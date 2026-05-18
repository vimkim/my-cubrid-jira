# [OOS] heap_get_visible_version 에서 class repr 없이 OOS OID 치환

## Issue Triage

**이슈 수행 목적**: `heap_record_replace_oos_oids` 가 class repr 없이 동작하도록 다시 구현해 HOTFIX 를 해제하고, 이 확장이 불필요한 내부 caller 에게는 `heap_get_visible_version_skip_oos_expand` 라는 명시적 opt-out 경로를 제공한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `heap_record_replace_oos_oids_with_values_if_exists` 는 본문 전체가 `return S_SUCCESS;` 한 줄짜리 HOTFIX 다 (`src/storage/heap_file.c`, M1 시점에 들어감). 이전 구현이 `heap_attrinfo_start` → `heap_attrinfo_read_dbvalues` → `heap_attrinfo_transform_to_disk_develop_ver` 의 무거운 경로를 거치며 class repr 캐시 경합을 일으켜 실용이 불가했기 때문이다.
- **영향**: 설계 의도 훼손 + 기능 작동 불가. `heap_get_visible_version` 의 contract 는 "OOS 를 모르는 호출자에게도 정상 레코드를 돌려준다" 인데 HOTFIX 때문에 인라인 `[OID(8B)|length(8B)]` 슬롯이 그대로 노출된다. 그 결과 `locator_repl_prepare_force`, `compactdb`, `loaddb` 등 recdes 바이트를 그대로 소비하는 경로가 OOS 테이블에서 정상 동작하지 않는다.

**이슈 수행 방안**:

- 신규 `heap_record_replace_oos_oids` 구현: VOT 워킹 (`OR_IS_OOS`, `OR_IS_LAST_ELEMENT`) + 인라인 `[OID|length(bigint)]` 직접 읽기 + `oos_read()` 로 재구성. class repr 불필요.
- 출력 VOT 는 항상 `BIG_VAR_OFFSET_SIZE` 로 작성하고 헤더의 `OR_MVCC_FLAG_HAS_OOS` 를 클리어한다.
- `HEAP_GET_CONTEXT::expand_oos` 옵션 추가, 기본값 `true` (`heap_init_get_context` 에서 초기화).
- 신규 entry point `heap_get_visible_version_skip_oos_expand` (`expand_oos = false`). 내부 스캔 hot path 4 곳을 이쪽으로 전환해 attrinfo 가 어차피 호출할 `oos_read` 와의 중복을 제거한다.
- `*_develop_ver` 함수 일체 (약 390 line) 와 `heap_file.h` extern 제거.
- `heap_scan_get_visible_version` fast-path 단축이 OOS 를 포함한 PEEK 레코드를 그대로 흘려보내지 않도록 `heap_recdes_contains_oos` 로 가드.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제**: OOS recdes 확장 경로가 HOTFIX 로 막혀 있어 OOS 비인식 클라이언트가 깨진다.
- **원인**: 기존 구현이 class repr 캐시 경합 때문에 실용이 불가능했다.
- **변경**: class repr 없이 VOT 만으로 재구성하는 신규 구현 + caller 가 확장을 끌 수 있는 opt-out 경로.
- **영향 범위**: `src/storage/heap_file.c`, `src/storage/heap_file.h`, `src/query/query_executor.c`, `src/query/scan_manager.c`. 기본 동작 (확장 on) 은 모든 외부 caller 에서 그대로 유지된다.

---

## Description

### 문제

`heap_record_replace_oos_oids` 는 OOS 가 포함된 heap recdes 를 조회할 때 16 바이트 인라인 슬롯 `[OID|length(bigint)]` 을 OOS 파일에 저장된 실제 가변 속성 바이트로 치환한다. OOS 를 모르는 호출자도 정상 레코드를 받게 하기 위한 단일 진입점이다.

문제는 이전 구현이 "값을 풀어 DB_VALUE 배열로 만든 뒤 다시 디스크 포맷으로 직렬화" 라는 한 바퀴 돌아가는 경로를 썼다는 점이다:

```
heap_attrinfo_start            # class repr 로드 (캐시 락 경합)
  -> heap_attrinfo_read_dbvalues  # 각 OOS OID 마다 oos_read
  -> heap_attrinfo_transform_to_disk_develop_ver  # 다시 직렬화
```

class repr 캐시 경합 때문에 실사용이 불가능해서 본문이 `return S_SUCCESS;` 로 치환된 채 시간이 흘렀고, 그 결과 OOS 미인식 클라이언트 경로 (`locator_sr.c` 의 replication / fetch, `unloaddb`, `compactdb` 등) 가 깨진 상태로 남아 있었다.

### 해법의 단서

최근에 도입된 `heap_recdes_get_oos_oids` 가 recdes 의 VOT 만으로 OOS OID 목록을 추출할 수 있음을 보여 줬다. 즉, class repr 없이도 recdes 바이트와 OOS 파일만으로 원본 레코드를 재구성할 수 있다. 본 PR 은 그 토대 위에서 신규 구현을 작성한다.

### 무엇을 바꿨는가

세 축이다.

1. **재구성 알고리즘 교체**: class repr / attrinfo 경유 → VOT 워킹 + `oos_read()`.
2. **확장 정책의 opt-out 채널**: 항상 확장하던 단일 contract → caller 가 `expand_oos = false` 로 끌 수 있는 옵션.
3. **`_develop_ver` 코드 일괄 제거**: 신규 구현에 더 이상 필요 없으므로 함수 7 개와 extern 선언 삭제.

---

## Implementation

### Call-path 지도 (변경의 핵심)

| Caller | 진입점 | `expand_oos` | recdes 사용 방식 |
|---|---|---|---|
| `scan_manager.c:6310` (`scan_next_index_lookup_heap`) | `heap_get_visible_version_skip_oos_expand` | `false` | 곧바로 `eval_data_filter` + `heap_attrinfo_read_dbvalues` |
| `query_executor.c:10543` (`qexec_execute_update` LOB cleanup) | `heap_get_visible_version_skip_oos_expand` | `false` | `heap_attrinfo_read_dbvalues` 로 LOB 컬럼만 추출 |
| `query_executor.c:11353` (`qexec_execute_delete` LOB cleanup) | `heap_get_visible_version_skip_oos_expand` | `false` | 동일 패턴 |
| `query_executor.c:12188` (`qexec_execute_duplicate_key_update`) | `heap_get_visible_version_skip_oos_expand` | `false` | `heap_attrinfo_read_dbvalues` + 파티션 repr 보정 |
| `locator_sr.c` 의 모든 fetch / replication / force 경로 | `heap_get_visible_version` (기본) | `true` | recdes 바이트를 그대로 클라이언트 / replica 로 전송 |
| `catalog_class.c`, `serial.c`, `sp_code.cpp` | `heap_get_visible_version` (기본) | `true` | 시스템 테이블 - OOS 발생 X, 확장은 사실상 no-op |
| `compactdb.c` / `compactdb_sr.c` | `heap_get_visible_version` (기본) | `true` | OID 만 사용 (`recdes` 가 NULL) |
| `lock_manager.c:5553` | `heap_get_visible_version` (기본) | `true` | `lock_dump` 의 MVCC 헤더 덤프 |

**해석**: opt-out 으로 전환한 4 개 site 는 모두 "곧장 attrinfo 로 들어가는" 패턴이다. attrinfo 가 어차피 OOS 컬럼마다 `oos_read` 를 호출하므로 record 단위 확장은 중복 작업이었다. 그 외 caller 는 (a) 바이트를 그대로 외부로 보내거나 (b) OOS 자체가 발생할 수 없는 시스템 테이블이라 기본값 `true` 가 안전하다.

### `heap_record_replace_oos_oids` 의 새 알고리즘

`src/storage/heap_file.c`. 다섯 단계로 동작한다.

