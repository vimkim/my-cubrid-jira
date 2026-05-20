# [OOS] heap_get_last_version 경로의 OOS 확장 버퍼가 자라지 못해 OOS 컬럼이 있는 행을 UPDATE 할 때 #15951 로 실패하는 회귀를 수정한다

## Issue Triage

**이슈 수행 목적** (필수): OOS 로 저장된 큰 JSON/가변 컬럼이 있는 행을 `UPDATE` 할 때 `Query execution failure #15951` 로 실패하던 회귀를 제거한다. `cbrd_23430.sh` 가 OK 로 통과한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: `heap_record_replace_oos_oids` 는 OOS OID inline 슬롯을 실제 가변 컬럼 바이트로 펼쳐 `rec->data` 에 쓴다. `0c9a02bd3 [CBRD-26815]` 패치 이후 COPY 모드에서 `rec->area_size < new_length` 가 되면 무조건 `S_DOESNT_FIT` 만 반환한다. 호출자가 `xlocator_fetch_all` 처럼 자체 재시도 루프를 가지면 더 큰 copyarea 로 재호출해 해결되지만, `UPDATE` 경로의 `locator_attribute_info_force -> heap_get_last_version` 은 재시도 루프가 없다 — `S_DOESNT_FIT` 를 받으면 `er_set` 도 호출하지 않은 채 `ER_FAILED` 로 빠진다.
- **영향**: 고객 시나리오 실패 — `loaddb` 로 한 행짜리 50000-element JSON 을 적재한 뒤 `alter table t add column i int; update t set i = 1;` 만 실행해도 회귀가 재현된다. 사용자에게는 원인 정보가 전혀 없는 `ERROR: Execute: Query execution failure #15951` 만 노출되고 `select json_length(j)` 도 함께 차단된다. `cbrd_23430.sh`, `json_long_body.sh` 등 OOS-on-UPDATE 시나리오가 NOK 로 떨어진다.

**이슈 수행 방안**:

- `HEAP_GET_CONTEXT` 에 `data_externally_positioned` 플래그를 추가하고, `heap_init_get_context` 시점에 `recdes != NULL && recdes->data != NULL` 인지 한 번만 기록한다.
- `heap_record_replace_oos_oids` 의 COPY 모드 분기에서 `rec->area_size < new_length` 일 때:
  - `data_externally_positioned == true` (또는 `scan_cache == NULL`) 이면 기존처럼 `S_DOESNT_FIT` 를 반환해 `xlocator_fetch_all` 의 재시도 루프에 맡긴다 — `CBRD-26815` 가 고친 unloaddb 시나리오를 그대로 보존한다.
  - `data_externally_positioned == false` (UPDATE 경로처럼 호출자가 `recdes.data = NULL` 로 넘긴 경우) 이면 `heap_scan_cache_allocate_recdes_data` 로 scan_cache 가 소유한 버퍼를 키워서 펼친 레코드를 그대로 담는다. `copy_recdes` 는 호출 이후에 읽히므로 포인터가 갱신되어도 호출자가 투명하게 큰 버퍼를 본다.
- PEEK 모드 분기는 변경하지 않는다.
- 회귀 회귀 방지를 위해 `cbrd_23430.sh` 가 OK 로 통과해야 한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: OOS 가 적용된 행을 `UPDATE` 하면 `Query execution failure #15951` 로 빠진다. 직접 원인을 짚는 에러 메시지가 없어 분석이 어렵다.
- **원인 / 배경**: `0c9a02bd3 [CBRD-26815]` 가 `heap_record_replace_oos_oids` 의 COPY-모드 재할당을 전면 금지하면서, scan_cache 가 소유한 버퍼를 더 키워야 하는 `heap_get_last_version` 경로의 UPDATE 가 같이 막혔다.
- **제안 / 변경**: 두 호출 패턴을 `data_externally_positioned` 플래그로 구분해, 외부 copyarea 슬롯을 가진 호출자만 `S_DOESNT_FIT` 로 돌려보내고 scan_cache 소유 버퍼는 그 자리에서 키운다.
- **영향 범위**: `src/storage/heap_file.{c,h}` 2 파일. `xlocator_fetch_all` / unloaddb 경로(CBRD-26815 가 고친 부분)는 동작 변경 없음. `UPDATE` 경로는 회귀 이전 동작으로 복귀.

