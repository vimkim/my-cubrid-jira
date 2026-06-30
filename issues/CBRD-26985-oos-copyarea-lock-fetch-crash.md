# [OOS] copyarea fetch 경로가 OOS expand 후 record 위치를 잘못 publish 해 crash

## Issue Triage

**이슈 수행 목적**: OOS expand 가 필요한 대량 fetch 경로에서 `LC_COPYAREA` descriptor 가 항상 실제 record bytes 를 가리키도록 고친다. `ALTER TABLE ... CHANGE` domain upgrade 중 서버가 죽고, 이후 SQL runner 가 깨진 DB 에 재접속을 반복하는 cascade 를 차단한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `feat/oos` 는 raw record 를 클라이언트/상위 계층으로 보내는 locator fetch 경로를 `heap_next_expand_oos` / `heap_get_visible_version_expand_oos` 로 바꿨다. 이 fetch 는 OOS expand, `REC_BIGONE`, MVCC undo 복원처럼 record 를 조립해야 하는 경우 `recdes.data` 를 caller buffer 가 아니라 heap scan cache 로 rebind 할 수 있다. 기존 locator packing 루프는 `recdes.data` 가 계속 copyarea 내부라고 가정해 descriptor `offset` 을 기록한다.
- **영향**: QA 실패. `function_index_skip_alter_table.sql` 의 `alter table t change i a int` 에서 `xlocator_lock_and_fetch_all` 이 copyarea descriptor 와 실제 bytes 의 buffer 기준을 어긋나게 만들고 `SIGSEGV` 로 종료한다. follow-on `function_index_skip_bit.sql` 의 접속 실패와 recovery fatal 은 같은 DB 가 이미 깨진 뒤의 2차 증상이다.

**이슈 수행 방안**:

- 각 fetch 직전에 남은 copyarea payload 크기를 다시 계산하고, `recdes.data` / `recdes.area_size` 를 현재 slot 으로 재설정한다.
- fetch 성공 후 `recdes.data` 가 scan cache 등 copyarea 밖으로 rebind 됐으면 descriptor 를 만들기 전에 record bytes 를 현재 copyarea slot 으로 복사한다.
- 현재 slot 에 record 가 안 들어가면 `S_DOESNT_FIT` 으로 기존 copyarea grow/retry 흐름을 탄다. 첫 object 를 이미 읽은 뒤 부족함을 알게 된 경우에는 OID 를 직전 값으로 되돌려 같은 object 를 더 큰 copyarea 에 다시 fetch 한다.
- 같은 copyarea packing 계약을 쓰는 `xlocator_fetch_all` 도 동일하게 보정한다. `xlocator_lock_and_fetch_all` 만 고치면 `unloaddb` / `compactdb` 대량 fetch 계열에 같은 rebind 위험이 남는다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/transaction/locator_sr.c` 의 copyarea packing 경로 두 곳(`xlocator_lock_and_fetch_all`, `xlocator_fetch_all`)만 수정한다. SQL 문법, catalog, OOS on-disk layout, WAL format 은 바뀌지 않는다. 기존 PR 문맥은 https://github.com/CUBRID/cubrid/pull/7368 이다.

---

## Description

### 한 줄 결론

OOS expand 자체가 잘못된 것이 아니다. heap fetch API 의 정상 계약은 "`recdes.data` 가 caller buffer 를 계속 가리킨다" 가 아니라 "성공한 record 의 위치를 `recdes.data` 로 돌려준다" 이다. locator copyarea packing 코드가 이 계약을 잘못 이해했다.

### 실패 호출 흐름

```text
ALTER TABLE ... CHANGE
  -> do_run_upgrade_instances_domain
    -> locator_upgrade_instances_domain
      -> xlocator_upgrade_instances_domain
        -> xlocator_lock_and_fetch_all
          -> heap_next_expand_oos / heap_get_visible_version_expand_oos
```

`xlocator_lock_and_fetch_all` 은 `LC_COPYAREA` 하나에 record bytes 와 descriptor 를 같이 싣는다.

```text
copyarea->mem
  | record bytes 는 위로 자란다
  v
  [ rec0 ][ rec1 ][ free space ... ][ obj1 ][ obj0 ][ LC_COPYAREA_MANYOBJS ]
                                      ^
                                      descriptor 는 아래로 자란다
