# [OOS] CDC가 vacuum으로 회수된 OOS 값 체인을 참조해 추출 실패 및 서버 crash 발생

## Issue Triage

### 목적

OOS 컬럼을 포함한 UPDATE/DELETE 로그를 CDC 및 flashback이 비동기로 읽을 때, heap의 old version이 vacuum된 이후에도 변경 전 값을 안전하고 정확하게 추출할 수 있도록 한다.

### 이유

| 구분 | 내용 |
|---|---|
| AS-IS | supplemental log의 record image에는 OOS payload가 아니라 OOS 값 체인을 가리키는 inline reference가 남는다. CDC가 해당 로그를 읽기 전에 vacuum이 old version의 OOS 값 체인을 회수하면 CDC는 이미 유효하지 않은 reference를 따라간다. |
| 현재 한계 | CDC의 consumer LSA는 archive log 삭제를 막지만, 그 로그가 참조하는 OOS 값 체인의 수명은 보호하지 않는다. WAL은 남아 있어도 CDC가 필요한 변경 전 값은 먼저 사라질 수 있다. |
| 영향 | OOS 컬럼의 UPDATE/DELETE 추출이 누락되거나 `cubrid_log_extract()`가 실패한다. assert가 활성화된 build에서는 `cub_server`가 `oos_check_head_header()`에서 crash한다. 같은 DML 변환 경로를 사용하는 flashback도 영향 가능성이 있다. |
| TO-BE | CDC/flashback이 읽을 수 있는 로그의 before/after image는 vacuum 진행 여부와 무관하게 materialize 가능해야 하며, 유효하지 않은 OOS reference로 서버가 crash하면 안 된다. |

### 방안

필수 invariant는 "CDC/flashback에서 아직 소비 가능한 log record가 참조하는 값은 정확하게 복원 가능해야 한다"이다. 구현 방향은 CDC/OOS 담당자 합의 전이므로 `TBD`로 둔다.

| 후보 | 개요 | 장점 | 비용 및 확인 사항 |
|---|---|---|---|
| CDC용 durable payload 기록 | supplemental log 생성 시 OOS 값을 실제 payload로 materialize하여 CDC가 heap/OOS 수명에 의존하지 않게 한다. | CDC와 vacuum 수명을 분리하고, CDC 지연에도 결과가 안정적이다. | WAL 증가량, 압축, log format 호환성, recovery log와 CDC 전용 정보의 경계를 설계해야 한다. |
| OOS 회수 시점 지연 | CDC/flashback safe LSA가 전진할 때까지 해당 old OOS 값 체인을 vacuum이 보존한다. | 기존 CDC record decoding 구조의 변경을 줄일 수 있다. | log LSA와 OOS chain의 수명 연결이 필요하고, 느리거나 중단된 consumer 때문에 OOS 공간이 장기간 증가할 수 있다. |
| Hybrid | 일정 범위는 OOS를 보존하고, 장기 보존이 필요한 경우 CDC용 payload로 전환한다. | WAL과 OOS 공간 증가를 절충할 수 있다. | 상태 및 recovery가 복잡해지고 두 경로의 경계 조건을 추가 검증해야 한다. |

유효하지 않은 OOS reference를 만나 DML을 누락하거나 NULL로 대체하는 방식은 CDC 데이터 정확성을 깨뜨리므로 해결책으로 사용하지 않는다. 구현 방향 결정 시 CDC 비활성 상태, consumer 재접속, flashback 시간 범위, archive 강제 삭제 설정에서의 보존 상한도 함께 정의해야 한다.

---

## AI-Generated Context

> 아래 내용은 AI가 PR의 exact commit, CircleCI artifact 및 source code를 교차 분석해 작성했다. 관찰된 사실과 원인 추론을 구분했으며, 구현 전 CDC/OOS 담당자의 검토가 필요하다.

### Summary

- 분석 대상: <https://github.com/CUBRID/cubrid/pull/6864>, `feat/oos` -> `develop`
- exact commit: `725a32c6ee0d7cb2b27dedd2283b03a9a93de608`
- CircleCI shell job: <https://circleci.com/gh/CUBRID/cubrid/145308>
- 전체 shell 결과: 3,238건 중 3,184 success, 24 failure, 30 skipped
- 이 이슈의 범위: 24개 failure 중 CDC의 `cbrd_27064`, `cbrd_27075` 2건
- 분석 방식: CircleCI artifact와 exact-commit source trace. 별도 local 실행 결과는 이 결론의 근거에 포함하지 않았으며, 요청 이후 추가 재현 및 vacuum timing isolation 실험을 수행하지 않았다.
- 결론 신뢰도: 높음. crash stack, DML별 결과 차이, OOS record contract 및 vacuum cleanup 경로가 동일한 lifetime gap을 가리킨다.

## Description

PR #6864의 OOS branch CircleCI에서 기존 CDC 회귀 TC 2건이 새롭게 실패했다.