---

## Description

OOS (Out-of-row Overflow Storage — heap 의 큰 가변 컬럼을 별도의 OOS 파일 페이지로 분리해 저장하는 매커니즘) 가 적용된 JSON 컬럼을 가진 행을 `UPDATE` 하면 다음과 같이 실패한다.

```sh
cubrid createdb jsondb -r en_US
cubrid loaddb --no-user-specified-name -d init_data -C jsondb -udba
csql -u dba jsondb -c 'alter table t add column i int; update t set i = 1;'
# ERROR: Execute: Query execution failure #15951.
```

`#15951` 은 에러 코드가 아니라 `query_executor.c:15951` 의 소스 라인 번호다 (`qexec_failure_line()` 가 첫 실패 라인을 기록한다). 즉 `qexec_execute_mainblock` 이 `qp_scan != S_SUCCESS` 를 받았는데 `er_errid()` 는 `NO_ERROR` 라, `query_executor.c:16548` 의 fallback 메시지 (`Query execution failure #%d.`) 가 출력된 상황이다. 어딘가에서 `er_set` 없이 에러 코드가 그대로 전파됐다는 신호다.

### 호출 흐름과 실패 지점

```
qexec_execute_update
  -> locator_attribute_info_force        (locator_sr.c:7556)
     -> heap_get_last_version            (recdes.data = NULL, COPY 모드)
        -> heap_get_record_data_when_all_ready (REC_HOME)
           -> heap_scan_cache_allocate_recdes_data  (DB_PAGESIZE * 2)
           -> spage_get_record (COPY)                (compact 레코드 복사)
           -> heap_record_replace_oos_oids           (OOS OID -> 실제 값 펼침)
              new_length > rec->area_size (= 32 KB)
              -> return S_DOESNT_FIT   (CBRD-26815 패치 이후)
        -> heap_get_record_data_when_all_ready 가 S_DOESNT_FIT 그대로 전달
     -> heap_get_last_version 가 S_DOESNT_FIT 반환
  -> locator_sr.c:7632 분기에서 ER_FAILED 반환 (er_set 호출 없음)
```

`heap_record_replace_oos_oids` 가 50000-element JSON 을 펼치면 `new_length` 가 수십 MB 까지 커지지만 scan_cache 가 미리 잡아 둔 버퍼는 `DB_PAGESIZE * 2 = 32 KB` 뿐이라 `area_size < new_length` 가 무조건 성립한다.

### 왜 CBRD-26815 가 이 경로를 끊었는가

`CBRD-26815` 의 본래 목적은 `xlocator_fetch_all` (unloaddb) 시나리오를 고치는 것이었다. 그 호출자는 `LC_RECDES_IN_COPYAREA` 로 `recdes.data` 를 copyarea 슬롯 안쪽에 미리 위치시키고 행 사이를 `recdes.data += round_length;` 로 옮긴다. 이때 `heap_record_replace_oos_oids` 가 `heap_scan_cache_allocate_recdes_data` 로 `rec->data` 를 scan_cache 메모리로 재할당해 버리면, 호출자가 가지고 있는 copyarea 슬롯에는 펼치기 전 stale 한 바이트가 그대로 남는다. 이후 `LC_RECDES_TO_GET_ONEOBJ` 가 그 stale 영역을 읽어 OOS OID 경계를 넘어 다음 행 영역까지 침범하면서 `db_json_deserialize_doc_internal` 의 unknown-type assert 가 터졌다.

`CBRD-26815` 패치는 이 문제를 막기 위해 COPY 모드에서 `rec->area_size < new_length` 이면 무조건 `S_DOESNT_FIT` 를 반환하도록 바꿨다. `xlocator_fetch_all` 처럼 자체 재시도 루프 (`copyarea_length += DB_PAGESIZE`) 가 있는 호출자에게는 옳은 처리지만, `heap_get_last_version` 호출 경로는 재시도 루프가 없어서 그대로 실패한다.

### 두 호출자의 RECDES 소유권 차이

