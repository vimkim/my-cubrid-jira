# CBRD-26756 설계 옵션 비교 — 작업 리포트

- **작업 일자**: 2026-05-19
- **작업자**: Daehyun Kim
- **JIRA**: [CBRD-26756](http://jira.cubrid.org/browse/CBRD-26756) (OOS 값 압축 메커니즘 분석)
- **부모 이슈**: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)
- **대상 코드베이스**: `/home/vimkim/gh/cb/oos-storage` (branch `feat/oos`)

---

## 1. 작업 배경

구두 피드백 요청사항:

> 다음 두 수준에 대해서 논의 후 설계 단계에서 구체화 시키기로 하였는데요.
> 이슈에 다음 두가지 방안에 대한 장/단과 우려되는 side-effect 정리 요청하셨습니다.
> 대현님이 생각하는 결론까지 적어두고, 최종 방향은 피드백 받아서 진행할께요.
>
> 1. OOS 수준에서 variable data 압축 (현 varchar 압축과 동일한 시점에서 압축 처리하고 oos는 압축 고려 안함)
> 2. 현재 varchar 압축 삭제하고 oos로 통일 — 너무 breaking changes 일까요?
>    String compression 과 엮여있는 코드가 많아서…? 한번 견적 뽑아보겠습니다.

본 작업은 위 요청에 대한 코드 기반 견적 + 권장안 작성.

---

## 2. 비교 대상 3가지

| ID | 명칭 | 한 줄 요약 |
|---|---|---|
| **A** | OOS 진입 직전 공통 압축 | 현 VARCHAR 압축은 그대로 두고, OOS 적재 직전에 LZ4 wrapper 한 번 |
| **B** | `data_writeval` / `pr_do_db_value_string_compression` 일반화 | 현 VARCHAR 와 동일한 시점·메커니즘을 다른 가변 타입에도 확장 |
| **C** | VARCHAR 압축 제거 + OOS-layer 로 단일화 | 압축 분기 일체 제거, 압축은 오직 OOS 레이어 |

---

## 3. 권장안 및 근거

**권장: Option A 채택.**

### 근거 (요약)

1. **본 작업의 목적은 OOS 로 빠지는 JSON / VARBIT / SET / MULTISET / SEQUENCE 등 비-VARCHAR 가변 타입의 압축 누락을 메우는 것** 이며, A 하나로 충족.
   - 측정 기준: LZ4 기준 OOS 페이지의 압축 후/원본 크기 비율 ≤ 0.7 목표.
2. **현 VARCHAR 압축은 CBRD-20158 도입 후 약 7년간 production 사용** 이력 (CBRD-26324 등 후속 정련) → 디스크/WAL/HA 포맷에 깊이 박혀 있음. 건드릴수록 비용 증가.
3. **호환성 부담 차원 수**: A=1 (OOS 페이지만), B=3 (heap + btree key + HA wire), C=4 (heap + btree key + HA wire + 카탈로그/WAL replay).
4. **변경 면적이 OOS 레이어 + `system_parameter` 토글로 한정** → self-contained 확장성.

### Option C ("varchar 압축 제거 후 OOS 로 통일") 가 너무 breaking 한가? — **예, 너무 breaking 합니다.**

- 단순 LOC 합산은 ~1,200~1,500 line 이지만,
- 디스크 포맷 + WAL + HA wire + 카탈로그가 동시에 깨짐 → dump/restore 마이그레이션 강제,
- legacy compressed-VARCHAR reader 영구 유지 필요 → 제거 효과 절반 이상 상쇄,
- 마이그레이션·롤링업그레이드·QA 회귀 비용까지 합쳐 실 비용은 A 의 multiple.

---

## 4. LOC 견적 (테스트 제외)

| 옵션 | 추정 LOC | 호환성 부채 |
|---|---|---|
| **A** | **약 400~500** | 없음 (feat/oos 미릴리즈) |
| **B** | 약 1,500~2,000 | btree 인덱스 키 포맷 + HA wire 변경 |
| **C** | 약 1,200~1,500 + 마이그레이션 비용 | [CRITICAL] 기존 DB + WAL + HA 전부 비호환 |

### Option A 세부 (about 400~500 LOC)

- `heap_file.c`: insert hook + read hook + 이중-압축 skip 분기 ≈ 80
- `oos_file.{hpp,cpp}`: 헤더 슬롯 + 페이로드 wrapper ≈ 60
- 신규 `oos_compress.{hpp,cpp}` (LZ4 wrapper) ≈ 100
- `system_parameter`: 토글 추가 ≈ 20
- 단위 + SQL/Shell 테스트 ≈ 200

### 이중 압축 회피 정책 (Option A 의 핵심 결정)

- **Skip predicate**: `db_type == DB_TYPE_VARCHAR && charlen >= 255`
- **이유**: `pr_do_db_value_string_compression` 의 게이트와 동일하므로 OR-buf 단계에서 이미 압축된 바이트열을 식별 가능.
- **나머지 가변 타입** (VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE) 은 모두 OOS-layer 압축 적용.

---

## 5. 코드베이스 영향 면적 (조사 결과)

`/home/vimkim/gh/cb/oos-storage` (branch `feat/oos`) 에서 grep 으로 측정:

