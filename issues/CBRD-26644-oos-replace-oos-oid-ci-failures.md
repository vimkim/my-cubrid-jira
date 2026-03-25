# [OOS] heap_record_replace_oos_oids 재활성화 후 CI 실패 분석 (PR #6945)

## Description

### 배경

`heap_record_replace_oos_oids_with_values_if_exists()` 함수(`src/storage/heap_file.c:7922`)에서 HOTFIX로 비활성화되어 있던 early return(`return S_SUCCESS`)을 주석 처리하여 OOS OID 치환 로직을 재활성화하는 PR을 제출하였다.

- PR: https://github.com/CUBRID/cubrid/pull/6945
- Base branch: `feat/oos`
- CircleCI: [Job 119993](https://app.circleci.com/pipelines/github/CUBRID/cubrid/27355/workflows/92e2eca0-5398-4837-922d-35834d36699c/jobs/119993) — 3207개 테스트 중 18개 실패 

 변경 내용 (1줄):

```diff
-  return S_SUCCESS;
+  // return S_SUCCESS;
```

 변경 전 (HOTFIX): 함수가 즉시 반환하여 OOS OID가 실제 값으로 치환되지 않음. `unloaddb` 등에서 OOS 데이터를 처리할 수 없었음.

 변경 후 (이 PR): `heap_attrinfo_read_dbvalues` → `heap_attrinfo_transform_to_disk_develop_ver` 를 통해 OOS OID를 인라인 값으로 치환하는 로직이 다시 동작함.

### 목적

18개 실패 TC를 카테고리별로 분류하고, 이 PR로 인한 실패와 기존 실패를 구분하여 수정 방향을 제시한다.

---

## Analysis

### 재활성화된 함수의 알려진 제한사항

1. PEEK 모드 미지원  — `context->ispeeking == PEEK` 일 때 `assert(false)` 발생 (line 7939). debug 빌드에서 서버 crash.
2. S_DOESNT_FIT — 확장된 레코드가 `context->recdes_p->area_size` 를 초과하면 반환 (line 7983).
3. `heap_attrinfo_transform_to_disk_develop_ver` 에 schema 변경 시 `repid_bits` 위험 관련 TODO 존재.

---

### 카테고리 1: OOS 레코드 PEEK 모드 crash (5건) — 이 PR로 인한 실패

OOS 저장소를 트리거하는 대용량 데이터(VARCHAR > page size, JSON > 1MB)가 포함된 레코드에 대해 쿼리 스캔이 PEEK 모드로 접근할 때, `assert(false)` 에 의해 debug 빌드에서 서버가 crash된다.

| # | TC | 데이터 타입 | OOS 트리거 | 실패 증상 |
|---|-----|-----------|------------|---------|
| 1 | `_35_cherry/issue_21522_json/cbrd_23349` | 24개 컬럼: VARCHAR(10757), STRING ~1MB, JSON ~1MB, CLOB, BLOB | 다중 OOS 컬럼 | `External file "ces_647/dba.t.0001774..." was not found` |
| 2 | `_35_cherry/issue_21522_json/cbrd_23430` | JSON (50000개 원소, ~1MB) | 대용량 JSON | `Query execution failure #15826` |
| 3 | `_36_damson/cbrd_23608_tde/tbl_enc_08` | VARCHAR(20000) ENCRYPT | 20KB varchar → OOS | diagdb 출력 불일치 (expected 7줄, got 11줄 — OOS overflow 항목 추가) |
| 4 | `_36_damson/cbrd_23608_tde/tbl_enc_14` | VARCHAR(20000) ENCRYPT PK | 20KB varchar → OOS | diagdb 출력 불일치 (MULTIPAGE_OBJECT_HEAP 항목 추가) |
| 5 | `_06_issues/_17_2h/cbrd_21517` | 인덱스가 있는 다중 컬럼 테이블 | OOS 데이터 | `Internal error: INDEX idx1 ON CLASS dba.foo. Key and OID: 0\|4545\|1 entry on B+tree is incorrect. The object does not exist.` |

 원인 분석 :

호출 경로:

```
heap_get_visible_version_internal / heap_get_last_version
  → heap_get_record_data_when_all_ready
    → (REC_HOME) spage_get_record(... context->ispeeking)  // PEEK 가능
    → heap_record_replace_oos_oids_with_values_if_exists
      → if (!heap_recdes_contains_oos) return S_SUCCESS;  // 비-OOS는 정상
      → if (context->ispeeking == PEEK) { assert(false); }  // CRASH!
```

일반적인 쿼리 스캔은 성능을 위해 PEEK 모드를 사용한다. OOS 플래그가 설정된 레코드를 만나면 서버가 crash하며, 이로 인한 연쇄 실패가 발생한다:

- 서버 프로세스 종료
- 후속 쿼리/연산 실패
- 외부 LOB 파일 접근 불가 ("External file not found")
- B+tree 무결성 검증 실패 ("object does not exist")

 수정 방향 :

1. COPY 모드 강제 전환  — OOS 데이터가 감지되면 PEEK → COPY로 전환 후 치환 수행
2. PEEK에서 OOS 치환 건너뛰기  — `unloaddb` 등 전체 데이터가 필요한 호출자는 COPY 모드를 사용하므로, PEEK에서는 S_SUCCESS 반환
3. PEEK 모드 정식 지원  — 새 버퍼를 할당하여 치환 후 recdes 포인터 갱신

```c
// 옵션 A: heap_get_record_data_when_all_ready의 REC_HOME 경로 (line 7890-7907):
case REC_HOME:
    ...
    scan = spage_get_record(..., context->ispeeking);
    if (scan != S_SUCCESS) return scan;

    // PEEK 모드에서는 OOS 치환 건너뛰기 (가장 단순, 안전)
    if (context->ispeeking == PEEK)
        return S_SUCCESS;  // 호출자는 OOS OID가 포함된 raw 레코드를 받음
    return heap_record_replace_oos_oids_with_values_if_exists(thread_p, context);
```

---

### 카테고리 2: LOB/CLOB 외부 저장소 에러 (6건) — 기존 실패 또는 연쇄 실패

CLOB/BLOB과 소량의 데이터를 사용하는 테스트들이다. LOB locator는 heap record 내에서 ~60-80 bytes로 저장되며 OOS 저장소를 트리거하지 않는다. `heap_recdes_contains_oos()` 가 `false` 를 반환하므로 이 PR의 변경으로 영향받지 않아야 한다.

| # | TC | 데이터 타입 | 실패 증상 |
|---|-----|-----------|---------|
| 1 | `_06_issues/_12_2h/bug_bts_10290` | CLOB (13 bytes) | `Path for external storage 'file:ces_088/...' is invalid` |
| 2 | `_06_issues/_12_2h/bug_bts_7596` | CLOB + BLOB | `Path for external storage 'file:ces_058/...' is invalid` |
| 3 | `_06_issues/_15_1h/bug_bts_16011` | CLOB + BLOB | unloaddb/loaddb 후 SELECT 결과 누락 |
| 4 | `_35_cherry/.../bug_bts_16011` (loaddb_CS) | CLOB + BLOB | server-side loaddb 후 SELECT 결과 누락 |
| 5 | `_06_issues/_10_2h/bug_xdbms3845` | BLOB + CLOB | copydb 후 NOK |
| 6 | `_06_issues/_10_2h/bug_xdbms3947` | CLOB | sub-test 3 NOK (LOB base path) |

 원인 분석 :

두 가지 가능성이 있다:

1. feat/oos 기존 실패 : OOS feature branch에서 외부 저장소 관련 변경이 있어 이 PR과 무관하게 LOB 테스트가 실패할 수 있음.
2.  연쇄 실패 : CI가 병렬로 테스트를 실행할 때, 카테고리 1의 서버 crash가 같은 노드의 후속 LOB 테스트에 영향을 줄 수 있음.

 권장 조치 : `feat/oos` base branch의 CI 결과와 비교하여 기존 실패 여부를 확인.

---

### 카테고리 3: B+tree / 인덱스 불일치 (2건) — 이 PR 관련 (연쇄)

| # | TC | 실패 증상 |
|---|-----|---------|
| 1 | `_06_issues/_14_2h/bug_bts_14917` | `Internal error: INDEX pk_image_doc_id_image_id ON CLASS public.image (CLASS_OID: 0\|213\|2). Key and OID: 1\|513\|1 entry on B+tree: 1\|448\|449 is incorrect. The object does not exist.` |
| 2 | `_06_issues/_17_2h/cbrd_21517` | `Internal error: INDEX idx1 ON CLASS dba.foo (CLASS_OID: 0\|213\|2). Key and OID: 0\|4545\|1 entry on B+tree is incorrect. The object does not exist.` |

 원인 분석 :

두 실패 모두 동일한 패턴을 보인다: B+tree 인덱스 항목이 참조하는 heap OID를 읽을 수 없음. 두 가지 가능한 메커니즘:

1. PEEK 모드 crash 연쇄 : OOS 레코드를 PEEK 모드로 읽을 때 서버가 crash(`assert(false)`)하며, 복구 과정이나 후속 연산에서 해당 레코드를 참조하는 인덱스 항목이 불일치로 보임.
2. OOS 치환 에러 반환 : OOS 치환 함수가 실패(`S_DOESNT_FIT` 또는 `S_ERROR`)하면 호출자가 레코드를 읽을 수 없는 것으로 처리. 인덱스 검증 시 디스크에 존재하지만 성공적으로 읽을 수 없는 레코드에 대해 "object does not exist" 보고.

 참고 : 두 테스트 모두 `CLASS_OID: 0|213|2` 패턴을 보여 OOS 레코드 접근 실패라는 공통 원인을 시사한다.

---

### 카테고리 4: 에러 코드 / 연결 변경 (1건) — 기존 실패 가능성

| # | TC | 실패 증상 |
|---|-----|---------|
| 1 | `_06_issues/_13_1h/bug_bts_10721` | 예상 에러 코드 -677, 실제 -191 (`Cannot connect to server`) |

 원인 분석 : 에러 코드 -191(` 서버 연결 실패 `) vs 예상 -677. `feat/oos` 의 무관한 변경이거나 같은 parallel group 내 서버 crash로 인한 연쇄 실패일 수 있다.

---

### 카테고리 5: 일시적 / 경미 / 원인 불명 실패 (4건)

| # | TC | 실패 증상 | CI 상세 분석 |
|---|-----|---------|------------|
| 1 | `_35_cherry/.../json_long_body` | sub-test 1 NOK |  일시적  — 데이터 초기화 시 54,336행 중 5,376행만 로드.  재시도 시 통과. PR 무관. |
| 2 | `_03_itrack/_itrack_1000316` | 출력 차이 (경미) | 행 수 1줄 불일치, 데이터 값은 일치. 기존 실패 가능성. |
| 3 | `_06_issues/_22_1h/cbrd_24103` | sub-test 4,9 NOK (10개 중) | CLOB + heap header + LOB 권한. 로컬 재현 필요. |
| 4 | `_06_issues/_14_1h/bug_bts_12381` | NOK | 에러 로그에서 "Create the overflow key file" 출현 2회 예상, 1회만 발견. overflow 파일 생성 타이밍 이슈. |
| 5 | `_35_cherry/.../bigPageSize` | Test failed | JSON 출력 포맷/공백 차이. 기존 실패 가능성. |

 권장 조치 : `feat/oos` 와 `feat/oos-replace-oos-oid` 양쪽에서 로컬 실행하여 신규 실패 여부 확인.

---

## Summary

| 카테고리 | 건수 | 이 PR 원인? | 근본 원인 |
|---------|------|-----------|----------|
| 1. OOS PEEK crash | 5 | Yes | PEEK 모드에서 OOS 레코드 접근 시 `assert(false)` |
| 2. LOB/CLOB 에러 | 6 | 기존 실패 가능성 | feat/oos 브랜치의 LOB 경로 이슈 |
| 3. B+tree 불일치 | 2 | Yes (연쇄) | OOS 레코드 읽기 실패 → "object does not exist" |
| 4. 에러 코드 변경 | 1 | 기존 실패 가능성 | 연결 에러 코드 불일치 |
| 5. 일시적/경미/불명 | 4 | No / Unknown | 일시적(json_long_body), 포맷, 로컬 재현 필요 |
|  합계  | 18 | 7건 확인  | |

---

## Acceptance Criteria

- [ ] PEEK 모드에서 OOS 레코드 접근 시 `assert(false)` crash가 발생하지 않도록 수정
- [ ] 카테고리 1의 5개 TC가 통과하도록 수정
- [ ] `feat/oos` base branch CI 결과와 비교하여 카테고리 2 (LOB/CLOB) 실패가 기존 실패인지 확인
- [ ] B+tree 불일치 (카테고리 3) 2건이 PEEK 수정 후 해소되는지 확인
- [ ] diagdb answer 파일(tbl_enc_08, tbl_enc_14)이 OOS 관련 새로운 heap 파일 타입을 반영하도록 업데이트 검토

---

## Remarks

### 참고 코드

| 파일 | 라인 | 설명 |
|-----|------|------|
| `src/storage/heap_file.c` | 7916-8001 | `heap_record_replace_oos_oids_with_values_if_exists()` — 재활성화된 함수 |
| `src/storage/heap_file.c` | 7851-7913 | `heap_get_record_data_when_all_ready()` — 호출자 (PEEK/COPY 분기) |
| `src/storage/heap_file.c` | 7939 | PEEK 모드 `assert(false)` 위치 |
| `src/storage/heap_file.c` | 27772-27776 | `heap_recdes_contains_oos()` — OOS 플래그 확인 |
| `src/storage/heap_file.c` | 13366-13369 | `heap_attrinfo_transform_to_disk_develop_ver()` — OOS→값 변환 |

### 관련 이슈

- CBRD-26570: `feat/oos` → `develop` 머지 시 CircleCI 실패 분석 (이전 분석, 동일 TC 다수 겹침)
- CBRD-26537: `heap_recdes_contains_oos` API 구현
- CBRD-26637: OOS 에러 핸들링 리팩터링

### 후속 작업

1. P0: `heap_record_replace_oos_oids_with_values_if_exists` 에서 PEEK 모드 처리 수정
2. P1: `feat/oos` base branch CI와 비교하여 기존 실패 분리
3. P2: tbl_enc_08/tbl_enc_14 diagdb answer 파일 업데이트 검토
4. P3: 카테고리 5의 불명확한 TC를 로컬에서 debug 모드로 실행