| 호출자 | `recdes.data` 진입 상태 | 소유자 | OOS 펼침 시 더 큰 버퍼가 필요할 때 |
|---|---|---|---|
| `xlocator_fetch_all` (unloaddb) | non-NULL, copyarea 슬롯을 가리킴 | 호출자가 copyarea 안쪽에 직접 배치 | 호출자가 copyarea 를 키워 재시도. `heap_*` 가 임의로 옮기면 stale 영역 문제 발생 |
| `heap_get_last_version` (UPDATE) | NULL | `heap_get_record_data_when_all_ready` 가 `heap_scan_cache_allocate_recdes_data` 로 scan_cache 안에 할당 | scan_cache 안에서 더 큰 버퍼로 옮겨도 호출자가 `copy_recdes` 를 호출 이후에 읽으므로 안전 |

`recdes->data` 가 호출 진입 시점에 NULL 인지 아닌지가 두 호출 패턴을 가르는 자연스러운 식별자다.

## Test Build

`CUBRID 11.5.0.2334 (debug build, clang20)`, OS: Linux 5.14.0-570.30.1.el9_6.x86_64

base 커밋: `e2a5d2b10` (`vk/cbrd-26815-oos-json-deserialize` merge from cub/develop)
회귀 도입 커밋: `0c9a02bd3 [CBRD-26815] Return S_DOESNT_FIT in COPY mode when expansion overflows`
수정 커밋: `b0c0d1226 [CBRD-26815] Allow scan_cache realloc for owned recdes in OOS expansion`

## Repro

```sh
# 빌드
./build.sh -m debug

# 테스트 데이터 (testcases-private 의 cbrd_23430 셋이 그대로 쓰임)
cp /home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21522_json/cbrd_23430/cases/init_data.tar.gz /tmp/
cd /tmp && tar -zxf init_data.tar.gz

cubrid service stop
cubrid deletedb jsondb 2>/dev/null
cubrid createdb jsondb -r en_US
cubrid server start jsondb

csql -u dba jsondb -c 'drop table if exists t; create table t(j json);'
cubrid loaddb --no-user-specified-name -d init_data -C jsondb -udba

csql -u dba jsondb -c 'alter table t add column i int; update t set i = 1;'
csql -u dba jsondb -c 'select json_length(j) from t;'
```

## Expected Result

```
1 row affected. (X sec) Committed.

=== <Result of SELECT Command in Line 1> ===

  json_length(j)
================
           50000

1 row selected.
```

## Actual Result (회귀 발생 시)

```
ERROR: Execute: Query execution failure #15951.
```

`UPDATE` 가 실패하고, 후속 `SELECT json_length(j)` 는 정상 (행이 손상되지는 않음).

## Implementation

### 변경 1 — `HEAP_GET_CONTEXT` 필드 추가 (`src/storage/heap_file.h`)

`expand_oos` 옆에 `data_externally_positioned` 를 추가한다. 호출자가 `recdes->data` 를 직접 배치한 경우(copyarea 슬롯 등)와 NULL 로 넘긴 경우를 구분하기 위함이다.

```cpp
struct heap_get_context
{
  /* ... 기존 필드 ... */
  bool expand_oos;

  /* True when the caller pre-positioned recdes_p->data into a buffer it owns ... */
  bool data_externally_positioned;
};
```

### 변경 2 — `heap_init_get_context` 에서 플래그 캡처 (`src/storage/heap_file.c`)

```c
context->data_externally_positioned = (recdes != NULL && recdes->data != NULL);
```

진입 시점의 `recdes->data` 가 자연스러운 식별자다.

- `xlocator_fetch_all` 가 `heap_next` 를 거쳐 들어오면 `LC_RECDES_IN_COPYAREA` 가 이미 `recdes.data` 를 copyarea 안쪽으로 옮겨 둔 상태 -> `true`.
- `locator_attribute_info_force` -> `heap_get_last_version` 경로는 `copy_recdes.data = NULL` 로 진입 -> `false`. 이후 `heap_get_record_data_when_all_ready` 가 `heap_scan_cache_allocate_recdes_data` 로 scan_cache 버퍼를 잡아 준다.

### 변경 3 — `heap_record_replace_oos_oids` 분기 보강 (`src/storage/heap_file.c`)