| 식별자 | 파일 수 | 라인 hit |
|---|---|---|
| `pr_do_db_value_string_compression` 호출 | 1 (object_primitive.c 내부) | 2 |
| `or_put_varchar_internal` 의 `compressable` 분기 | 1 정의 | ~110 라인 |
| `or_get_varchar_compression_lengths` 호출 | 5 파일 | 14 호출 |
| `or_put_varchar` / `or_packed_varchar_length` / `or_get_varchar*` 류 | 6 파일 | 40 hits |
| `compressed_size` / `compressed_buf` / `DB_TRIED_COMPRESSION` / `DB_UNCOMPRESSABLE` | 12 파일 | ~165 hits |
| `pr_Enable_string_compression` 토글 | 2 파일 | 4 hits |

**핵심 관찰**: 압축은 사실상 OR-buf 레이어 (`or_put_varchar_internal`) 에서 일어남. `pr_do_db_value_string_compression` 은 `DB_VALUE` 에 캐시하기 위한 사전 호출이며, 디스크 바이트열은 OR helper 가 직접 `cubcompress::compress<LZ4>` 수행 (`object_representation.c:840-870`).

→ VARCHAR 압축은 변경 시 **디스크 포맷 + WAL 포맷 + HA wire 포맷** 이 동시에 바뀜. Option B / C 가 비싼 진짜 이유는 LOC 가 아니라 이 호환성 면.

---

## 6. 검증 절차

본 권장안은 두 단계로 검증되었음:

### Stage 1: 코드 정적 분석

- `heap_file.c` (28K 라인) 의 OOS insert/read 경로 직접 확인
  - `heap_attrinfo_insert_to_oos` (`:12429-`)
  - `heap_attrvalue_read_oos_inline` (`:10601-10645`)
  - `heap_record_replace_oos_oids_with_values_if_exists` (`:7962-`) — **현재 HOTFIX 로 `return S_SUCCESS;` 무조건 반환 (dead path)**
- `oos_file.{hpp,cpp}` 의 `oos_insert` / `oos_read` 시그니처 (`oos_buffer` 기반) 확인
- `or_put_varchar_internal` 의 압축 분기 (`object_representation.c:788-900`) 직접 read
- `btree_load.c:2513, 4065, 4071` 의 `data_readval` 호출 → btree 인덱스 키도 `data_writeval`/`data_readval` 콜백을 공유함을 확인
- HA replication 경로는 `log_append_undoredo_recdes` (`heap_file.c:22412, 22421` 등 8 사이트) 가 heap record 바이트열을 그대로 WAL 에 기록 → VARCHAR 압축 포맷이 WAL/HA 에 그대로 전파됨

### Stage 2: Grill-and-Revise (적대적 리뷰 루프)

- **Round 1 (critic agent, Opus)**: 20개 정량 결함 지적. 주요 항목:
  - LOC 수치 hallucination (75 hits → 실제 40, 14 파일 → 실제 12)
  - 누락 코드 경로 (HOTFIX dead code, btree_load.c `data_readval`, WAL RVHF_INSERT)
  - 한자 (multiple, self-contained, single location, 잘 동작하고, 비대칭을 메우는) → 정량 지표 요구
  - VARNCHAR / charlen<255 edge case 미해결
  - OOS_RECORD_HEADER 버전 필드 부재 미해결
  - 시스템 카탈로그 영향 미언급
- **Round 2 (executor agent, Opus)**: 20개 지적사항 전체를 코드 인용 (file:line) 으로 반영, 수치 grep 으로 재계산
- **Round 3 (critic agent, Opus, 최종)**: spot-check 통과 → **VERDICT: APPROVED**

---

## 7. 후속 작업 (별도 후속 티켓 예정)

1. **OOS_RECORD_HEADER 또는 OOS payload prefix 의 압축 메타 슬롯 스펙 확정**
   - 옵션 (a) header 에 version field 신설 (format break, feat/oos 미릴리즈므로 허용)
   - 옵션 (b) payload prefix 에 magic + algo + orig_size (header invariant 유지)
2. **알고리즘 / 임계값 선정**: LZ4 / pglz / zstd 비교, `pr_Enable_string_compression` 재사용 여부.
3. **VARCHAR skip 분기의 정확성 테스트**: 위 case-C (skip predicate) 검증.
4. **테스트 매트릭스**:
   - (i) 각 가변 타입 (VARCHAR/VARNCHAR/VARBIT/JSON/SET/MULTISET/SEQUENCE) round-trip insert→read
   - (ii) 알고리즘 ID dispatch (forward-compat)
   - (iii) VARCHAR 이중 압축 회피
   - (iv) `pr_Enable_string_compression` OFF 시 거동
5. **HOTFIX 해제 의존성**: `heap_record_replace_oos_oids_with_values_if_exists` 의 HOTFIX 가 풀리는 시점에 동일한 decompression hook 을 추가해야 함.

---

## 8. 결과물

- **JIRA 본문 수정안**: `~/gh/my-cubrid-jira/issues/CBRD-26756-oos-value-compression.md`
  - line 300 이하 "## 설계 옵션 비교 (구두 피드백 사항, 2026-05-19 추가)" 섹션이 본 리포트의 최종 형태.
  - critic agent 가 코드 인용으로 검증한 후 APPROVED 상태.
- **본 리포트**: 작업 요약 (이 파일).

---

## 9. 다음 액션

1. 위 JIRA 본문 수정안을 검토 후 JIRA 에 반영.
2. 피드백 수령 후 최종 방향 결정.
3. 결정된 방향에 따라 후속 티켓 (Option A 구현용) 발행.
