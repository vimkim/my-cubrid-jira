# 코멘트 #2 — 설계 옵션 비교 상세 (코드 인용 · LOC 견적 · WAL/HA/btree 호환성)

> 본 코멘트는 description 의 "설계 옵션 비교 — 권장안 요약" 의 근거 자료다. 옵션 A/B/C 각각에 대한 코드 인용·grep 집계·Pros/Cons·LOC 견적·이중 압축 회피 술어를 포함한다. Description 본문 길이 제약 (≈ 32 KB) 을 피하기 위해 분리.

## 비교 대상

| ID | 명칭 | 한 줄 요약 |
|---|---|---|
| **A** | OOS 진입 직전 공통 압축 | 현 VARCHAR 압축은 그대로 두고, OOS 적재 직전에 (선택적으로 비-VARCHAR 가변 타입까지) LZ4 로 한 번 감싼다 |
| **B** | `data_writeval` / `pr_do_db_value_string_compression` 일반화 | 현 VARCHAR 와 동일한 시점·동일한 메커니즘을, 다른 가변 타입에도 확장. OOS-layer 는 추가 압축 안 함 |
| **C** | VARCHAR 압축 제거 + OOS-layer 로 단일화 | `pr_do_db_value_string_compression` / `or_put_varchar_internal` 의 압축 분기 제거, 압축은 오직 OOS 레이어 |

## 현재 압축 메커니즘이 박혀 있는 코드 면적 (영향 범위의 기준선)

조사 시점의 grep 집계 (`~`/`.orig` 백업 파일 제외). 사용한 명령:

```bash
# or_put_varchar 류 (6 파일 / 40 hits)
grep -rn --include="*.c" --include="*.cpp" --include="*.h" --include="*.hpp" \
  -E "or_put_varchar|or_packed_varchar_length|or_get_varchar" src/ \
  | grep -v -E '\.orig|\.c~'

# compressed_* (12 파일 / 165 hits, .i 포함)
grep -rn --include="*.c" --include="*.cpp" --include="*.h" --include="*.hpp" --include="*.i" \
  -E "compressed_size|compressed_buf|DB_TRIED_COMPRESSION|DB_UNCOMPRESSABLE" src/ \
  | grep -v -E '\.orig|\.c~'
```

| 식별자 | 정의 위치 | 호출/참조 파일 수 | 총 라인 hit |
|---|---|---|---|
| `pr_do_db_value_string_compression` | `object_primitive.c:14260` | 1 파일 (object_primitive.c 내부 2 호출) | 2 |
| `or_put_varchar_internal` 의 `compressable` 분기 | `object_representation.c:788-900` | 1 정의 | ~110 |
| `or_get_varchar_compression_lengths` | `object_representation.h:2149` (STATIC_INLINE) | 5 파일 | 14 호출 |
| `or_put_varchar` / `or_packed_varchar_length` / `or_get_varchar*` 류 | `object_representation.{c,h}` | **6 파일** (object_primitive.c · object_representation.{c,h} · object_representation_sr.c · network_interface_sr.cpp · query_executor.c) | **40 hits** |
| `compressed_size` / `compressed_buf` / `DB_TRIED_COMPRESSION` / `DB_UNCOMPRESSABLE` (DB_VALUE 필드) | `dbtype_def.h` | **12 파일** (object_representation.h · compressor.hpp · network_interface_sr.cpp · db_macro.c · dbtype_function.{h,i} · dbtype_def.h · dbtype.h · load_sa_loader.cpp · object_primitive.{h,c} · parse_evaluate.c) | **약 165 hits** |
| `pr_Enable_string_compression` 토글 | `object_primitive.c:882` | 2 파일 (`object_primitive.c`, `object_representation.c`) | 4 |

핵심 관찰:

- **압축은 사실상 OR-buf 레이어 (`or_put_varchar_internal`) 에서 이미 일어난다.** `pr_do_db_value_string_compression` 은 `DB_VALUE` 에 결과를 캐시해 두기 위한 사전 호출이며, 디스크 바이트열 자체는 OR helper 가 그 자리에서 `cubcompress::compress` (LZ4 specialization) 를 돌린다 (`object_representation.c:840-870`).
- 이 결과는 length prefix 가 `[byte=charlen ≤ 254] | [byte=255 sentinel + int compressed_len + int decompressed_len + bytes]` 두 모드로 나뉘며, **모든 reader (heap, btree, HA log, network, recovery)** 가 `or_get_varchar_compression_lengths` 한 곳을 거쳐 이 layout 을 해석한다.
- 따라서 VARCHAR 압축은 **변경 시 디스크 포맷·WAL 포맷·HA wire 포맷 동시 변경** 이며, 옵션 B/C 가 비싼 진짜 이유는 LOC 가 아니라 이 호환성 면이다.