```text
shell/_37_elderberry/cbrd_23842_cdc/bug/cbrd_27075/cases/cbrd_27075.sh
shell/_37_elderberry/cbrd_23842_cdc/bug/cbrd_27064/cases/cbrd_27064.sh
```

두 TC가 원래 검증하던 CBRD-27064와 CBRD-27075의 CDC log-page boundary 수정은 분석 commit에 이미 포함되어 있다.

```text
f771eb824  [CBRD-27064] Fix CDC log page references across page boundaries
a404cc564  [CBRD-27075] Fix CDC timestamp lookup on continuation-only log pages
```

또한 두 TC 모두 기존 문제의 판별 조건인 `ER_LOG_PAGE_CORRUPTED` 발생 횟수가 0이다. 따라서 이번 실패는 기존 boundary bug의 재발이 아니라, OOS record image를 CDC가 DB_VALUE로 변환하는 새 경로에서 발생한다.

## Test Build

| 항목 | 값 |
|---|---|
| Version | CUBRID 11.5.0.2524-725a32c |
| Revision | `725a32c6ee0d7cb2b27dedd2283b03a9a93de608` |
| Branch | `feat/oos` |
| PR | <https://github.com/CUBRID/cubrid/pull/6864> |
| CircleCI workflow | `58dd4c06-8faa-42a1-87ec-8bc3a4f805bd` |
| CircleCI job | `test_shell` #145308, 50-way parallel |
| Job time | 2026-08-12 12:41:33Z - 13:15:20Z |

## Repro

CircleCI에서 다음 기존 CDC TC가 실패한다. 아래 내용은 CI에 실행된 기존 TC의 scenario를 정리한 것이며, 별도 local 실행 결과는 증거에 포함하지 않았다.

### `cbrd_27075`

- 4KB, 8KB, 16KB page size별로 page size의 5배인 비압축 BIT VARYING payload를 사용한다.
- 동일 row를 두 payload로 번갈아 2,000회 UPDATE한다.
- workload와 CDC의 `cubrid_log_find_lsa()` / `cubrid_log_extract()` 호출을 겹쳐 실행한다.
- `supplemental_log=1`, `log_compress=no`, `log_max_archives=2`, `force_remove_log_archives=yes`를 사용한다.

### `cbrd_27064`

- 4KB page에서 약 16,000-20,380 byte의 비압축 BIT VARYING payload를 사용한다.
- overflow payload에 대해 INSERT 700건, DELETE 700건, UPDATE 2,400건을 각각 CDC로 추출한다.
- before-image를 조건 컬럼에 포함하는 `all_in_cond=1` 경로를 사용한다.

## Expected Result

- OOS payload를 사용하는 INSERT, UPDATE, DELETE가 모두 CDC에서 정확한 건수와 값으로 추출되어야 한다.
- CDC consumer가 DML보다 늦더라도, 아직 소비 가능한 WAL의 before/after value를 복원할 수 있어야 한다.
- `cubrid_log_find_lsa()` 및 `cubrid_log_extract()`가 오류를 반환하지 않아야 한다.
- OOS inline reference의 head/length 검증에서 서버가 assert 또는 crash하면 안 된다.
- 기존 CBRD-27064/27075의 판별 조건인 log page corruption이 발생하면 안 된다.

## Actual Result

### `cbrd_27075`

`cub_server` core가 발생했다.

```text
Core dumped in oos_check_head_header at src/storage/oos_file.cpp:1679

oos_check_head_header
  -> oos_read
  -> heap_attrvalue_read_oos_inline
  -> heap_attrvalue_point_variable
  -> heap_attrvalue_read
  -> heap_attrinfo_read_dbvalues
  -> cdc_make_dml_loginfo
  -> cdc_log_extract
  -> cdc_loginfo_producer_execute
```

page size별 결과는 다음과 같다. 모든 설정에서 기존 log-page corruption은 0이지만 CDC 조회 또는 추출이 실패했다.

| Page size | Workload | CDC result | Log-page corruption |
|---:|---:|---|---:|
| 4KB | `FINAL_SEQ=2000` | `FIND_OK=30`, `EXTRACT_ERR=2`, `TOTAL_ITEMS=294` | 0 |
| 8KB | `FINAL_SEQ=-1` | `FIND_OK=2`, `FIND_ERR=28`, `EXTRACT_ERR=2`, `TOTAL_ITEMS=0` | 0 |
| 16KB | `FINAL_SEQ=2000` | `FIND_OK=30`, `EXTRACT_ERR=4`, `TOTAL_ITEMS=331` | 0 |

최종 결과는 `CONFIGS_OK=0/3`이다.

### `cbrd_27064`

같은 OOS payload에서 INSERT는 통과하지만 old value가 필요한 DELETE와 UPDATE가 실패했다.

