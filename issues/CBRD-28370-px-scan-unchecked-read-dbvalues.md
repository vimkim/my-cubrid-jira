# [PARALLEL SCAN] 병렬 힙 스캔이 heap_attrinfo_read_dbvalues() 오류를 무시해 FATAL/core 또는 이전 행 값을 반환한다

**한 줄 요약**: [CBRD-27800](https://jira.cubrid.org/browse/CBRD-27800)의 `ha_repl` 회귀 FATAL/core 분석 과정에서 발견한 병렬 힙 스캔의 독립 결함이다. `parallel_scan::slot_iterator::next_qualified_slot_with_peek()`(`src/query/parallel/px_scan/px_scan_slot_iterator.cpp:155`)가 `heap_attrinfo_read_dbvalues()`의 반환값을 검사하지 않아, 행 읽기 오류가 나면 일반 오류를 반환하는 대신 서버가 `FATAL`/core로 종료되거나 직전 행의 값을 그대로 반환한다. 이 이슈는 병렬 힙 스캔이 `heap_attrinfo_read_dbvalues()` 실패 시 오류를 정상 전파하도록 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 병렬 힙 스캔 중 `heap_attrinfo_read_dbvalues()`가 실패하면 서버 비정상 종료(`FATAL`/core)나 이전 행 값 재사용 없이 원래 오류 코드를 그대로 호출자에게 반환하게 한다.

**이슈 수행 이유**: `src/query/parallel/px_scan/px_scan_slot_iterator.cpp:155`는 코드베이스 전체에서 유일하게 `heap_attrinfo_read_dbvalues()`의 반환값을 확인하지 않고 다음 단계(`fetch_val_list`)로 진행한다. 순차 힙 스캔(`src/query/scan_manager.c:6325`), 배치 스캔(`src/query/scan_manager.c:8772`), 병렬 인덱스 스캔(`src/query/parallel/px_scan/index/px_scan_index_leaf_slot_walker.cpp:544`)은 모두 실패 시 즉시 `S_ERROR`를 반환한다. `11.5.0.2997-de4bb11` `ha_repl` 회귀 테스트(`CBRD-27800`으로 OOS 레코드가 손상된 상태)에서 순차 스캔은 `-1398`(`ER_HEAP_OOS_CORRUPTED_RECORD`)을 반환한 반면, 병렬 힙 스캔에서는 `heap_attrinfo_access` `FATAL`과 core 5건이 발생했다.

**영향**: 병렬 힙 스캔 중 OOS 손상(`-1398`), 메모리 부족(`ER_OUT_OF_VIRTUAL_MEMORY`), 레코드 손상 등 어떤 이유로든 `heap_attrinfo_read_dbvalues()`가 실패하면 두 가지 심각한 결과가 발생한다.

1. **워커가 처음 읽는 행에서 실패하는 경우**: 속성 캐시 슬롯이 `HEAP_UNINIT_ATTRVALUE`인 채 `heap_attrinfo_access()`에 진입해 `ER_FATAL_ERROR_SEVERITY` → `abort()`로 `cub_server`가 종료된다(release `11.5.0.2997-de4bb11` `ha_repl`에서 core 5건 확인).
2. **워커가 정상 행을 1건 이상 읽은 뒤 실패하는 경우**: 이미 채워진 `HEAP_READ_ATTRVALUE`와 `cache_dbvalp`를 그대로 읽어 오류를 삼키고 직전 행 값을 오답으로 반환한다(소스 분석; `11.5.0.3025-131af8f` release `ha_repl`에서 `cbrd_26799.test`가 FATAL 없이 NOK로 끝난 현상과 일치).

OOS 손상 외의 오류 조건에서의 직접 단독 재현은 아직 수행하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 결함 경로 (`de4bb116e5` 및 `develop` `424cab5ef6`)

1. **반환값 미검사**: `parallel_scan::slot_iterator::next_qualified_slot_with_peek()`([px_scan_slot_iterator.cpp:153-169](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/parallel/px_scan/px_scan_slot_iterator.cpp#L153-L169))는 `m_rest_regu_list`가 있을 때 `heap_attrinfo_read_dbvalues()`를 호출하면서 반환값을 검사하지 않고 그대로 `fetch_val_list(..., PEEK)`로 진행한다.
   - 코드베이스 전체에서 `heap_attrinfo_read_dbvalues()`의 반환값을 무시하는 호출 지점은 이곳뿐이다. 일반 순차 스캔([scan_manager.c:6325](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/scan_manager.c#L6325)), 배치 스캔([scan_manager.c:8772](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/scan_manager.c#L8772)), 병렬 인덱스 스캔([px_scan_index_leaf_slot_walker.cpp:544](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/parallel/px_scan/index/px_scan_index_leaf_slot_walker.cpp#L544))은 모두 `!= NO_ERROR`를 검사하고 즉시 `S_ERROR` 또는 `ER_FAILED`를 반환한다.
2. **오류 시 슬롯 미초기화 유지**: `heap_attrinfo_read_dbvalues_with_oos_prefetch()`([heap_file.c:12530-12541](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/storage/heap_file.c#L12530-L12541))는 요청된 OOS 컬럼이 2개 이상일 때 `heap_oos_read_grouped_payloads()`([heap_oos.cpp:782-866](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/storage/heap_oos.cpp#L782-L866))를 먼저 호출한다. 여기서 `-1398`이나 메모리 부족 등이 발생하면 `heap_attrinfo_read_dbvalues_loop()`가 아예 실행되지 않아 비-OOS 컬럼(예: `cext int`, `attrid = 12`)을 포함한 모든 슬롯이 읽히지 않는다. 단일 OOS 컬럼이나 일반 읽기 실패에서도 실패한 컬럼 이후 슬롯은 읽히지 않는다.
3. **워커 첫 행 실패 시 `FATAL`/core**: 각 병렬 스캔 워커는 `m_rest_attr_cache->values[]`를 `HEAP_UNINIT_ATTRVALUE`([heap_file.c:11111](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/storage/heap_file.c#L11111))로, `regu_var->value.attr_descr.cache_dbvalp`를 `NULL`로 초기화한 채 시작한다. 워커가 처음 읽는 행(예: `CBRD-27800`에서 가장 먼저 덮이는 0번 페이지 1번 행)에서 `heap_attrinfo_read_dbvalues()`가 실패하면 `fetch_val_list()`([fetch.c:2173](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/fetch.c#L2173), `de4bb116e5` 기준 `:2210`) → `fetch_peek_dbval_slow()`([fetch.c:1680](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/query/fetch.c#L1680), `de4bb116e5` 기준 `:1717`) → `heap_attrinfo_access()`([heap_file.c:13237-13256](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/storage/heap_file.c#L13237-L13256), `de4bb116e5` 기준 `:13244`)로 진입한다. 여기서 `value->state == HEAP_UNINIT_ATTRVALUE`가 참이 되어 `"heap_attrinfo_access: Unknown attrid = %d"`를 남기고 `er_set(ER_FATAL_ERROR_SEVERITY, ...)` → `er_log()`([error_manager.c:1819](https://github.com/CUBRID/cubrid/blob/424cab5ef64aaa5299b4e5f9267c0ee105ba9f4e/src/base/error_manager.c#L1819)) → `abort()`로 이어진다.
4. **워커 후속 행 실패 시 직전 행 값 재사용(소스 분석)**: 같은 워커가 이미 정상 행을 1건 이상 읽었다면 `values[]`의 상태가 `HEAP_READ_ATTRVALUE`이고 `regu_var->value.attr_descr.cache_dbvalp`도 직전 행 슬롯을 가리킨다. 이 상태에서 `heap_attrinfo_read_dbvalues()`가 실패해도 오류가 전파되지 않고 `fetch_val_list()`가 직전 행의 캐시 값을 그대로 반환해 묵시적 오답이 생긴다.

### 버전 범위

- 이 누락은 `149be38138`([CBRD-25447](https://jira.cubrid.org/browse/CBRD-25447), PR #6512 `px_heap_scan_slot_iterator.cpp`)에서 처음 들어갔고, `0c6088ab35`([CBRD-26722](https://jira.cubrid.org/browse/CBRD-26722), PR #7062 `px_scan_slot_iterator.cpp`)에서 현재 위치로 옮겨졌다.
- `develop`(11.5.x)에 존재하며 `release/11.4`에는 없다.

## Test Build

| 빌드 | 환경 / 실행 | 결과 |
|---|---|---|
| `11.5.0.2997-de4bb11` (`de4bb116e5`, release) | QA `ha_repl` (`mainId=6255`) | `cbrd_25717_overflow_record.test` 등 4개 TC에서 slave server `FATAL`; `ha1`에서 `heap_attrinfo_access` core 5건 |
| `11.5.0.2997-de4bb11` (`de4bb116e5`, debug) | QA `ha_repl` (`mainId=6254`) | 동일 4개 TC에서 slave server `FATAL` |
| `11.5.0.3025-131af8f` (`131af8f86e`, release) | QA `ha_repl` (`mainId=6257`) | OOS 3개 TC `FATAL`; `cbrd_26799.test`는 FATAL 없이 `[NOK]` |
| `11.5.0.3025-131af8f` (`131af8f86e`, debug) | QA `ha_repl` (`mainId=6256`) | 동일 4개 TC에서 `FATAL` |

`CBRD-27800` 없이 오류 주입(fault injection)이나 OOM으로 병렬 힙 스캔만 단독 실행하는 재현은 아직 수행하지 않았다.

## Expected Result

병렬 힙 스캔 중 `heap_attrinfo_read_dbvalues()`가 실패하면 `next_qualified_slot_with_peek()`가 즉시 `S_ERROR`를 반환하여, 서버 `FATAL`/core나 이전 행 값 재사용 없이 원래 오류 코드(예: `-1398` 또는 `ER_OUT_OF_VIRTUAL_MEMORY`)를 질의 오류로 돌려준다.

## Actual Result

`11.5.0.2997-de4bb11` release `ha_repl`(`mainId=6255`, `cbrd_25717_overflow_record.test`)의 slave server에서 동일한 core stack 5건이 발생했다.

```text
SUMMARY : [Core dumped in heap_attrinfo_access at src/storage/heap_file.c:13244]
#0  raise () from /lib64/libc.so.6
#1  abort () from /lib64/libc.so.6
#2  er_log (err_id=<optimized out>) at src/base/error_manager.c:1819
#3  er_set_internal (severity=0, err_id=-2, ...) at src/base/error_manager.c:1546
#4  er_set (severity=0, file_name=".../src/storage/heap_file.c", line_no=13244, err_id=-2, num_args=0)
#5  heap_attrinfo_access (attrid=12, attr_info=<optimized out>) at src/storage/heap_file.c:13244
#7  fetch_peek_dbval_slow (..., tplrec=0x0, ...) at src/query/fetch.c:1717
#9  fetch_val_list (..., tplrec=0x0, peek=1) at src/query/fetch.c:2210
#10 parallel_scan::slot_iterator::next_qualified_slot_with_peek (...) at src/query/parallel/px_scan/px_scan_slot_iterator.cpp:165
#11 parallel_scan::task<1, 0>::drain_slot_oids (...) at src/query/parallel/px_scan/px_scan_task.cpp:850
```

## Additional Information

### ANALYSIS에서 확인할 사항

- `px_scan_slot_iterator.cpp` 내 다른 오류 전파·재시도 경로 점검: 예컨대 `px_scan_slot_iterator.cpp:119`에서 `heap_next_1page()` 호출 시 지역 변수 `is_peeking` 대신 멤버 `m_is_peeking`을 넘겨 `goto restart_scan_oid` 재시도 후에도 계속 `PEEK`로 호출되는 점이나, `drain_slot_oids()`(`px_scan_task.cpp`)가 워커의 `S_ERROR`를 코디네이터로 누락 없이 전파하는지 함께 확인한다.
- 워커 첫 행 실패(`FATAL`/core)와 후속 행 실패(이전 행 값 재사용) 두 경로 모두를 검증하는 단위 테스트 또는 오류 주입 회귀 테스트 추가 필요 여부를 결정한다.

### 관련 이슈

- [CBRD-27800](https://jira.cubrid.org/browse/CBRD-27800): `ha_repl`에서 OOS 레코드 손상(`-1398`)을 일으켜 이 결함의 `FATAL`/core를 드러낸 트리거 이슈.
- [CBRD-26722](https://jira.cubrid.org/browse/CBRD-26722): `px_scan_slot_iterator.cpp`가 포함된 병렬 스캔 확장 작업.
- [CBRD-26769](https://jira.cubrid.org/browse/CBRD-26769): OOS 읽기 실패를 `heap_attrinfo_read_dbvalues()`까지 전파하도록 정리한 이슈.

### 분류 제안

- JIRA 유형: `Correct Error`
- 문제 범주: `Correctness / data integrity`, `Reliability / recovery`
- 컴포넌트: `px_scan` (`src/query/parallel/px_scan/px_scan_slot_iterator.cpp`)