1. **소스 스냅샷**: PEEK 시 페이지 버퍼가 사라질 수 있으므로 `std::vector<char>` 로 입력 바이트를 복사해 두고 이후 작업은 스냅샷 위에서만 한다.
2. **VOT 워킹**: `OR_GET_OFFSET_SIZE` 로 entry 크기를 정하고, sentinel (`OR_IS_LAST_ELEMENT`) 까지 각 entry 의 `(raw offset, OOS flag)` 를 모은다.
3. **OOS blob 읽기**: OOS 플래그가 있는 index 마다 인라인 슬롯에서 OID 와 `or_get_bigint` 로 길이를 읽고, `recdes_allocate_data_area` 로 버퍼를 잡아 `oos_read(thread_p, oid, oos_buffer(buf, len))` 로 채운다. scope_exit 가드가 실패/조기-return 시 모든 버퍼를 자동 해제.
4. **출력 레이아웃 계산**: 출력 VOT 는 항상 `BIG_VAR_OFFSET_SIZE` 로 쓴다 (확장 후 offset 이 원본 offset_size 범위를 넘는 경우를 일관되게 처리). 새 레코드 크기 = `header + dst_vot + (fixed + bound-bitmap) + Σ(new value lengths)`.
5. **재구성**: 헤더를 복사한 뒤 `repid_bits` 에서 `OR_MVCC_FLAG_HAS_OOS` 와 offset-size 비트를 재조정, VOT 를 새 offset 으로 재작성 (sentinel 에 `OR_SET_VAR_LAST_ELEMENT`), fixed/bound 영역은 그대로 복사, 가변 값 영역만 OOS 인덱스에 대해 `oos_read` blob 으로, 나머지는 원본 바이트로 splicing.

PEEK 모드는 (1) 스냅샷을 만든 뒤 (2) `heap_scan_cache_allocate_recdes_data` 로 scan_cache 안에 쓰기 가능한 버퍼를 받아 `ispeeking = COPY` 로 전환한다.

### `HEAP_GET_CONTEXT::expand_oos` 옵션

`heap_init_get_context` 에서 `true` 로 초기화. 새 entry point `heap_get_visible_version_skip_oos_expand` 는 init 직후 `context.expand_oos = false` 로 덮어쓰고 `heap_get_visible_version_internal` 을 호출한다. 스캔용 `heap_scan_get_visible_version_skip_oos_expand` 도 시그니처만 다를 뿐 같은 패턴.

이름 선택: `_raw_oos` 도 후보였으나 "raw OOS data?" 와 "raw OIDs?" 모두로 읽히는 문제가 있어 동작을 직접 가리키는 `_skip_oos_expand` 를 선택했다.

### `heap_scan_get_visible_version` fast-path 보정

기존 fast-path 단축 (REC_HOME + PEEK + snapshot hit 이면 `peeked_recdes` 를 그대로 반환) 은 OOS 레코드도 그대로 흘려보냈다. 이 PR 에서 `expand_oos == true && heap_recdes_contains_oos(peeked_recdes)` 조합일 때는 단축을 우회하도록 가드를 추가했다. 그렇지 않으면 클라이언트 PEEK 경로가 여전히 확장되지 않은 레코드를 받게 된다.

### 삭제된 `_develop_ver` 함수

신규 구현에 더 이상 필요 없다. 약 390 line 분량:

- `heap_attrinfo_transform_variable_to_disk_develop_ver`
- `heap_attrinfo_transform_columns_to_disk_develop_ver`
- `heap_attrinfo_get_record_payload_size_develop_ver`
- `heap_attrinfo_determine_disksize_develop_ver`
- `heap_attrinfo_transform_header_to_disk_develop_ver`
- `heap_attrinfo_transform_to_disk_internal_develop_ver`
- `heap_attrinfo_transform_to_disk_develop_ver` (+ `heap_file.h` extern)

