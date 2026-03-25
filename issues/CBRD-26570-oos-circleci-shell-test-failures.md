# [OOS] feat/oos CircleCI Shell Test 실패 분석 (PR #6864)

## Description

### 배경

`feat/oos` -> `develop` 머지 PR (#6864)의 CircleCI shell test에서 15개 TC가 실패했다.

- **PR**: https://github.com/CUBRID/cubrid/pull/6864
- **CircleCI**: https://app.circleci.com/pipelines/github/CUBRID/cubrid/27286/workflows/50de801e-0548-4215-918e-bcc244e05508/jobs/119813/tests

OOS(Out-of-Slot)는 ~2K를 초과하는 컬럼 값을 heap record 내부가 아닌 별도의 `FILE_OOS` 파일에 저장하는 기능이다.

### 목적

15개 실패 TC를 OOS 관련 여부로 분류하고, 각각의 실패 원인을 분석하여 수정 방향을 제시한다.

---

## Analysis

### 핵심 발견

`heap_record_replace_oos_oids_with_values_if_exists()` 함수(`src/storage/heap_file.c:7921`)가 현재 ** 즉시 `S_SUCCESS` 를 반환하며 비활성화 ** 되어 있다. TODO 주석으로 "this function is buggy. by doing this, we give up unloaddb."라고 기록되어 있다.

이로 인해 heap record에 OOS OID가 포함된 경우, 실제 값으로 치환되지 않아 LOB locator 해석 실패, unloaddb 데이터 손실 등 다수의 연쇄 실패가 발생한다.

---

### 카테고리 1: LOB/External Storage 읽기 실패 (7건) — OOS 관련

CLOB/BLOB의 `CAST`, `clob_to_char()`, `blob_to_bit()` 연산 시 `ERROR: External file "ces_..."` 에러 발생. LOB locator 경로 해석이 실패한다.

| # | TC | 테스트 내용 | 실패 증상 |
|---|-----|-----------|---------|
| 1 | `_06_issues/_12_2h/bug_bts_7596` | CLOB/BLOB 생성 + select + CAST | CAST 시 external storage path 에러 |
| 2 | `_06_issues/_12_2h/bug_bts_10290` | CLOB insert + select | 동일 CAST 실패 패턴 |
| 3 | `_06_issues/_15_1h/bug_bts_16011` | CLOB/BLOB unload->load 사이클 (SA) | `clob_to_char()` 실패 + loaddb 출력 형식 변경 |
| 4 | `_35_cherry/.../bug_bts_16011` (loaddb_CS) | 동일, client-server loaddb | 동일 실패 |
| 5 | `_06_issues/_10_2h/bug_xdbms3845` | copydb + BLOB/CLOB | copydb 후 LOB 데이터 미보존 |
| 6 | `_06_issues/_10_2h/bug_xdbms3947` | `--lob-base-path` LOB 디렉터리 | sub-case 3 NOK — LOB 파일 미발견 |
| 7 | `_35_cherry/issue_21522_json/cbrd_23349` | JSON + CLOB + BLOB + varchar(10757) select | `ERROR: External file "ces_..."` |

** 원인 분석 **:

heap record에 LOB locator 컬럼이 포함되어 있고, 해당 record가 ~2K를 초과하면 OOS에 저장된다.
이후 LOB locator를 읽을 때, OOS OID 참조가 실제 LOB locator 문자열로 치환되지 않아 external storage 경로 조회가 실패한다.

```
정상 경로:
  heap record → LOB locator 문자열 → es_read() → LOB 데이터

OOS 도입 후 (broken):
  heap record → OOS OID (raw bytes) → LOB locator로 해석 시도 → "ces_..." 에러
```

** 수정 방향 **:

`heap_record_replace_oos_oids_with_values_if_exists()` 구현이 필수. 이 함수가 OOS OID를 `oos_read()` 로 실제 값으로 치환해야 LOB locator가 정상 해석된다.

---

### 카테고리 2: 대형 레코드 Unload/Load 실패 (3건) — OOS 관련

| # | TC | 테스트 내용 | 실패 증상 |
|---|-----|-----------|---------|
| 8 | `_06_issues/_24_2h/cbrd_25481` | JSON >1MB unload/load 사이클 | `length(a)` 가 예상값(1108895, 6990515) 대신 `NULL` 반환 |
| 9 | `_35_cherry/.../bigPageSize` | 다양한 타입 loaddb + 4K page | "Test failed" (diff 미제공) |
| 10 | `_03_itrack/_itrack_1000316` | loaddb + 문자열 함수 대량 데이터 | "Test failed" (diff 미제공) |

** 원인 분석 **:

`unloaddb` 가 heap record를 스캔할 때, OOS 컬럼 값이 OOS OID 상태 그대로 추출된다. `heap_record_replace_oos_oids_with_values_if_exists()` 가 비활성화되어 있기 때문이다. 결과적으로 unload된 objects 파일에 garbage 또는 NULL이 기록된다.

```
unloaddb 경로:
  heap_scan → recdes → (OOS OID 치환 필요) → objects 파일 기록

현재 (broken):
  heap_scan → recdes → OOS OID 그대로 기록 → loaddb 시 garbage/NULL
```

** 수정 방향 **:

`heap_record_replace_oos_oids_with_values_if_exists()` 구현.
record 내 `OR_MVCC_FLAG_HAS_OOS` 플래그 확인 후, 각 OOS 마커에 대해 `oos_read()` 를 호출하여 인라인 값으로 치환해야 한다.

---

### 카테고리 3: TDE + OOS diagdb 출력 불일치 (2건) — OOS 관련

| # | TC | 테스트 내용 | 실패 증상 |
|---|-----|-----------|---------|
| 11 | `_36_damson/cbrd_23608_tde/tbl_enc_08` | TDE encrypt + varchar(20000) → diagdb | `MULTIPAGE_OBJECT_HEAP` overflow 항목 누락 (AES 알고리즘) |
| 12 | `_36_damson/cbrd_23608_tde/tbl_enc_14` | TDE encrypt + varchar(20000) PK → diagdb | 동일 overflow 항목 누락 |

** 원인 분석 **:

테스트 answer 파일은 `MULTIPAGE_OBJECT_HEAP` 타입의 overflow 파일이 `tde_algorithm: AES` 로 나타나길 기대한다. OOS 도입 후, 대형 varchar(20000) 데이터가 `FILE_OOS` 타입 파일에 저장되므로 `diagdb -d1` 출력이 달라진다.

answer 파일 기대값:
```
type = MULTIPAGE_OBJECT_HEAP
tde_algorithm: AES
```

실제 출력 (OOS 후):
```
type = OUT_OF_LINE_OVERFLOW_STORAGE   (또는 해당 항목 미출력)
tde_algorithm: ???
```

** 수정 방향 (2가지)**:

1. **answer 파일 업데이트 **: `FILE_OOS` / `OUT_OF_LINE_OVERFLOW_STORAGE` 출력에 맞게 기대값 수정
2. **TDE 암호화 전파 확인 **: `FILE_OOS` 생성 시 부모 heap의 `tde_algorithm` 을 상속하는지 확인 — 미상속 시 보안 버그

---

### 카테고리 4: OOS 무관 (3건)

| # | TC | 테스트 내용 | 실패 증상 | 비고 |
|---|-----|-----------|---------|------|
| 13 | `_06_issues/_22_1h/cbrd_24103` | LOB 디렉터리 권한 (umask) | sub-case 4,9 NOK | 환경/권한 문제 가능성. `show heap header` 출력 형식 미변경 확인 |
| 14 | `_06_issues/_13_1h/bug_bts_10721` | JDBC broker 에러 코드 | 에러 코드 `-191` vs 기대값 `-677` | OOS 무관. 에러 코드 변경 별도 확인 필요 |
| 15 | `_35_cherry/issue_22015_QEWC/trigger_2` | 동시 trigger DDL + DML (JDBC) | 730초 초과 timeout | 동시성/locking regression 또는 CI 환경 불안정 |

---

## Summary

| 카테고리 | 건수 | OOS 관련 | 핵심 원인 |
|---------|------|---------|---------|
| LOB 읽기 실패 | 7 | **Yes** | OOS OID 미치환 → LOB locator 해석 실패 |
| Unload/Load 실패 | 3 | **Yes** | `heap_record_replace_oos_oids_with_values_if_exists()` 비활성화 |
| TDE diagdb 불일치 | 2 | **Yes** | `FILE_OOS` 신규 타입 answer 미반영 / TDE 전파 미확인 |
| OOS 무관 | 3 | **No** | 에러 코드 변경, timeout, 권한 |

**15건 중 12건이 OOS 관련.** 가장 영향력 큰 단일 수정은 `heap_record_replace_oos_oids_with_values_if_exists()` 구현이며, 이를 통해 LOB 실패 7건 + Unload/Load 실패 3건 = **10건을 해결 ** 할 수 있다.

---

## Acceptance Criteria

- [ ] `heap_record_replace_oos_oids_with_values_if_exists()` 구현하여 OOS OID를 실제 값으로 치환
- [ ] LOB 관련 7건 TC 통과 확인 (`bug_bts_7596`, `bug_bts_10290`, `bug_bts_16011` x2, `bug_xdbms3845`, `bug_xdbms3947`, `cbrd_23349`)
- [ ] Unload/Load 관련 3건 TC 통과 확인 (`cbrd_25481`, `bigPageSize`, `_itrack_1000316`)
- [ ] TDE answer 파일 업데이트 또는 `FILE_OOS` TDE 전파 구현 (`tbl_enc_08`, `tbl_enc_14`)
- [ ] OOS 무관 3건은 별도 이슈로 분리 (`cbrd_24103`, `bug_bts_10721`, `trigger_2`)

---

## Remarks

- `heap_record_replace_oos_oids_with_values_if_exists()` 위치: `src/storage/heap_file.c:7921`
- OOS OID 감지 플래그: `OR_MVCC_FLAG_HAS_OOS`
- OOS 값 읽기 API: `oos_read()` (`src/storage/oos_file.cpp`)
- OOS 파일 타입: `FILE_OOS` (`src/storage/file_manager.h`)
- diagdb 출력명: `OUT_OF_LINE_OVERFLOW_STORAGE` (`src/storage/file_manager.c:3059-3080`)
- PR: https://github.com/CUBRID/cubrid/pull/6864

### 참고 코드

| 파일 | 설명 |
|------|------|
| `src/storage/heap_file.c` | `heap_record_replace_oos_oids_with_values_if_exists()` — 비활성화된 핵심 함수 |
| `src/storage/oos_file.hpp` | `oos_read()`, `oos_insert()`, `oos_delete()` API 선언 |
| `src/storage/oos_file.cpp` | OOS 파일 구현 |
| `src/storage/file_manager.h` | `FILE_OOS` 파일 타입 정의 |
| `src/storage/file_manager.c` | `FILE_OOS` → `"OUT_OF_LINE_OVERFLOW_STORAGE"` 출력 |
| `src/transaction/locator_sr.c` | `locator_fixup_oos_oids_in_recdes()` — insert 시 OOS OID 고정 |
