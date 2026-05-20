# [OOS] [M2] [Regression] [Top Level] 매뉴얼 테스트 결과 분석 및 실패 케이스 이슈화 2

## Issue Triage

**이슈 수행 목적**: CBRD-26660 의 follow-up. round-1 분석에서 식별된 회귀 중 CBRD-26815 / CBRD-26813 / CBRD-26814 의 부분 수정이 머지된 이후, `vk/cbrd-26815-oos-json-deserialize` 브랜치의 CircleCI shell 단계 16건 실패 TC 를 다시 4 버킷으로 분류하고 OOS 회귀에 해당하는 항목만 M2 차단 작업 큐에 남긴다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: round-1 분석 (CBRD-26660, build `11.5.0.2328-8d7b97a`, 32 NOK, `failed-tc-report.md`) 이후 CBRD-26815 (json deserialize), CBRD-26813 (`REC_BIGONE` reassembly 후 OOS OID 확장), CBRD-26814 (OOS inline metadata fit 검사) 의 부분 수정이 머지된 빌드 `11.5.0.2334-e2a5d2b` 의 CircleCI job `gh/CUBRID/cubrid/126741` (workflow `be86f0d1-d4c0-4488-8b94-344c86710fc8`) shell 단계에서 16건 NOK 잔존. 16건은 통과로 전환됐으나, LOB/ELO 클러스터(`peekmem_elo` / `readval_elo_with_type` / `lob_locator.cpp` / `src/storage/es.c`) 와 OOS UPDATE 경로(`heap_record_replace_oos_oids_with_values_if_exists`) 에 걸린 케이스가 남아 있다.
- **영향**: 미분류 상태에서는 잔존 OOS 회귀와 develop-side flaky 가 M2 마감 차단 항목으로 섞여 우선순위 판단이 불가하다. 또 round-1 에서는 보이지 않다가 새로 노출된 OOS UPDATE 의심 케이스(`cbrd_23430.sh`) 가 별도 티켓 없이 묻혀 M3 회귀로 새지 않도록 분리가 필요하다.

**이슈 수행 방안**:

- 16건을 4 버킷 — A) 잔존 OOS 회귀 9건, B) 신규 OOS 의심 2건, C) ambiguous 1건, D) develop-flaky 의심 4건 — 으로 분류한다.
- 버킷 A 의 LOB/ELO 클러스터 7건(`bug_xdbms3947`, `bug_bts_16011` SA/CS, `bug_bts_7596`, `bug_bts_10290`, `cbrd_23349`, `cbrd_24103`) 과 TDE × OOS 1건(`tbl_enc_14`) 은 round-1 sub-task CBRD-26660 의 §2.1, §2.2 분류를 그대로 승계하고 동일 fix 티켓에 묶는다. `cbrd_22803.sh` 는 OOS metaclass 추가 fetch 의 정당한 회계 변화로 보고 answer-file 갱신 후보로 남긴다.
- 버킷 B 의 신규 OOS 의심 2건(`json_long_body.sh`, `cbrd_23430.sh`) 은 본 sub-task 결과로 별도 fix sub-task 를 신규 발행한다. 사용자 인용: "Now try to find out what are left among those 16 failed TC. I'll post it as a jira comment."
- 버킷 C 의 `bug_bts_14917.sh` 는 `cub/develop` HEAD 에서 단발 재실행해 OOS 회귀 여부를 분리한다. 분류 결과는 `TBD - ANALYSIS 단계에서 결정`.
- 버킷 D 의 4건(`cbrd_20145_1`, `_itrack_1000316`, `bug_xdbms3845`, `trigger_2`) 은 본 sub-task 범위 밖. develop baseline 재현 후 answer-file 갱신 또는 무시로 처리한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: CBRD-26660 follow-up. M2 매뉴얼 테스트 round 2 결과 16 NOK 를 분류해 OOS 회귀와 환경 flaky 를 분리한다.
- **원인 / 배경**: round-1 (CBRD-26660) 32 NOK 중 16건이 CBRD-26815 / CBRD-26813 / CBRD-26814 부분 수정으로 통과. 잔존은 LOB/ELO + OOS UPDATE 경로에 집중.
- **제안 / 변경**: 4 버킷 분류 후 OOS 회귀 11건만 M2 차단 항목으로 남기고, ambiguous 1건은 develop 재실행으로 분리, flaky 4건은 별도 운영 항목으로 분리.
- **영향 범위**: M2 마감 일정, 후속 fix sub-task 발행, develop-flaky tracking.

