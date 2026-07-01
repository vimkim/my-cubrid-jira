# [OOS] [Refactoring] OOS record flag naming 을 MVCC 용어에서 분리

## Issue Triage

**이슈 수행 목적**: OOS 플래그를 MVCC 생명주기 플래그처럼 보이게 하는 이름과 접근 API 를 정리한다. develop 머지 전에는 디스크 포맷을 바꾸지 않고, 레코드 헤더 안의 공용 flag 영역과 MVCC 전용 low 3bit 영역을 코드 이름으로 분리한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `OOS` (Out-of-row Storage - heap 의 큰 가변 컬럼을 외부 OOS 파일로 분리해 저장하는 방식) 구현 과정에서 `HAS_OOS` 가 `OR_MVCC_FLAG_HAS_OOS=0x08` 로 정의되어 있다. 그러나 이 bit 는 `MVCC` (Multi-Version Concurrency Control - 레코드 버전 가시성을 관리하는 방식) insert/delete/prev-version 상태가 아니라 레코드 저장 포맷 메타데이터다.
- **영향**: 기술 부채 - 새 코드를 작성하는 사람이 `HAS_OOS` 를 MVCC lifecycle flag 로 오해하면 header size 계산, vacuum OOS 정리, SA mode flag 보존 경로에서 잘못된 mask 또는 clear 로 이어질 수 있다.