| DML | 기대 건수 | 실제 CDC 결과 | Log-page corruption |
|---|---:|---:|---:|
| INSERT | 700 | 700, extractor rc=0 | 0 |
| DELETE | 700 | 19에서 중단, extractor rc=1 | 0 |
| UPDATE | 2,400 | 1에서 중단, extractor rc=1 | 0 |

CDC client log에는 실패 시 `cubrid_log_extract()`의 `rc=-10`이 기록된다.

## Additional Information

### Root Cause Assessment

다음 원인으로 판단한다.

```text
UPDATE / DELETE commit
  -> supplemental WAL의 undo/redo RECDES에 16-byte OOS inline reference 저장
       [OOS head OID | full payload length]
  -> CDC consumer가 WAL을 비동기로 처리하기 전에 vacuum 진행
  -> old heap version과 그 version만 참조하던 OOS chain 회수
  -> CDC가 WAL에서 RECDES를 복원
  -> cdc_make_dml_loginfo()가 heap_attrinfo_read_dbvalues() 호출
  -> OOS inline reference를 Resolve하기 위해 oos_read() 호출
  -> 삭제되었거나 재사용된 slot의 header가 원래 OID/length와 불일치
  -> rc=-10 또는 oos_check_head_header() assert로 cub_server crash
```

OOS는 heap record에 payload 대신 16-byte inline reference를 저장한다. record의 `HAS_OOS` flag와 variable offset tag가 해당 값의 Resolve 필요 여부를 나타낸다. CDC가 WAL에서 undo/redo RECDES를 복원한 뒤 `cdc_make_dml_loginfo()`에서 `heap_attrinfo_read_dbvalues()`를 호출하면, OOS attribute는 `heap_attrvalue_read_oos_inline()`을 거쳐 `oos_read()`로 실제 값을 읽는다.

반면 OOS vacuum은 MVCC 관점에서 더 이상 보이지 않는 old row version의 undo image에서 OOS OID를 찾아 `oos_delete()`로 체인을 회수한다. 현재 CDC의 `consumer.start_lsa`는 archive log volume 삭제 시점만 제한한다. vacuum의 OOS 체인 회수 조건에는 CDC/flashback safe LSA가 포함되지 않는다.

따라서 WAL record 자체가 보존되어 있어도 그 record가 가리키는 OOS payload는 먼저 없어질 수 있다. 삭제된 OOS slot이 재사용되면 inline reference가 가리키는 위치에서 `chunk_index != 0` 또는 `total_data_length != expected_length`가 검출된다. `cbrd_27075`의 `oos_check_head_header()` crash는 이 검증 지점과 정확히 일치한다.

### Why INSERT Passes but UPDATE/DELETE Fail

INSERT의 redo image가 가리키는 OOS chain은 현재 live row가 계속 참조하므로 CDC가 읽을 때 남아 있을 가능성이 높다. DELETE와 UPDATE의 undo image는 과거 값의 OOS chain을 필요로 하며, 해당 old version이 vacuum 대상이 되면 체인이 먼저 회수될 수 있다. `cbrd_27064`에서 INSERT 700/700은 통과하고 DELETE/UPDATE만 즉시 실패하는 결과가 이 차이를 뒷받침한다.

### Scope

- 직접 영향: OOS-backed variable attribute를 포함한 CDC UPDATE/DELETE, 특히 before-image를 요구하는 `all_in_cond=1`.
- 잠재 영향: `cdc_make_dml_loginfo(..., is_flashback=true)`를 사용하는 flashback DML materialization.
- 비영향 근거: 기존 CBRD-27064/27075 log-page boundary bug의 fix는 포함되어 있고, 이번 CI에서 `ER_LOG_PAGE_CORRUPTED=0`이다.
- 확인 필요: release build에서 assert가 비활성화된 경우 반환 오류와 CDC producer 상태, 삭제 slot 재사용 전후의 오류 일관성.

### Required Verification after Fix

- 기존 `cbrd_27064`, `cbrd_27075` 전체 통과.
- 4KB, 8KB, 16KB page에서 OOS INSERT/UPDATE/DELETE의 정확한 건수와 byte-identical 값 검증.
- CDC consumer를 지연시키고 vacuum이 old version을 처리한 뒤에도 before/after value 추출 성공.
- `all_in_cond=0/1` 모두 검증.
- flashback의 동일 OOS DML 조회 검증.
- server restart/recovery 및 archive rollover 후에도 동일 결과 보장.
- 선택한 보존 방식에 따른 WAL 또는 OOS 공간 증가량 측정과 상한 정의.

### Evidence

- PR: <https://github.com/CUBRID/cubrid/pull/6864>
- CircleCI test result: <https://app.circleci.com/pipelines/github/CUBRID/cubrid/34481/workflows/58dd4c06-8faa-42a1-87ec-8bc3a4f805bd/jobs/145308/tests>
- CDC crash path: `src/transaction/log_manager.c`, `src/storage/heap_file.c`, `src/storage/oos_file.cpp`
- OOS vacuum path: `src/query/vacuum_oos.cpp`, `src/storage/oos_file.cpp`