```

descriptor (`LC_COPYAREA_ONEOBJ`) 의 `offset` 은 `copyarea->mem` 기준이다. 따라서 descriptor 를 publish 하기 전에는 실제 record bytes 가 반드시 copyarea 내부의 해당 offset 에 있어야 한다.

### OOS branch 에서 깨진 가정

`develop` 의 일반 fetch 는 대개 caller 가 준 `recdes.data` 에 page record 를 복사한다. 그래서 locator 코드는 아래처럼 단순히 pointer 를 전진시켜도 우연히 맞았다.

```text
fetch into recdes.data
descriptor.offset = offset
offset += aligned_length
recdes.data += aligned_length
recdes.area_size -= aligned_length + descriptor_size
```

`feat/oos` 에서는 같은 raw-byte fetch 경로가 OOS expand 를 요청한다. 이때 heap layer 는 inline OOS OID 를 실제 value bytes 로 바꿔 full record 를 조립해야 한다. 조립 결과가 caller slot 에 안 들어가거나, `REC_BIGONE` / MVCC undo 복원처럼 별도 조립이 필요한 경우 heap scan cache 의 `m_area` 에 record 를 만들고 `recdes.data` 를 그쪽으로 돌릴 수 있다.

```text
xlocator_lock_and_fetch_all
  └ heap_get_visible_version_expand_oos
     └ heap_get_visible_version_internal
        └ heap_record_replace_oos_oids
           └ heap_oos_build_record
              ★ recdes.data = scan_cache.m_area 로 rebind 가능
```

문제는 rebind 뒤에도 locator 가 descriptor `offset` 을 copyarea 기준으로 기록한다는 점이다. 실제 bytes 는 scan cache 에 있는데 descriptor 는 copyarea 내부를 가리킨다. 더 나쁘게는 루프 끝의 `recdes.data += round_length` 가 scan cache pointer 를 전진시키므로, 다음 record 부터는 copyarea 가 아니라 scan cache 중간을 caller buffer 처럼 쓰게 된다.

core 에서 확인된 값도 이 상태와 맞다.

```text
mobjs->num_objs = 532
offset = 16992
recdes.length = 32
recdes.area_size = 8672
recdes.data = scan_cache.m_area 내부 주소
```

32바이트 record 자체가 OOS record 라서 scan cache 로 간 것이 아니다. 앞선 fetch 의 rebind 가 `recdes.data` 기준을 바꿔 놓았고, 이후 작은 record 까지 그 오염된 기준을 물려받은 것이다.

### develop / feat/oos / current 비교

| 코드 기준 | locator fetch 동작 | 판정 |
|-----------|-------------------|------|
| `develop` (`a25a6b6d4`) | `xlocator_fetch_all` 은 `heap_next`, `xlocator_lock_and_fetch_all` 은 일반 heap fetch 중심. OOS expand 가 없어서 scan-cache rebind 가 이 경로에 거의 들어오지 않는다. | 잠복 버그에 가깝다. copyarea packing 계약은 약하지만 trigger 가 적다. |
| `feat/oos` (`53e8d6b9a`) | raw-byte 경로가 `_expand_oos` fetch 로 바뀌었다. 그런데 copyarea slot 재설정, rebind 후 copy, 실제 남은 payload 계산이 없다. | CBRD-26985 원인. OOS 가 heap fetch 의 정상 rebind 경로를 이 루프에 끌어오면서 기존 가정이 깨졌다. |
| current before 추가 보정 | `xlocator_lock_and_fetch_all` 만 copyarea 재설정/복사로 고쳤다. | `ALTER CHANGE` crash 는 막지만 sibling `xlocator_fetch_all` 에 같은 hazard 가 남는다. |
| current after 추가 보정 | 두 대량 fetch 경로 모두 같은 copyarea 계약을 따른다. | CBRD-26985 범위에서는 맞다. |

## Test Build

- 대상 브랜치: `CBRD-26985-infinite-loop`
- 기준: `feat/oos` 위의 CBRD-26985 수정
- 원래 재현 기준 커밋: `53e8d6b9a`
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

해당 statement 는 30,000 row 테이블에서 `char` -> `int` domain upgrade 를 수행한다.

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

### 구현 방향

공통 계산은 helper 로 둔다.

```text
copyarea->length
  - sizeof(LC_COPYAREA_MANYOBJS)
  - offset
  - num_objs * sizeof(LC_COPYAREA_ONEOBJ)
