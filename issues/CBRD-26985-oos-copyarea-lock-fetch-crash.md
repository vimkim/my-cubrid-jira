# [OOS] caller-owned heap fetch buffer 가 scan cache 로 바뀌어 copyarea fetch 가 crash

## Issue Triage

**이슈 수행 목적**: OOS expand 가 필요한 heap fetch 에서 caller 가 지정한 `RECDES.data` buffer 소유권을 보존한다. `LC_COPYAREA` descriptor 가 실제 record bytes 를 계속 가리키게 하여 `ALTER TABLE ... CHANGE` domain upgrade 중 crash 와 후속 DB recovery 실패를 막는다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `xlocator_lock_and_fetch_all` 은 `LC_RECDES_IN_COPYAREA` 로 `RECDES.data` 를 copyarea payload slot 에 맞춘 뒤, 각 object 마다 `recdes.data += DB_ALIGN(recdes.length, MAX_ALIGNMENT)` 및 `recdes.area_size -= round_length + sizeof(*obj)` 로 다음 slot 을 준비한다. 기존 `heap_init_get_context` 는 `recdes->area_size >= 0` 일 때만 이 buffer 를 caller-owned 로 보았으므로, copyarea 여유 공간이 소진된 순간 OOS expand heap fetch 가 `recdes.data` 를 heap scan cache 로 rebind 할 수 있었다.
- **영향**: QA 실패. `function_index_skip_alter_table.sql` 의 `alter table t change i a int` 에서 descriptor `offset` 은 copyarea 기준으로 publish 되지만 실제 bytes 는 scan cache 에 남아 `SIGSEGV` 로 종료한다. 뒤따른 `function_index_skip_bit.sql` 의 접속 실패와 recovery fatal 은 같은 DB 가 이미 깨진 뒤의 2차 증상이다.

**이슈 수행 방안**:

- `heap_init_get_context` 의 `keep_recdes_buffer` 판정에서 `recdes->area_size >= 0` 조건을 제거한다. caller 가 위치시킨 non-scan-cache `RECDES.data` 는 남은 writable area 가 0 이하가 되어도 caller-owned 로 유지한다.
- `heap_scancache::is_recdes_assigned_to_area` 는 scan-cache 시작 주소만 비교하지 않고, scan-cache block 내부 전체 범위를 검사한다. scan-cache pointer 가 record 단위로 전진한 뒤에도 scan-cache-owned 로 판정되게 한다.
- heap 은 caller-owned buffer 가 부족할 때 scan cache 로 성공 rebind 하지 않고 `S_DOESNT_FIT` 을 노출한다. 기존 locator copyarea grow/retry 흐름이 같은 object 를 더 큰 copyarea 로 다시 fetch 한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/heap_file.c`, `src/storage/heap_file.h` 의 heap fetch buffer ownership 판정만 수정한다. SQL 문법, catalog, OOS on-disk layout, WAL format, locator copyarea layout 은 바뀌지 않는다. PR 문맥은 https://github.com/CUBRID/cubrid/pull/7368 이다.

---

## Description

### 한 줄 결론

OOS expand 자체가 문제는 아니다. 문제는 caller 가 이미 output 위치로 지정한 `RECDES.data` 를 heap 계층이 "scan cache 로 바꿔도 되는 buffer" 로 잘못 분류한 점이다.

### 실패 호출 흐름

```text
ALTER TABLE ... CHANGE
  -> do_run_upgrade_instances_domain
    -> locator_upgrade_instances_domain
      -> xlocator_upgrade_instances_domain
        -> xlocator_lock_and_fetch_all
          -> heap_next / heap_get_visible_version_expand_oos
```

`xlocator_lock_and_fetch_all` 은 `LC_COPYAREA` 하나에 record bytes 와 descriptor 를 같이 담는다.

```text
copyarea->mem
  | record bytes 는 앞에서 뒤로 증가
  v
  [ rec0 ][ rec1 ][ free space ... ][ obj1 ][ obj0 ][ LC_COPYAREA_MANYOBJS ]
                                      ^
                                      descriptor 는 뒤에서 앞으로 증가