---

## Description

본 sub-task 는 CBRD-26660 의 follow-up 이다. round-1 분석 (CBRD-26660, build `11.5.0.2328-8d7b97a`, 32 NOK) 에서 식별된 회귀 중 일부가 다음 세 sub-task 의 부분 수정으로 해결됐다:

- CBRD-26815 — OOS JSON deserialize 경로 수정 (`vk/cbrd-26815-oos-json-deserialize` 브랜치 본체)
- CBRD-26813 — `REC_BIGONE` reassembly 후 OOS OID 확장
- CBRD-26814 — OOS inline metadata fit 검사 (value-area position)

위 세 수정을 적용한 빌드 `11.5.0.2334-e2a5d2b` 의 CircleCI shell job `126741` (pipeline 29495, workflow `be86f0d1-d4c0-4488-8b94-344c86710fc8`, branch `vk/cbrd-26815-oos-json-deserialize`) 실행 결과: 3197 case 중 16 failure, 30 skipped, 3151 success.

round-1 대비 16건이 신규 통과했고, 그중 `bigPageSize.sh` 의 `or_get_int` SIGSEGV (`peekmem_elo` 스택) 가 사라진 것이 가장 큰 진전이다.

### Test Build

- Build: `11.5.0.2334-e2a5d2b` (2026-05-20)
- Branch: `vk/cbrd-26815-oos-json-deserialize`
- CircleCI: pipeline 29495 / workflow `be86f0d1-d4c0-4488-8b94-344c86710fc8` / job `126741` (test_shell)
- Tests endpoint: `https://circleci.com/api/v2/project/gh/CUBRID/cubrid/126741/tests`

### Bucket A — 잔존 OOS 회귀 (9)

| # | Test | Cluster | Symptom |
|---|---|---|---|
| 1 | `bug_xdbms3947.sh` | LOB-not-written | `INSERT INTO xoo (clob) VALUES (char_to_clob('xxx'))` 후 `testlob/` 아래 file 0개 |
| 2 | `bug_bts_16011.sh` (SA loaddb) | LOB-not-written | `loaddb` 행은 적재되나 `ces_*` 파일 누락 |
| 3 | `bug_bts_16011.sh` (CS server-side loaddb) | LOB-not-written | 서버 측 `loaddb` 경로에서도 동일 결함 |
| 4 | `bug_bts_7596.sh` | CAST CLOB/BLOB | 24 cast variant 전부 *external storage path invalid* |
| 5 | `bug_bts_10290.sh` | CAST CLOB/BLOB | `CAST(... AS CLOB)` -> *path is invalid* |
| 6 | `cbrd_23349.sh` | Mixed-type LOB | `SELECT *` -> *External file 'ces_*/...' was not found* |
| 7 | `cbrd_24103.sh` | LOB file count | 기대 file 개수 미달 |
| 8 | `tbl_enc_14.sh` | TDE x OOS | `diagdb` 출력에 `MULTIPAGE_OBJECT_HEAP / tde_algorithm: AES` 블록 누락 |
| 9 | `cbrd_22803.sh` | Cosmetic (real) | `Num_hit` / `Num_page_request` 가 각 +1. OOS metaclass 추가 fetch 의 정당한 회계 변화로 추정, answer 파일 갱신 후보 |

분류 근거: 직전 sub-task 의 §2.1 (LOB/ELO storage broken) 과 §2.2 (TDE x OOS) 가 그대로 잔존. 단일 lob-locator 수정 한 번으로 1-7 이 동반 통과할 가능성이 높다.

### Bucket B — 신규 OOS 의심 (2)