## A. OOS 진입 직전 공통 압축

### 개요

- **쓰기 hook**: `heap_attrinfo_insert_to_oos` (`heap_file.c:12485`) — `oos_insert (...)` 호출 직전에 `recdes.data` 를 LZ4 로 감싸고 작은 헤더 (`algo:1B + orig_size:4B`) 를 prepend.
- **읽기 hook 후보 (모두 OOS 페이로드를 다시 가져옴)**:
  - (live) `heap_attrvalue_read_oos_inline` (`heap_file.c:10601-10645`) — `oos_read` 직후 헤더 검사 → 압축 표식이면 LZ4 decompress. 인라인-OOS attr value 읽기의 단일 entry.
  - (dead) `heap_record_replace_oos_oids_with_values_if_exists` (`heap_file.c:7962`) — `heap_file.c:7931, 7953` 두 호출처 (REC_RELOCATION, REC_HOME)에서 진입하지만 함수 첫 줄 `return S_SUCCESS;` (`heap_file.c:7966-7968`) 로 차단되어 있음. 주석: "HOTFIX! todo: this function is buggy. by doing this, we give up unloaddb."
- **Option A 적용 가능성**: HOTFIX 가 살아 있는 동안에는 hook 을 `heap_attrvalue_read_oos_inline` 하나에만 두면 충분. **HOTFIX 가 해제되어 `heap_record_replace_oos_oids_with_values_if_exists` 가 실제로 OOS 를 재읽기 시작하면, 같은 decompress hook 을 두 번째 entry 에도 반드시 복제해야 한다.** 후속 티켓에서 HOTFIX 상태와 묶어 추적한다.
- **이중 압축 회피**: VARCHAR 는 OR-buf 단계에서 이미 LZ4 결과가 들어 있으므로 OOS-layer 압축을 unconditionally skip. (case C: 가장 단순하고 안전).
- **OOS 헤더 변경**: 현 `OOS_RECORD_HEADER` (`oos_file.hpp:26-31`) 는 `total_data_length / chunk_index / next_chunk_oid` 세 필드만 보유. **버전 / 알고리즘 ID 슬롯 없음.** 따라서 압축 메타 식별은 다음 둘 중 하나로 결정해야 한다.
  - (a) `OOS_RECORD_HEADER` 에 `uint8_t version` / `uint8_t algo` 필드 추가 (포맷 break — feat/oos 가 unreleased 이므로 이번 release 안에서만 흡수 가능).
  - (b) 페이로드 prefix 에 magic/sentinel 바이트 (예: `0xC0 0xMP` + algo:1B + orig_size:4B) 를 두고 OOS_RECORD_HEADER 는 그대로 유지 — 비압축 페이로드와 magic 충돌 가능성은 압축 토글 OFF 인 페이로드에서만 발생하므로, 압축 토글 ON 인 OOS 페이로드는 항상 magic 으로 시작한다고 invariant 를 둔다.

### Pros

- **변경 면적 최소.** OOS 경로 2~3 함수에 국한 (HOTFIX 해제 후에는 3 함수). type 시스템·OR helper·btree·HA·recovery 무관.
- **VARCHAR 디스크 포맷 변경 0** → 기존 데이터 무손실, 인라인 (non-OOS) 행에 한해 롤링 업그레이드 가능. **feat/oos 가 아직 release 되지 않았으므로 OOS 페이지 자체에는 호환성 부채가 없다** (released DB 에 OOS 페이지가 존재하지 않음).
- 토글 한 줄로 OFF 시 원래 거동 회귀.
- 압축 효과가 큰 JSON / SET / MULTISET / SEQUENCE / VARBIT 가 즉시 혜택.
- 향후 알고리즘 교체 (zstd 등) 가 OOS 레이어 안에서 self-contained.

### Cons / Side-effect