```

각 fetch 반복은 아래 순서를 지킨다.

```text
1. 현재 offset 기준 copyarea slot 과 남은 payload 크기를 계산한다.
2. recdes.data / recdes.area_size 를 그 slot 으로 reset 한다.
3. heap_next_expand_oos 또는 heap_get_visible_version_expand_oos 를 호출한다.
4. 반환된 length 가 현재 slot 보다 크면 S_DOESNT_FIT 으로 빠진다.
5. recdes.data 가 현재 slot 이 아니면 bytes 를 copyarea slot 으로 복사한다.
6. descriptor offset/length 를 publish 한다.
```

`xlocator_lock_and_fetch_all` 의 lock branch 는 OID 를 얻기 위해 `heap_next` 를 한 번 호출한 뒤 lock 을 잡고 `heap_get_visible_version_expand_oos` 로 다시 읽는다. 두 번째 fetch 직전에도 `recdes` 를 copyarea slot 으로 다시 맞춰야 한다. 첫 fetch 가 `recdes.data` 를 바꿨을 수 있기 때문이다.

`xlocator_fetch_all` 은 lock branch 는 없지만 같은 `LC_COPYAREA` descriptor/payload layout 을 사용하고 `heap_next_expand_oos` 를 호출한다. 따라서 같은 보정이 필요하다.

### 추가 grill 결과

| 항목 | 결론 | 조치 |
|------|------|------|
| `xlocator_lock_and_fetch_all` fix | 맞는 방향이다. rebind 후 copyarea 로 복사하고, 공간 부족 시 grow/retry 로 돌리는 것이 heap fetch 계약과 맞다. | CBRD-26985 본문에 유지. |
| `xlocator_fetch_all` sibling path | 기존 CBRD-26985 패치는 여기까지 확장되지 않아 같은 copyarea rebind 위험이 남았다. `unloaddb` / `compactdb` 대량 fetch 는 이 경로와 연결된다. | 같은 보정 적용. |
| CircleCI job 133950 의 18 SQL failures | CBRD-26985 copyarea crash 와 다른 실패다. stack 이 `locator_insert_force` 아래 insert path 이고, `heap_insert_adjust_recdes_header` 의 `HEAP ABORT (OOS+REC_BIGONE insert)` 임시 guard 와 맞는다. | CBRD-26937 범위로 분리. CBRD-26985 로 해결됐다고 쓰면 안 된다. |
| develop 대비 OOS+heap 구현 | `develop` 은 big heap record 에서 `HEAP_MVCC_SET_HEADER_MAXIMUM_SIZE` 만 수행한다. current OOS branch 는 `has_oos && heap_is_big_length(record_size)` 에서 release build 도 `abort()` 한다. 주석도 `REVERT BEFORE MERGE` 라고 명시한다. | 현재 OOS+heap 구현은 잘못된 상태다. OOS 청크 쓰기 전 사용자 에러로 거부하거나, OOS+`REC_BIGONE` ownership/vacuum semantics 를 구현해야 한다. 기존 CBRD-26937 문서가 전자 방향을 제안한다. |

### 검증 결과

- `git diff --check` 통과
- `locator_sr.c` server-mode single-file compile 통과
- `locator_sr.c` SA-mode single-file compile 통과
- 기존 재현 SQL 은 패치 후 `csql` exit 0 으로 종료했고 core 를 만들지 않았다.
- `function_index_skip_alter_table.result` 와 line-for-line 으로 일치했다.
- `function_index_skip_bit.sql` 도 follow-on cascade 없이 통과했다.

### 관련 자료

- 풀 리퀘스트: https://github.com/CUBRID/cubrid/pull/7368
- 관련 follow-up: CBRD-26937 (`OOS+REC_BIGONE` 임시 abort 제거 / 정식 거부)
- 관련 OOS fetch 이슈: CBRD-26948 (`xlocator_fetch_all` / unloaddb / compactdb OOS expand)