```c
if (context->ispeeking == PEEK)
  {
    /* 기존 그대로: PEEK 은 page buffer 라 write 불가, scan_cache 로 옮기고 COPY 로 전환 */
    ...
  }
else if (rec->area_size < new_length)
  {
    if (context->data_externally_positioned || context->scan_cache == NULL)
      {
        /* xlocator_fetch_all 처럼 외부에 위치한 버퍼면 호출자의 재시도 루프에 맡긴다. */
        return S_DOESNT_FIT;
      }
    /* scan_cache 가 소유한 버퍼면 그대로 키운다. 호출자는 copy_recdes 를 이후에 읽으므로
       rec->data 가 갱신돼도 투명하다. */
    if (heap_scan_cache_allocate_recdes_data (thread_p, context->scan_cache, rec, new_length) != NO_ERROR)
      {
        return S_ERROR;
      }
  }
```

PEEK 모드 분기는 변경하지 않는다. PEEK 으로 들어와 scan_cache 가 없으면 여전히 `S_DOESNT_FIT`, 있으면 그대로 scan_cache 로 옮긴다.

### 변경 안 한 것

- `xlocator_fetch_all` 의 재시도 루프: 동작 변경 없음. `data_externally_positioned == true` 가 잡혀 `S_DOESNT_FIT` 가 그대로 반환된다.
- `locator_attribute_info_force` 의 에러 처리: `er_set` 누락 자체는 별개 결함이지만 본 회귀 수정 범위 밖이라 그대로 둔다. 본 수정으로 `S_DOESNT_FIT` 가 더 이상 그 경로에 도달하지 않으므로 사용자 노출 회귀는 사라진다.

## Acceptance Criteria

- [ ] 위 Repro 단계가 `update` 단계에서 `1 row affected` 를 출력하고 `select json_length(j)` 가 `50000` 을 반환한다.
- [ ] `cbrd_23430.sh` (`shell/_35_cherry/issue_21522_json/cbrd_23430/cases/cbrd_23430.sh`) 가 OK 로 통과한다.
- [ ] `cbrd_25481.sh` (unloaddb + multi-MB JSON, CBRD-26815 가 고친 시나리오) 가 결과 데이터 측면에서 동일하게 통과한다 — 즉 회귀 도입 직전 동작을 보존한다.
- [ ] `bigPageSize.sh`, `tbl_enc_08.sh`, `cbrd_25446.sh` 등 인접 OOS/JSON 테스트가 회귀 도입 직전 대비 추가 NOK 를 만들지 않는다.
- [ ] `-m debug`, `-m release` 모두 클린 빌드.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] CI (`test_sql`, `test_medium`) 통과
- [ ] PR 머지 후 `vk/cbrd-26815-oos-json-deserialize` 브랜치 회귀 사라짐 확인

## 참고 코드

- `src/storage/heap_file.c:7982 heap_record_replace_oos_oids` — OOS OID -> 실제 값 펼치는 함수
- `src/storage/heap_file.c:7899 heap_get_record_data_when_all_ready` — REC_HOME / REC_RELOCATION / REC_BIGONE 분기에서 위 함수를 호출
- `src/storage/heap_file.c:26814 heap_get_last_version` — UPDATE 경로의 진입 함수
- `src/storage/heap_file.c:26980 heap_init_get_context` — `data_externally_positioned` 캡처 지점
- `src/transaction/locator_sr.c:7556 locator_attribute_info_force` — `heap_get_last_version` 호출자, `S_DOESNT_FIT` 를 ER_FAILED 로 변환하는 분기 보유
- `src/transaction/locator_sr.c:2775 xlocator_fetch_all` — `LC_RECDES_IN_COPYAREA` 로 `recdes.data` 를 위치시키는 호출자, 자체 grow-and-retry 루프 보유

## Remarks

- 회귀 도입 커밋: `0c9a02bd3 [CBRD-26815] Return S_DOESNT_FIT in COPY mode when expansion overflows`
- 수정 커밋: `b0c0d1226 [CBRD-26815] Allow scan_cache realloc for owned recdes in OOS expansion`
- 후속 정리 후보 (본 티켓 범위 밖):
  - `locator_attribute_info_force` 가 `scan == S_ERROR || scan == S_DOESNT_FIT` 분기에서 `er_set` 없이 `ER_FAILED` 만 반환하는 부분. 본 수정으로 사용자 노출 회귀는 사라지지만, 다른 회귀가 같은 경로로 들어오면 또 `#NNNNN` 형태 모호 에러로 노출될 수 있다.
  - `cbrd_23430.sh` 가 다루지 못한 추가 시나리오 (예: 멀티 OOS 컬럼 동시 UPDATE) 는 `CBRD-26817` 의 후속 sub-task 로 분리한다.
