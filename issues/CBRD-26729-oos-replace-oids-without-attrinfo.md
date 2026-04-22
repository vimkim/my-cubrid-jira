# [OOS] get_visible_version에서 OOS OID 치환 시 attr_info 경로 제거

## Description

### 배경
`heap_record_replace_oos_oids` 는 OOS가 포함된 heap recdes를 조회할 때, recdes 내부의 16바이트 OOS 인라인 슬롯 (`OID + BIGINT`) 을 OOS에 저장된 실제 가변 속성 바이트로 치환하여 "OOS를 모르는 클라이언트" 에게 정상 레코드로 반환하기 위한 함수이다.

기존 구현은 다음과 같은 흐름으로 동작했다:

1. `heap_attrinfo_start` → 클래스 표현(class repr) 로드
2. `heap_attrinfo_read_dbvalues` → recdes를 DB_VALUE 배열로 디코드 (이 단계에서 각 OOS OID마다 `oos_read` 호출)
3. `heap_attrinfo_transform_to_disk_develop_ver` → DB_VALUE 배열을 다시 on-disk 포맷으로 직렬화

이 경로는 느리고, 무엇보다 **class repr 락/캐시 경합** 을 유발하여 실사용이 불가했다. 그 결과 현재 코드에는 `return S_SUCCESS;` HOTFIX 가 들어가 있어 OOS recdes가 **확장되지 않은 상태** 로 반환되고 있었다. 이 때문에 unloaddb / compactdb / replication 등 OOS를 모르는 클라이언트 경로가 OOS 레코드를 올바르게 처리하지 못한다.

최근 패치에서 `heap_recdes_get_oos_oids` 가 도입되어, recdes의 **VOT(variable offset table)만** 으로 OOS OID 목록을 추출할 수 있게 되었다. 즉, class repr 없이도 OOS OID들을 안전하게 복원할 수 있는 토대가 마련되었다.

### 목적

- class repr / attr_info 경유 없이, **`oos_read()` + VOT 워킹만으로** OOS 인라인 슬롯을 실제 데이터 바이트로 치환하여 원본 recdes를 재구성한다.
- 불필요한 `_develop_ver` 보조 함수들을 모두 제거한다.
- OOS 확장 여부를 caller가 선택할 수 있도록 `HEAP_GET_CONTEXT::expand_oos` 옵션을 추가한다.
  - 기본값은 `true` (안전한 기본값, 기존 계약 유지).
  - `heap_attrinfo_read_dbvalues` 로 디코드하는 내부 hot path는 `false` 로 opt-out 하여 중복 `oos_read` 를 피한다.

---

## Implementation

### 신규 함수: `heap_record_replace_oos_oids`

`src/storage/heap_file.c` 에 기존 HOTFIX 스텁을 교체하여 신규 구현:

1. **VOT 워킹**: `OR_GET_OFFSET_SIZE`, `OR_IS_OOS`, `OR_IS_LAST_ELEMENT` 매크로로 sentinel 까지 각 entry의 `(raw offset, OOS flag)` 를 수집. class repr 불필요.
2. **OOS blob 읽기**: OOS 플래그가 있는 index에 대해 16바이트 인라인 슬롯에서 OID 파싱 → `oos_read(thread_p, oid, rec_out)` 호출. 수집된 RECDES는 scope_exit 가드로 자동 해제.
3. **출력 레이아웃 계산**:
   - 출력 VOT는 항상 `BIG_VAR_OFFSET_SIZE (4 byte)` 로 작성하여 확장된 레코드가 원본 offset_size 범위를 넘더라도 문제없이 표현.
   - 새 레코드 크기 = `header + dst_vot + (fixed attr + bound bitmap) + Σ(new value lengths)`
4. **재구성**:
   - 헤더를 그대로 복사한 뒤 `repid_bits` 에서 `OR_MVCC_FLAG_HAS_OOS` 를 클리어하고 offset-size 비트를 재설정.
   - VOT를 새 offset들로 재작성 (sentinel에는 `OR_SET_VAR_LAST_ELEMENT`).
   - fixed + bound-bit bitmap 영역은 그대로 복사.
   - 가변 값 영역은 OOS 인덱스에 대해 `oos_read` 결과 blob을, 그 외에는 원본 바이트를 splicing.
5. **PEEK 지원**: 소스가 페이지 버퍼에 PEEK 되어 있으면 상단에서 `std::vector<char>` 로 스냅샷한 뒤 `heap_scan_cache_allocate_recdes_data` 로 scan_cache에 쓰기 가능한 버퍼를 할당하고 `ispeeking = COPY` 로 전환.

### 삭제된 `_develop_ver` 함수들 (약 390 line)

- `heap_attrinfo_transform_variable_to_disk_develop_ver`
- `heap_attrinfo_transform_columns_to_disk_develop_ver`
- `heap_attrinfo_get_record_payload_size_develop_ver`
- `heap_attrinfo_determine_disksize_develop_ver`
- `heap_attrinfo_transform_header_to_disk_develop_ver`
- `heap_attrinfo_transform_to_disk_internal_develop_ver`
- `heap_attrinfo_transform_to_disk_develop_ver` (+ `heap_file.h` extern 선언)

외부 참조는 모두 신규 `heap_record_replace_oos_oids` 로 대체되었다.