- **압축 정책이 두 곳에 공존** (VARCHAR 는 OR-layer, 나머지는 OOS-layer). 유지보수자가 "이 타입은 어디서 압축되나" 추적 필요. → docs 로 1쪽 짜리 가이드로 완화 가능.
- **이중 압축 회피 분기가 정확해야 함.** VARCHAR 의 OR 결과를 다시 LZ4 에 넣으면 거의 안 줄고 헤더만 늘어남.
- **OOS 헤더 또는 payload prefix 의 식별자 슬롯 신설 필요** → 옵션 (a) 면 `OOS_RECORD_HEADER` 한 번 break, 옵션 (b) 면 magic invariant 문서화 필요.
- **HOTFIX 해제 시 hook 누락 위험.** `heap_record_replace_oos_oids_with_values_if_exists` 가 부활하면 동일 decompress 분기를 빠뜨리지 않도록 후속 PR 에서 같이 들어가야 한다.
- **non-VARCHAR 가변 컬럼 (VARBIT/JSON/SET/MULTISET/SEQUENCE) 의 인라인 ↔ OOS 비대칭.** 인라인 (≤ 512B) 은 비압축, OOS (> 512B) 는 압축으로 같은 컬럼이 행 크기에 따라 압축 여부가 달라진다. VARCHAR 는 인라인에서도 ≥ 255B 면 이미 LZ4 압축되므로 비대칭 영향 없음. JSON/SET 류는 OOS 진입 임계 자체가 512B 이므로 영향 범위가 "큰 행" 으로 한정.
- **카탈로그 컬럼 영향.** 시스템 카탈로그 뷰 (`schema_system_catalog_install_query_spec.cpp` 기준 `VARCHAR(255)` 37 컬럼 + 일부 query_spec 컬럼이 `VARCHAR(1073741823)` 의 클래스 컬럼을 참조) 가 OOS 로 분기되는 경우 압축 페이로드가 카탈로그 reader 에 전달된다. 카탈로그 row 는 일반 heap row 와 같은 경로를 타므로 Option A 의 hook 두 곳을 거치면 자동으로 decompress 된다 → **카탈로그 전용 추가 작업은 불필요**, 단 OOS 진입 카탈로그 row 가 실제로 발생하는지 (현 catalog 가 large blob 컬럼을 가진 경우) 는 단위 테스트로 한 번 더 확인 필요.

### 예상 LOC (테스트 제외)

| 위치 | 추정 라인 |
|---|---|
| `heap_file.c`: insert hook + read hook + 이중-압축 skip 분기 | 80 |
| `oos_file.{hpp,cpp}`: 헤더 슬롯 + 페이로드 wrapper 헬퍼 | 60 |
| 신규 `oos_compress.{hpp,cpp}` (LZ4 wrapper) | 100 |
| `system_parameter`: 토글 추가 | 20 |
| 단위 + SQL/Shell 테스트 | 200 |
| **합계** | **약 400~500 LOC** |

## B. `data_writeval` / `pr_do_db_value_string_compression` 일반화

### 개요

- `pr_do_db_value_string_compression` 의 `if (db_type != DB_TYPE_VARCHAR)` 가드 해제 + VARBIT / JSON / SET / MULTISET / SEQUENCE 의 `lengthval`·`writeval`·`readval` 콜백에 동일한 압축 분기 복제.
- 각 타입에 평행한 `or_put_TYPE_compressed` / `or_get_TYPE_compression_lengths` OR helper 신설 (`TYPE` 자리에 varbit/json/set/multiset/sequence).
- 압축 메타 (compressed_length / decompressed_length / sentinel byte) 가 디스크 포맷·인덱스 키 포맷에 동시 진입.

### Pros

- 압축 정책이 타입 직렬화 콜백 안 한 곳에 모인다 ("타입이 자기 압축을 책임진다").
- OOS 경로 외에도, 인라인 가변 컬럼 (≤ 512B) 까지 압축 혜택 가능.
- 향후 새 가변 타입이 추가되어도 같은 패턴을 따르면 됨.

### Cons / Side-effect