```

`LC_COPYAREA_ONEOBJ.offset` 은 `copyarea->mem` 기준 record 시작 위치이다. 따라서 descriptor 를 publish 할 때는 실제 record bytes 가 반드시 `copyarea->mem + offset` 에 있어야 한다.

### 왜 OOS branch 에서만 드러났나

`feat/oos` 는 raw record 를 클라이언트나 상위 계층으로 넘기는 일부 fetch 경로에서 inline OOS OID 를 실제 column bytes 로 펼친다. 이 작업은 `heap_next_expand_oos` 또는 `heap_get_visible_version_expand_oos` 아래에서 실행된다.

```text
xlocator_lock_and_fetch_all
  -> heap_get_visible_version_expand_oos
     -> heap_get_visible_version_internal
        -> heap_get_record_data_when_all_ready
           -> heap_record_replace_oos_oids
```

OOS expand 결과가 caller buffer 에 들어가지 않으면 heap 은 `S_DOESNT_FIT` 을 반환해야 한다. 그러면 locator 는 기존 copyarea grow/retry 로 같은 object 를 더 큰 copyarea 에 다시 읽는다.

pre-fix 에서는 `heap_init_get_context` 가 다음 조건으로 caller-owned 여부를 판단했다.

```text
recdes != NULL
&& recdes->data != NULL
&& recdes->area_size >= 0
&& recdes->data 가 scan-cache 시작 주소가 아님
```

copyarea loop 는 object 를 하나 pack 할 때마다 `recdes.area_size` 에서 record payload 와 descriptor 크기를 뺀다. 이 값은 copyarea 의 남은 writable area 이지 buffer 소유권이 아니다. 그러나 pre-fix heap 은 이 값이 0 이하가 되면 caller buffer 가 아니라고 판단했고, 이후 `heap_prepare_recdes_copy_area` 가 `heap_scan_cache_allocate_recdes_data` 를 통해 `recdes.data` 를 scan cache 로 바꿀 수 있었다.

이 상태에서 locator 는 기존처럼 descriptor 를 만든다.

```text
obj->offset = offset                  copyarea 기준 metadata
recdes.data = scan_cache.m_area + n    실제 bytes 위치
```

metadata 와 payload 의 기준 주소가 갈라지므로, 다음 단계가 copyarea descriptor 로 record 를 다시 해석할 때 잘못된 bytes 를 읽는다.

### core 에서 보인 단서

관찰된 core 값은 "큰 OOS value 가 copyarea 를 넘쳤다" 보다 "buffer 기준이 이미 scan cache 로 오염됐다" 에 가깝다.

```text
mobjs->num_objs = 532
offset = 16992
recdes.length = 32
recdes.area_size = 8672
recdes.data = scan_cache.m_area 내부 주소
```

`recdes.length = 32` 이므로 현재 record 자체가 큰 payload 라서 실패한 것이 아니다. 앞선 fetch 중 `recdes.data` 가 scan cache 로 바뀌었고, locator loop 가 그 pointer 를 계속 전진시키면서 작은 record 도 scan cache 기준으로 pack 하려 한 것이다.

## Test Build

- 대상 브랜치: `CBRD-26985-infinite-loop`
- PR HEAD: `e4db120d3` (`[CBRD-26985] Preserve caller-owned heap fetch buffers`)
- 기준 브랜치: `feat/oos`
- 원래 재현 기준: `53e8d6b9a` 부근의 pre-fix `feat/oos`
- 분석 중 확인한 런타임 버전: `CUBRID 11.5.0.2335-53e8d6b`, 64bit release build
- 실행 모드: SA mode (standalone, 서버와 클라이언트가 한 프로세스에서 도는 모드)
- OS: `TBD - 합의 미확인`

## Repro

```sh
csql -S -u dba -i function_index_skip_alter_table.sql <db_name>
csql -S -u dba -i function_index_skip_bit.sql <db_name>
```

직접 trigger statement:

```sql
alter table t change i a int;
```

해당 statement 는 30,000 row 테이블에서 `char` 계열 값을 `int` domain 으로 upgrade 하는 경로를 실행한다.

## Expected Result

`function_index_skip_alter_table.sql` 이 서버 crash 없이 끝난다. 결과는 golden result 와 일치해야 하며, `add unique index idx(j,k)` 의 `Error:-670` 은 테스트가 기대하는 unique constraint failure 로 남는다.

뒤따르는 `function_index_skip_bit.sql` 은 같은 DB 에 정상 접속해 실행된다.

## Actual Result

패치 전에는 `alter table t change i a int` 에서 `csql` 이 `SIGSEGV` 로 종료했다. 이후 같은 DB 로 다음 SQL test 를 실행하면 서버 recovery 중 redo 적용 실패가 발생했고, test runner 는 접속 실패를 반복했다.

관찰된 fatal message:

```text
LOG FATAL ERROR: log_rv_redo_record_sync: Error applying redo record
at log_lsa=(47149, 16240), rcv = {mvccid=27691, vpid=(0, 29057), offset = 3, data_length = 18}
```

## Additional Information

### 실제 수정 내용

| 파일 | 변경 | 의미 |
|------|------|------|
| `src/storage/heap_file.c` | `heap_init_get_context` 의 `keep_recdes_buffer` 조건에서 `area_size >= 0` 제거 | caller 가 위치시킨 `RECDES.data` 는 남은 공간이 부족해도 caller-owned 이다. 공간 부족은 `S_DOESNT_FIT` 으로 드러나야 한다. |
| `src/storage/heap_file.c` | `heap_scancache::is_recdes_assigned_to_area` 를 시작 주소 비교에서 block range 비교로 변경 | scan-cache pointer 가 block 중간을 가리켜도 scan-cache-owned 로 판정한다. |
| `src/storage/heap_file.h` | `keep_recdes_buffer` 주석을 caller-positioned buffer 기준으로 갱신 | field 의미를 "rebind 금지" 보다 "caller 가 위치시킨 buffer 보존" 으로 명확히 한다. |

### 변경 전후 계약

```text
AS-IS
  recdes.data != NULL && recdes.area_size >= 0 이면 caller-owned
  recdes.data == scan_cache.m_area 시작 주소이면 scan-cache-owned