### `HEAP_GET_CONTEXT::expand_oos` 옵션

```c
struct heap_get_context
{
  ...
  bool expand_oos;   /* default: true, set in heap_init_get_context */
};
```

| API | expand_oos | 용도 |
|-----|-----------|------|
| `heap_get_visible_version` | `true` | 클라이언트 전송/외부 툴 경로 (안전 기본값) |
| `heap_get_visible_version_raw_oos` | `false` | `heap_attrinfo_read_dbvalues` 로 디코드하는 내부 경로 |
| `heap_scan_get_visible_version` | `true` | 동일 |
| `heap_scan_get_visible_version_raw_oos` | `false` | 동일 |

`heap_scan_get_visible_version` 의 fast-path 단축 (REC_HOME + PEEK + snapshot hit 이면 `peeked_recdes` 를 그대로 반환) 도 **`expand_oos == true` 이고 해당 레코드가 OOS를 포함하면 단축 경로를 우회** 하도록 수정했다. 그렇지 않으면 클라이언트 경로에서 OOS가 여전히 확장되지 않은 상태로 흘러갈 수 있다.

### Raw-OOS로 전환된 caller 위치

| 파일 | 라인 | 경로 설명 |
|------|------|-----------|
| `src/query/scan_manager.c` | 6309 | index scan `heap_get_visible_version` (eval_data_filter → attrinfo 경유) |
| `src/query/query_executor.c` | 10426, 11236 | delete-LOB attr 읽기 |
| `src/query/query_executor.c` | 12071 | unique lookup 후 attribute fetch |

이 경로들은 모두 뒤이어 `heap_attrinfo_read_dbvalues` → `heap_attrvalue_read` 를 호출하며, 그 안에서 이미 per-attribute `oos_read` 처리가 되므로 recdes 전체 확장은 **중복 작업** 이었다.

### Caller 분류 (survey 결과)

| 카테고리 | 대표 caller | 확장 필요 |
|----------|-------------|---------|
| Query scan hot path | `scan_manager.c`, `query_executor.c` (위 4곳) | 불필요 (opt-out 완료) |
| 클라이언트/외부 바이트 경로 | `locator_sr.c` fetch 경로 다수, `loaddb`, `compactdb`, `unloaddb`, replication | **필요** (default `true`) |
| Small-record / catalog | `catalog_class.c`, `serial.c`, `sp_code.cpp`, `lock_manager.c` | 실제로는 OOS 미발생. default `true` 유지 |

---

## Spec Change

### 함수 시그니처

| Before | After |
|--------|-------|
| `static SCAN_CODE heap_record_replace_oos_oids_with_values_if_exists (thread_p, context)` (HOTFIX `return S_SUCCESS;`) | `static SCAN_CODE heap_record_replace_oos_oids (thread_p, context)` (실제 동작) |
| — | `extern SCAN_CODE heap_get_visible_version_raw_oos (...)` |
| — | `extern SCAN_CODE heap_scan_get_visible_version_raw_oos (...)` |
| `extern SCAN_CODE heap_attrinfo_transform_to_disk_develop_ver (...)` | **삭제** |

### `HEAP_GET_CONTEXT`

| 필드 | Before | After |
|------|--------|-------|
| `expand_oos` | 없음 | `bool`, `heap_init_get_context` 에서 `true` 로 초기화 |

---

## Acceptance Criteria

- [x] `heap_record_replace_oos_oids` 가 class repr 없이 `oos_read()` 만으로 OOS 인라인 슬롯을 원본 값으로 치환한다
- [x] PEEK 모드가 지원된다 (scan_cache 기반 버퍼 재할당 + COPY로 자동 전환)
- [x] 모든 `*_develop_ver` 함수와 헤더 선언이 삭제되었다
- [x] `HEAP_GET_CONTEXT::expand_oos` 옵션이 추가되고 기본값 `true`
- [x] `heap_get_visible_version_raw_oos` / `heap_scan_get_visible_version_raw_oos` entry point 제공
- [x] Scan manager / query executor 의 attrinfo 경유 경로가 raw-OOS 변형을 사용하도록 스위치 (4곳)
- [x] `heap_scan_get_visible_version` fast-path 단축이 OOS + expand_oos 조합에서는 우회되어, 클라이언트 PEEK 경로가 여전히 확장된 레코드를 받는다
- [x] `just build-test` 통과 — 12/12 OOS 테스트 pass, 0 failed

---

## Remarks

- Parent: CBRD-26583 [OOS] [EPIC] [M2] 마일스톤 2
- Base branch: `feat/oos`
- 이 변경으로 HOTFIX 경로가 해제되어 **unloaddb / compactdb / replication 등 OOS-미인식 클라이언트 경로가 처음으로 올바르게 동작** 한다
- 성능 관점:
  - Scan hot path: `expand_oos=false` 로 중복 `oos_read` 제거
  - 클라이언트 경로: class repr 조회가 없어져 기존 HOTFIX 이전 대비 크게 단순/고속화
- Follow-up 후보:
  - 확장된 레코드 바이트가 `area_size` 를 넘는 엣지 케이스에 대한 통합 테스트 추가 (`S_DOESNT_FIT` 반환 경로)
  - `scan_cache == NULL` 경로를 호출하는 PEEK caller가 등장할 경우 처리 방식 재검토