- **[WARN] B-Tree 인덱스 키 포맷 변경.** btree 는 동일한 `data_writeval`/`data_readval` 콜백을 호출하므로, VARBIT/JSON 등이 인덱스 키로 쓰이는 경우 인덱스 페이지 포맷이 바뀐다. 옵션:
  - (b1) 기존 인덱스 호환성을 깬다 → 마이그레이션 강제.
  - (b2) btree 진입 경로에서만 압축 skip 분기 → 호출처 분기 폭증 + per-type 의 lengthval/writeval pair 가 caller 별 동작 분기 (heap-vs-btree).
  - (b3) **btree 인덱스 빌드 시 핫패스 영향.** `btree_load.c:2513` (sort 단계 key 직렬화), `btree_load.c:4065, 4071` (중복 키 비교) 가 `data_readval` 을 직접 호출하므로, 압축 키를 다시 매번 decompress 해야 비교 가능. 인덱스 빌드/리오그 성능 저하가 마이그레이션 비용과 별개로 발생.
- **[WARN] HA replication / WAL 포맷 변경.** WAL 의 heap insert/delete redo 레코드가 raw recdes 바이트를 그대로 적재한다. 근거:
  - `heap_file.c:22412`, `heap_file.c:22421` — `log_append_undoredo_recdes (thread_p, RVHF_INSERT, &log_addr, NULL, recdes_p);` (insert).
  - `heap_file.c:23608, 23613` — `log_append_undoredo_recdes (thread_p, RVHF_DELETE, &log_addr, &temp_recdes, NULL);` (delete).
  - `heap_file.c:20825` — `log_append_undoredo_recdes (thread_p, RVHF_MVCC_DELETE_MODIFY_HOME, ...)` (mvcc delete-modify).
  - 즉 `data_writeval` 결과가 그대로 recdes 페이로드가 되어 WAL 에 박힌다. 타입별 압축이 데이터 바이트 layout 을 바꾸면 동일한 RVHF_* recovery handler 가 새/구 양쪽을 디코드할 수 있어야 하며, HA replication 도 동일 페이로드를 슬레이브에 그대로 전달하므로 master/slave 동시 업그레이드가 필수. 롤링 업그레이드 불가.
- **[WARN] 카탈로그 영향.** system catalog 컬럼이 VARCHAR 외에 JSON 으로 확장된 경우 (없는 경우라도 향후 추가 시) 카탈로그 포맷이 새 DB 와 호환 안 됨.
- `or_get_varchar_compression_lengths` 호출처 14곳을 타입별로 곱하면 신규 helper 호출처가 30~40 곳으로 증가.
- `lengthval` ↔ `writeval` ↔ `readval` triple 의 invariant 가 깨지지 않도록 5 종 타입에 동일한 케어 필요.

### 예상 LOC

각 행의 근거를 명시한다. 출처 없는 행은 "조사 필요" 로 표기.

| 위치 | 추정 라인 | 근거 |
|---|---|---|
| `object_primitive.c`: VARBIT/JSON/SET/MULTISET/SEQUENCE 의 length/write/read × 5 종 | 600 | 현 `mr_lengthval_string_internal`/`mr_writeval_string_internal` (`object_primitive.c:10498-10650`) 가 약 150 LOC 라인 → 5 종 복제 시 대략 600~750 |
| `object_representation.{c,h}`: 신규 OR helper (5 종) | 400 | `or_put_varchar_internal`/`or_get_varchar*` (`object_representation.c:788-900`) 약 80~110 LOC → 5 종 복제 |
| btree 경로 보정 (인덱스 키 포맷 호환) | 조사 필요 | `btree_load.c:2513, 4065, 4071` + 검색·삽입 경로 모두 영향, 정확한 분기 수는 별도 조사 |
| HA replication / WAL path (recovery handler + replication writer) | 조사 필요 | `log_append_undoredo_recdes` 호출 8 곳 (`heap_file.c:20825, 22412, 22417, 22421, 23104, 23608, 23613, 24497`) 의 새/구 포맷 분기. 단, replication.c / log_manager.c 자체에는 `or_put_varchar`/`compressed_*` 직접 참조 없음 (grep 결과 0 hit) — 영향은 recdes 페이로드 의미론을 거쳐 간접적임 |
| 테스트 (SQL regression, btree key 비교, HA replay) | 500 | 5 종 타입 × insert/read/index/HA 4 시나리오 |
| **합계** | **약 1,500~2,000 LOC + 인덱스/HA 호환성 부채** | 일부 행은 조사 필요로 표시했으므로 상한은 더 커질 수 있음 |

## C. VARCHAR 압축 제거 + OOS-layer 로 단일화