| # | Test | Symptom | Suspected cause |
|---|---|---|---|
| 10 | `json_long_body.sh` | `init_data` 로딩 후 행 수 **5,376** (기대 **54,336**, 약 10x 미달). step-1 NOK | OOS write/read 경로에서 large-body JSON 행이 silently drop |
| 11 | `cbrd_23430.sh` | `create t(j json)` -> `loaddb` 1 행 -> `alter add column i int; update t set i = 1` -> `SELECT json_length(j)` 가 `ERROR: Execute: Query execution failure #15951` 반환 (기대 `50000`) | OOS UPDATE 가 large-JSON OOS chain 을 corrupt. CBRD-26516 의 "UPDATE 가 `heap_record_replace_oos_oids` 를 3x 호출" 우려와 같은 패밀리 가능성 |

`cbrd_23430.sh` 는 1 행 / 단일 UPDATE / 단일 JSON 컬럼이라 minimal repro 로 적합. 별도 fix sub-task 발행 대상.

### Bucket C — Ambiguous, develop HEAD 재실행 필요 (1)

| # | Test | Error |
|---|---|---|
| 12 | `bug_bts_14917.sh` | `cubrid.jdbc.driver.CUBRIDException: INDEX pk_image_doc_id_image_id ON CLASS public.image (CLASS_OID: 0\|216\|1). Key and OID: 1\|577\|1 entry on B+tree: 1\|512\|513 is incorrect. The object does not exist.` |

`image` 테이블의 btree-heap key/OID 불일치. develop concurrency flaky 일 수도, OOS UPDATE/DELETE 가 btree key removal 을 chain 하지 못한 회귀일 수도 있다. develop HEAD 단발 재실행으로 분리한다.

### Bucket D — develop-side flaky / 환경 의심 (4)

| # | Test | Symptom |
|---|---|---|
| 13 | `cbrd_20145_1.sh` | `MNT_SERVER_COPY_STATS` 수신 크기 4,464 B 차이. protocol counter answer drift 후보 |
| 14 | `_itrack_1000316.sh` | TRIM/string. trailing whitespace cosmetic diff |
| 15 | `bug_xdbms3845.sh` | DB copy 유틸 테스트. diff 미확보 |
| 16 | `trigger_2.sh` | NOK timeout 727 s (cap 10 분), `_35_cherry/QEWC` heavy trigger. slow-runner flake 패턴 |

본 sub-task 범위 외. develop baseline 비교 후 answer 갱신 또는 unstable tagging 으로 처리.

### Tally

- round-1 (CBRD-26660) 대비 fixed 16건 (CBRD-26815 / CBRD-26813 / CBRD-26814 부분 수정 효과): `bigPageSize.sh`, `cbrd_25446.sh`, `tbl_enc_08.sh`, `bug_bts_5596.sh`, `cbrd_25481.sh`, `multi_queries_2.sh`, `bug_bts_8199.sh`, dblink 6건, `cbrd_23843_3`, `cbrd_26111`, `cbrd_24046`, `bug_bts_9617`, `check_option`, `bug_bts_16030`
- Still-OOS to fix: 직전 9건 + 신규 2건 = **11건** (A + B)
- Verify on develop: 1건 (C)
- Likely flaky: 4건 (D)

### Recommended Next Steps

1. LOB locator 단일 수정으로 Bucket A 의 1-7 (8 포함 가능) 동반 통과를 노린다.
2. `cbrd_23430.sh` 로컬 재현으로 OOS UPDATE / `json_length` 회귀 minimal repro 를 확립한다.
3. `bug_bts_14917.sh` 를 `cub/develop` HEAD 에서 1 회 재실행해 bucket C 를 분리한다.
4. Bucket D 는 develop rebaseline 이후 answer 파일 갱신 또는 unstable tagging 으로 처리한다.

---

## Remarks

- 부모/선행 sub-task: CBRD-26660 (round-1 매뉴얼 테스트 결과 분석, build `11.5.0.2328-8d7b97a`, 32 NOK). 분석본 원본은 workspace `failed-tc-report.md`.
- round-1 대비 본 round 의 fix 들어간 sub-task: CBRD-26815 (OOS JSON deserialize, 본 브랜치), CBRD-26813 (`REC_BIGONE` reassembly 후 OOS OID 확장), CBRD-26814 (OOS inline metadata fit 검사). 세 sub-task 가 CBRD-26660 에서 제기된 회귀 중 일부를 부분적으로 해결.
- 관련 티켓: CBRD-26516 (UPDATE 가 `heap_record_replace_oos_oids` 를 3x 호출), CBRD-26517 (OOS TODO)