TO-BE
  recdes.data != NULL 이고 scan-cache block 밖이면 caller-owned
  recdes.data 가 scan-cache block 내부이면 scan-cache-owned
```

이 변경으로 heap fetch 의 성공 반환 계약이 분명해진다.

```text
caller-owned RECDES.data 에 record 가 들어감
  -> S_SUCCESS, recdes.data 유지

caller-owned RECDES.data 에 record 가 안 들어감
  -> S_DOESNT_FIT, caller 가 buffer 를 키워 재시도

scan-cache-owned 또는 empty RECDES.data
  -> heap 이 scan-cache area 를 할당하거나 키울 수 있음
```

### locator 를 직접 고치지 않는 이유

`xlocator_fetch_all` 과 `xlocator_lock_and_fetch_all` 은 이미 `S_DOESNT_FIT` 일 때 copyarea 를 키워 재시도하는 구조를 갖고 있다. lock fetch 경로는 `heap_get_visible_version_expand_oos` 의 `S_DOESNT_FIT` 에서 `retry_current_oid` 를 세우고 `prev_oid` 로 되돌리는 보정도 갖고 있다.

따라서 이번 수정은 locator 에 새 packing helper 를 넣는 대신 heap 계층의 buffer ownership 판정을 바로잡는다. 그러면 locator 의 기존 copyarea grow/retry 계약이 정상적으로 동작한다.

### 관련 자료

- 풀 리퀘스트: https://github.com/CUBRID/cubrid/pull/7368
- 관련 follow-up: CBRD-26937 (`OOS+REC_BIGONE` 임시 abort 제거 / 정식 거부)