**이슈 수행 방안**: 사용자 인용: "develop 에 머지할 때 naming 이랑 이런 걸 잘 분리". `HAS_OOS` 의 물리 bit 위치(`0x08`)는 유지하되, 이름과 helper 를 `record header flag` 계층으로 옮긴다. MVCC 전용 API 는 low 3bit 만 다루도록 명시하고, OOS call site 는 `heap_recdes_contains_oos()` 또는 record-flag helper 를 통해 접근한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/base/object_representation_constants.h`, `src/base/object_representation.h`, `src/base/object_representation_sr.c`, `src/transaction/mvcc.h`, `src/storage/heap_file.c`, `src/storage/heap_oos.cpp`, `src/storage/oos_util.cpp`, `src/query/vacuum.c`, `src/query/vacuum_oos.cpp`, `src/transaction/log_applier.c` 의 naming/API 정리. SQL 시맨틱, wire protocol, OOS inline format, heap record binary layout 은 변경하지 않는다.

---

## Description

`recdes` (record descriptor - heap/page 위의 레코드 바이트와 길이를 담는 구조) 의 첫 representation word 에는 representation id, bound bit, variable offset size bit, 그리고 bits 24-28 의 record flag 영역이 함께 들어 있다. 기존 CUBRID 코드는 이 5bit 영역을 주로 MVCC header 구성에 사용했기 때문에 매크로 이름도 `OR_MVCC_FLAG_*`, `OR_GET_MVCC_FLAG`, `OR_MVCC_FLAG_SHIFT_BITS` 로 잡혀 있다.

OOS 는 이 남는 flag 공간에 `HAS_OOS` 를 추가했다. 이 bit 는 "이 레코드의 variable offset table 에 OOS OID 가 들어 있다" 는 저장 포맷 메타데이터다. insert MVCCID 존재 여부, delete MVCCID 존재 여부, 이전 버전 LSA 존재 여부처럼 MVCC header 크기를 결정하는 정보가 아니다.

현재 코드도 이 차이를 이미 일부 알고 있다. `OR_MVCC_HEADER_SIZE_LOOKUP_MASK` 는 `0x7` 이며, `mvcc_header_size_lookup` 접근은 low 3bit 만 사용한다. 반면 전체 flag mask 인 `OR_MVCC_FLAG_MASK` 는 `0x1f` 라서 `HAS_OOS` 의 `0x08` 까지 포함한다. 즉 물리 저장 위치는 공용 record flag 영역이고, MVCC header size 계산 영역은 그 안의 low 3bit 뿐이다.

문제는 이름이 이 경계를 흐린다는 점이다. 예를 들어 `heap_update_adjust_recdes_header` 는 VOT 를 다시 걷지 않고 이미 찍힌 `HAS_OOS` bit 를 신뢰한다. 이 판단 자체는 맞지만, 코드상으로는 `mvcc_flags & OR_MVCC_FLAG_HAS_OOS` 로 표현되어 있어 OOS 가 MVCC flag 인 것처럼 읽힌다. vacuum 도 `MVCC_GET_FLAG(&helper->mvcc_header) & OR_MVCC_FLAG_HAS_OOS` 형태로 같은 혼동을 반복한다.

develop 머지 전 정리는 포맷 변경이 아니라 소유권 정리여야 한다. bit 위치를 옮기면 기존 feat/oos 개발 DB 재초기화, recovery/log applier 경로 재검증, 여러 call site 의 binary parsing 재확인이 필요하다. 반면 이름과 helper 를 분리하면 현재 동작은 유지하면서 코드 독자가 "전체 record flag" 와 "MVCC header-size flag" 를 구분할 수 있다.

## Specification Changes

사용자 SQL 시맨틱: N/A.

디스크 포맷: 변경 없음. `HAS_OOS` 는 기존과 동일하게 representation word 의 `0x08` bit 를 사용한다.

내부 naming/API 변경:

| 구분 | 현재 | 변경 방향 |
|------|------|-----------|
| 전체 flag 영역 | `OR_MVCC_FLAG_MASK` (`0x1f`) | `OR_RECORD_FLAG_MASK` (`0x1f`) |
| flag shift | `OR_MVCC_FLAG_SHIFT_BITS` | `OR_RECORD_FLAG_SHIFT_BITS` |
| MVCC lifecycle 영역 | `OR_MVCC_HEADER_SIZE_LOOKUP_MASK` (`0x7`) | `OR_RECORD_MVCC_FLAG_MASK` 또는 `OR_MVCC_LIFECYCLE_FLAG_MASK` |
| OOS record flag | `OR_MVCC_FLAG_HAS_OOS` (`0x08`) | `OR_RECORD_FLAG_HAS_OOS` (`0x08`) |
| representation word getter | `OR_GET_MVCC_REPID_AND_FLAG(ptr)` | `OR_GET_RECORD_REPID_AND_FLAGS(ptr)` |
| record flag getter | `OR_GET_MVCC_FLAG(ptr)` | `OR_GET_RECORD_FLAGS(ptr)` |
| MVCC-only getter | 혼재 | `OR_GET_MVCC_FLAGS(ptr)` 는 low 3bit 만 반환 |
| OOS 판정 | `flag & OR_MVCC_FLAG_HAS_OOS` | `heap_recdes_contains_oos()` 또는 `OR_RECORD_HAS_OOS(ptr)` |

`OR_VAR_BIT_OOS` 는 variable offset table 의 per-column flag 다. record-level `HAS_OOS` 와 계층이 다르므로 본 이슈에서는 필수 변경 대상이 아니다. 다만 이름을 더 명확히 하려면 `OR_VOT_FLAG_OOS` 또는 `OR_VAR_OFFSET_FLAG_OOS` 로 별도 정리할 수 있다. 이 rename 은 `TBD - 합의 미확인`.

## Implementation

### 1. record flag 계층 이름 추가

`object_representation_constants.h` 에 record header flag 계층을 먼저 추가한다. 초기 PR 에서는 compatibility alias 를 둘 수 있지만, develop 머지 전에는 OOS 경로가 새 이름을 쓰도록 정리한다.

```c
#define OR_RECORD_FLAG_MASK              0x1f
#define OR_RECORD_MVCC_FLAG_MASK         0x07
#define OR_RECORD_FLAG_SHIFT_BITS        24
#define OR_RECORD_FLAG_MASK_IN_WORD      (OR_RECORD_FLAG_MASK << OR_RECORD_FLAG_SHIFT_BITS)