마지막 호출 site (`heap_record_replace_oos_oids_with_values_if_exists` HOTFIX 분기에서 `_develop_ver` 를 부르려던 부분) 는 신규 알고리즘이 대체했다.

---

## Spec Change

### 함수 시그니처

| Before | After |
|---|---|
| `heap_record_replace_oos_oids_with_values_if_exists` 본문이 `return S_SUCCESS;` HOTFIX | `heap_record_replace_oos_oids` 가 VOT walking + `oos_read()` 로 실제 재구성 |
| — | `extern SCAN_CODE heap_get_visible_version_skip_oos_expand (...)` |
| — | `extern SCAN_CODE heap_scan_get_visible_version_skip_oos_expand (...)` (선언만, caller 없음 — Remarks 참조) |
| `extern SCAN_CODE heap_attrinfo_transform_to_disk_develop_ver (...)` | **삭제** |

### `HEAP_GET_CONTEXT`

| 필드 | Before | After |
|---|---|---|
| `expand_oos` | 없음 | `bool`, `heap_init_get_context` 에서 `true` 로 초기화 |

---

## Acceptance Criteria

- [x] `heap_record_replace_oos_oids` 가 class repr 없이 `oos_read()` + VOT walking 만으로 OOS 인라인 슬롯을 원본 값으로 치환한다
- [x] PEEK 모드가 지원된다 (스냅샷 + `heap_scan_cache_allocate_recdes_data` + `ispeeking = COPY` 전환)
- [x] 모든 `*_develop_ver` 함수와 `heap_file.h` extern 이 삭제되었다
- [x] `HEAP_GET_CONTEXT::expand_oos` 옵션이 추가되고 기본값 `true`
- [x] `heap_get_visible_version_skip_oos_expand` entry point 가 제공되고 4 개 스캔 site (`scan_manager.c:6310`, `query_executor.c:10543, 11353, 12188`) 가 이를 사용한다
- [x] `heap_scan_get_visible_version` fast-path 단축이 OOS + `expand_oos == true` 조합에서는 우회되어 클라이언트 PEEK 경로가 확장된 레코드를 받는다
- [x] `just build-test` 통과 — 12/12 OOS 테스트 pass, 0 failed

---

## Remarks

- Parent: CBRD-26583 [OOS] [EPIC] [M2] 마일스톤 2
- Base branch: `feat/oos`
- HOTFIX 해제 효과: `unloaddb` / `compactdb` / replication 등 OOS 미인식 클라이언트 경로가 처음으로 정상 동작한다.
- 성능 관점:
  - Scan hot path: `expand_oos = false` 로 record 단위 + attribute 단위 `oos_read` 중복 제거.
  - 클라이언트 경로: class repr 조회/캐시 경합이 사라져 HOTFIX 이전 구현 대비 크게 단순/고속화.
- **Dead-on-arrival 1 건**: `heap_scan_get_visible_version_skip_oos_expand` 는 선언/정의되어 있지만 caller 가 없다. (a) `heap_file.c:8521, 8768` 내부 스캔 helper 가 곧장 attrinfo 로 들어가므로 자연스러운 caller 후보다. (b) 그 전환을 별도 티켓으로 미루겠다면 본 PR 에서는 선언을 빼는 것도 고려.
- Follow-up 후보 (현 PR 범위 밖이지만 동일한 redundancy):
  - `src/transaction/locator_sr.c:13759` (`mvcc_cond_reeval` rest-attrs) — 직후 `heap_attrinfo_read_dbvalues`.
  - `src/loaddb/load_server_loader.cpp:244` — 직후 `heap_attrinfo_read_dbvalues`.
  - `src/storage/heap_file.c:8521, 8768` — 내부 scan helper.
- 엣지 케이스 후보:
  - 확장된 레코드가 `area_size` 를 넘는 경우 (`S_DOESNT_FIT`) 의 통합 테스트.
  - `scan_cache == NULL` 인 PEEK caller 가 등장할 경우의 처리.