### 개요

- `pr_do_db_value_string_compression`, `or_put_varchar_internal` 의 `compressable` 분기, `or_get_varchar_compression_lengths`, DB_VALUE 의 `compressed_*` 필드, `DB_TRIED_COMPRESSION`/`DB_UNCOMPRESSABLE` 상태 등 일체 제거.
- 압축 정책은 OOS-layer 단일 위치.

### Pros

- 코드 중복 제거. 압축 관련 grep 패턴이 `pr_data_compress_string` 한 함수로 줄어든다 (현재 직접 호출 1 사이트 + `pr_do_db_value_string_compression` 경유 2 사이트 → OOS-layer 한 사이트).
- DB_VALUE 라이프사이클이 단순해진다 (`compressed_*` 참조 12 파일 약 165 hits 제거 대상).
- 미래의 유지보수자가 압축 동작을 한 곳에서 이해 가능.

### Cons / Side-effect

- **[CRITICAL] 기존 데이터베이스 비호환.** VARCHAR ≥ 255B 가 들어 있는 모든 페이지 (heap + 카탈로그 + btree 인덱스 키) 가 현 `or_get_varchar_compression_lengths` 로 디코드된다. 이 함수 제거 시 기존 페이지 read 불가 → **dump/restore 마이그레이션 강제.**
- **[CRITICAL] WAL 비호환.** 기존 WAL 의 heap insert/update redo 레코드 (`log_append_undoredo_recdes (thread_p, RVHF_INSERT, ...)` — `heap_file.c:22412, 22421`) 가 압축 VARCHAR 를 담은 raw recdes 바이트열을 그대로 적재한다. recovery 시 동일 recdes 가 `data_readval` 로 풀리므로, VARCHAR 압축 분기를 제거하면 기존 WAL redo 가 디코드 불가 → 재기동 실패.
- **[CRITICAL] HA replication 비호환.** 마스터-슬레이브 동시 변경 필수, 누적 replication log 도 호환 reader 필요. (replication 도 동일한 recdes 페이로드를 전달하므로 WAL 호환성과 운명이 같다.)
- 결과적으로 **"permanent backward-compat reader" 유지가 필수** 이므로 코드 제거 효과의 절반 이상이 상쇄.
- 단순 grep 으로 "VARCHAR 압축이 박힌 곳" 만 12 파일 약 165 hits 이며, 그 중 다수가 매크로/타입 라이프사이클이라 일괄 grep-replace 불가.

### 예상 LOC

| 작업 | 추정 라인 |
|---|---|
| 제거: `object_primitive.c` (~150) + `object_representation.c` (~80) + `dbtype*.{h,i}` (~30) + `db_macro.c` (~30) + `query_executor.c` (~20) + `network_interface_sr.cpp` (~40) | **−350** |
| 신설: legacy compressed-varchar 디코드 유지 reader (WAL redo · 기존 heap/btree 페이지 read 경로용) | +200 |
| DB version gate + 마이그레이션 도구 (unloaddb/loaddb 확장) | +300 |
| 테스트 (기존 회귀 + 신규 백워드 호환) | +400 |
| **합계** | **약 1,200~1,500 LOC** (단, 비기능 비용 — 마이그레이션 검증·회귀·문서·고객 영향이 LOC 비례 이상) |

> 주: 이전 견적에 포함됐던 `replication.c` / `log_manager.c` 제거 행은 삭제했다. 두 파일에서 `or_put_varchar` / `compressed_*` 직접 참조를 grep 한 결과 0 hit 으로, 해당 파일은 압축 코드 자체를 갖지 않고 recdes 페이로드를 그대로 통과시키기만 한다. WAL/HA 호환 부담은 "신설: legacy reader" 행에 흡수했다.

## 권장안 및 근거 (상세)

근거:

1. **본 작업의 목적은 다음 측정 가능한 비대칭을 메우는 것이다**: JSON / VARBIT / SET / MULTISET / SEQUENCE 컬럼이 OOS 진입 임계 (> 512B) 를 넘긴 행에서 OOS 페이지 압축 후 크기 / 원본 크기 비율 ≤ 0.7 (LZ4 기준) 을 달성. Option A 단일 변경으로 이 목적이 충족된다.
2. **현 VARCHAR 압축은 production 안정 단계.** CBRD-20158 (`b049ba5ee`, 2018) 에서 처음 도입된 후 CBRD-21558 (`cd36742df`, inline 함수화), CBRD-22638 / CBRD-22993 (NCHAR varying / VARNCHAR 보정), CBRD-23703 / CBRD-26324 (LZ4 라이브러리 교체 및 `cubcompress::compress` (LZ4 specialization) API 정착) 까지 7년에 걸친 다수 패치로 안정화되었다. 디스크 / WAL / HA 포맷에 같은 기간 박혀 있으며, B / C 는 LOC 가 아니라 호환성 측면에서 비싸다.
3. **C 가 "너무 breaking 한가?" 의 답: 예, 너무 breaking 합니다.** 단순 LOC 만 보면 1,200~1,500 이지만 disk + WAL + HA 포맷이 동시에 바뀐다. 정량 비교:
   - **호환 부담 차원 수**: A = 1 (OOS payload prefix), B = 3 (인덱스 + WAL + HA wire), C = 4 (heap + WAL + HA + 카탈로그).
   - **마이그레이션 강제 여부**: A = 없음, B = 인덱스 키 포맷에 따라 있음, C = 필수 (dump/restore).
   - **롤링 업그레이드 가능**: A = 가능 (non-OOS 인라인 행 한정, OOS 자체는 unreleased), B = 불가, C = 불가.
   - 즉 같은 1.0~1.5K LOC 라도 A 대비 B/C 의 실제 비용은 검증 surface 와 고객 영향까지 합쳐 수배 (concrete multiplier 는 별도 산정 필요하나 위 차원 수만으로도 단일 자릿수 multiple).
4. A 안은 변경이 **OOS 레이어 + `system_parameter` 토글 한 곳으로 국한** 된다. 후속 알고리즘 교체 (LZ4 → zstd) 도 같은 layer 안에서 self-contained.

이중 압축 회피는 **case C (VARCHAR 일 때 OOS-layer 압축 skip)** 권장. skip 술어를 명시:

```
skip_oos_compression(value) :=
  DB_VALUE_DOMAIN_TYPE(value) == DB_TYPE_VARCHAR
  && charlen >= OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION  // 255
```

이는 현 `pr_do_db_value_string_compression` (`object_primitive.c:14260`) 의 게이트와 동일 조건이므로, OR-layer 가 압축을 시도한 경우 ↔ OOS-layer 가 skip 하는 경우가 정확히 일치한다 (false-positive/negative 0). **VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE 는 OR-layer 에서 압축되지 않으므로 모두 OOS-layer 압축 대상.** VARCHAR < 255B 가 OOS 로 들어가는 경우 (즉 인라인 임계 512B 와 압축 임계 255B 사이) 는 OR-layer 가 압축을 안 한 상태이므로 OOS-layer 가 그대로 압축한다.

**권장안: Option A 채택.**

> 후속 티켓 (예: CBRD-26757) 에서 다음을 다룬다:
> - `OOS_RECORD_HEADER` 버전 필드 추가 vs payload prefix magic — 둘 중 어느 방식으로 압축 메타를 식별할지 확정 (`oos_file.hpp:26-31` 의 헤더에 현재 version slot 없음).
> - HOTFIX (`heap_file.c:7966-7968`) 해제 시 `heap_record_replace_oos_oids_with_values_if_exists` 에도 동일 decompress hook 적용.
> - 알고리즘 (LZ4 vs zstd) / 임계값 / `pr_Enable_string_compression` 토글 재사용 여부.
> - 단위 / SQL / shell 테스트 계획:
>   - (i) 압축 대상 6 타입 (VARCHAR / VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE — VARCHAR 는 skip 술어 검증) 각각에 대한 OOS round-trip (insert → flush → read → compare).
>   - (ii) 알고리즘 ID dispatch — 향후 zstd 도입을 가정해 reader 가 algo 필드를 보고 분기하는 골격 테스트.
>   - (iii) 이중 압축 회피 — VARCHAR ≥ 255B 가 OOS 로 들어갈 때 OOS payload 가 OR-layer 결과를 그대로 통과 (재압축 0 회) 함을 확인.
>   - (iv) 토글 OFF 회귀 — `pr_Enable_string_compression` 또는 신규 OOS 압축 토글 OFF 시 모든 타입이 비압축 페이로드로 저장되며 read 도 정상.