#define OR_RECORD_FLAG_HAS_OOS           0x08
```

`OR_MVCC_FLAG_VALID_INSID`, `OR_MVCC_FLAG_VALID_DELID`, `OR_MVCC_FLAG_VALID_PREV_VERSION` 는 실제 MVCC lifecycle bit 이므로 MVCC 이름을 유지한다. 다만 이 세 bit 만 `OR_RECORD_MVCC_FLAG_MASK` 안에 들어간다는 점을 코드 이름이나 주석으로 드러낸다.

기존 MVCC 이름은 두 단계로 정리한다.

| 단계 | 처리 |
|------|------|
| 1차 | 기존 이름을 새 이름의 alias 로 두고 call site 를 이동한다. |
| 2차 | `OR_MVCC_FLAG_HAS_OOS` 와 OOS 관련 MVCC-named helper 사용을 제거한다. |
| 3차 | MVCC lifecycle flag 이름은 남기되, "전체 5bit record flag mask" 와 "MVCC low 3bit mask" 가 다른 이름을 쓰도록 정리한다. |

### 2. getter/setter 의미 분리

현재 `OR_GET_MVCC_FLAG(ptr)` 는 전체 5bit 를 반환한다. 새 API 에서는 아래처럼 의미를 분리한다.

```c
#define OR_GET_RECORD_FLAGS(ptr) \
  (((OR_GET_INT (((char *) (ptr)) + OR_REP_OFFSET)) >> OR_RECORD_FLAG_SHIFT_BITS) & OR_RECORD_FLAG_MASK)

#define OR_GET_MVCC_FLAGS(ptr) \
  (OR_GET_RECORD_FLAGS (ptr) & OR_RECORD_MVCC_FLAG_MASK)

#define OR_RECORD_HAS_OOS(ptr) \
  ((OR_GET_RECORD_FLAGS (ptr) & OR_RECORD_FLAG_HAS_OOS) != 0)
```

`or_mvcc_get_header`, `or_mvcc_set_header`, `MVCC_REC_HEADER` 경로는 기존 동작을 유지하되, header size 계산에는 `OR_RECORD_MVCC_FLAG_MASK` 만 들어가게 한다. `HAS_OOS` 는 record flag 로 보존하거나 제거해야 하며, `mvcc_header_size_lookup` 의 index 가 되어서는 안 된다.

### 3. OOS call site 이동

OOS 여부를 직접 보는 코드는 record-level helper 로 옮긴다.

```
heap_attrinfo_transform_header_to_disk()
  -> OR_RECORD_FLAG_HAS_OOS 를 representation word 에 set

heap_recdes_contains_oos()
  -> OR_RECORD_HAS_OOS(record->data)

heap_insert_adjust_recdes_header()
heap_update_adjust_recdes_header()
  -> MVCC lifecycle bit 조작 전후로 OR_RECORD_FLAG_HAS_OOS 보존

vacuum / vacuum_oos
  -> MVCC_GET_FLAG(... ) & OR_MVCC_FLAG_HAS_OOS 제거
  -> recdes 가 있는 경로는 heap_recdes_contains_oos()
  -> REC_BIGONE 처럼 header 만 있는 경로는 OR_RECORD_FLAG_HAS_OOS 를 읽는 별도 helper 사용
```

### 4. VOT per-column OOS flag 는 별도 계층으로 유지

`OR_VAR_BIT_OOS` 는 variable offset table entry 의 low bit 이다. record header 의 `HAS_OOS` 는 "이 레코드에 OOS 컬럼이 하나라도 있음" 을 빠르게 알리는 summary bit 이고, VOT flag 는 "이 variable column 하나가 OOS OID 를 담음" 을 나타낸다.

```
record header flag
  OR_RECORD_FLAG_HAS_OOS       // record-level summary

variable offset table flag
  OR_VAR_BIT_OOS               // per-variable-column marker
```

이 구분을 주석과 helper 이름에 반영한다. `heap_recdes_compute_oos_flag_debug` 의 주석도 `OR_MVCC_FLAG_HAS_OOS` audit 에서 `OR_RECORD_FLAG_HAS_OOS` audit 으로 바꾼다.

### 5. compatibility alias 제거 기준

개발 중 임시 alias 는 허용하되, 완료 전 검색 결과를 기준으로 정리한다.

| 검색어 | 완료 기준 |
|--------|-----------|
| `OR_MVCC_FLAG_HAS_OOS` | 0건. 필요 시 한 곳의 compatibility block 에만 남기고 OOS 코드는 사용하지 않는다. |
| `OR_GET_MVCC_FLAG` | MVCC lifecycle 처리 경로에서만 사용하거나, `OR_GET_RECORD_FLAGS` / `OR_GET_MVCC_FLAGS` 로 분리한다. |
| `MVCC_GET_FLAG(...) & OR_RECORD_FLAG_HAS_OOS` | 0건. `MVCC_GET_FLAG` 는 MVCC lifecycle flag 판정에만 사용한다. |
| `OR_GET_MVCC_REPID_AND_FLAG` | record-level parsing 경로는 `OR_GET_RECORD_REPID_AND_FLAGS` 로 이동한다. |
| `mvcc_header_size_lookup[` | index 가 `OR_RECORD_MVCC_FLAG_MASK` 또는 동일 의미의 low 3bit mask 를 거치는지 확인한다. |

## Acceptance Criteria

- [ ] `HAS_OOS` 의 public macro 이름이 `OR_RECORD_FLAG_HAS_OOS` 계층으로 이동한다.
- [ ] OOS write/read/vacuum 경로에서 `OR_MVCC_FLAG_HAS_OOS` 직접 사용이 사라진다.
- [ ] `OR_GET_RECORD_FLAGS()` 와 `OR_GET_MVCC_FLAGS()` 의미가 분리되어, OOS 판정은 record flag getter 를 사용한다.
- [ ] `mvcc_header_size_lookup` 접근은 `HAS_OOS` bit 를 제외한 low 3bit mask 를 유지한다.
- [ ] `heap_recdes_contains_oos()` 는 새 record flag helper 를 사용한다.
- [ ] `heap_recdes_compute_oos_flag_debug()` 주석과 assert 메시지가 `OR_RECORD_FLAG_HAS_OOS` 용어로 갱신된다.
- [ ] `OR_VAR_BIT_OOS` 와 record-level `HAS_OOS` 의 차이가 `object_representation.h` 주석에 명시된다.
- [ ] OOS SQL/unit regression 이 기존과 동일하게 통과한다.

## Definition of done

- [ ] 위 Acceptance Criteria 전 항목 충족
- [ ] debug/release 빌드 통과
- [ ] OOS 관련 SQL regression 및 unit_tests/oos 통과
- [ ] `rg -n "OR_MVCC_FLAG_HAS_OOS|HAS_OOS.*MVCC|MVCC.*HAS_OOS" src` 결과 검토 완료
- [ ] develop merge 전 임시 alias 또는 TODO 가 남아 있으면 제거하거나 후속 티켓으로 명시

## References

| 파일 | 참고 지점 |
|------|-----------|
| `src/base/object_representation_constants.h` | `OR_MVCC_FLAG_MASK`, `OR_MVCC_HEADER_SIZE_LOOKUP_MASK`, `OR_MVCC_FLAG_HAS_OOS` 정의 |
| `src/base/object_representation.h` | `OR_GET_MVCC_FLAG`, `OR_VAR_BIT_OOS`, `OR_IS_OOS` |
| `src/storage/heap_file.c` | `heap_attrinfo_transform_header_to_disk`, `heap_insert_adjust_recdes_header`, `heap_update_adjust_recdes_header`, `heap_recdes_contains_oos` |
| `src/storage/heap_oos.cpp` | OOS expand 경로의 record flag clear/preserve |
| `src/storage/oos_util.cpp` | debug-only `HAS_OOS` audit |
| `src/query/vacuum.c` | REC_BIGONE guard 의 OOS flag 판정 |
| `src/query/vacuum_oos.cpp` | vacuum OOS cleanup 의 `heap_recdes_contains_oos` 사용 |
| `src/transaction/log_applier.c` | replication/log applier 경로의 MVCC lifecycle flag assert |

## Remarks

- 부모 이슈: CBRD-26583 (OOS M2).
- 기존 feat/oos 개발 DB 의 compatibility 는 유지한다. 본 이슈는 bit 위치를 바꾸지 않는다.
- `OR_VAR_BIT_OOS` rename 은 선택 사항이다. record header naming 분리와 별도 PR 로 나누는 편이 리뷰 범위를 줄인다.
