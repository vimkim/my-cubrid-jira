# [OOS] [M2] heap recdes가 임계값 아래로 떨어질 때까지 큰 컬럼부터 점진 OOS 전송

## Issue Triage

> **이슈 수행 목적** (필수): heap recdes 가 `DB_PAGESIZE / 4` 임계값을 넘었을 때, 512 B 초과 가변 컬럼을 무차별로 모두 OOS 로 보내지 않고, 큰 컬럼부터 한 개씩 보내 record 가 임계값 아래로 떨어지면 즉시 멈추도록 한다. PG TOAST 의 demotion 정책과 동일한 동작이다.
>
> **이슈 수행 이유** (필수): 현재 정책은 record 가 임계값을 단 1 B 만 넘어도 512 B 초과 가변 컬럼을 전부 외부화하므로, wide-record 워크로드의 OOS 파일 증가율과 SELECT 시 OOS read I/O 가 측정 가능 수준으로 누적된다.
>
> **이슈 수행 방안**: M2 점진 demotion 정책으로 OOS 후보 선정 알고리즘 교체 (`heap_attrinfo_determine_disk_layout()` 한 함수 변경).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하고, 구현/리뷰 단계에서 본문 참고.

### Summary

- **문제**: record 가 4 KB 임계값을 넘으면 512 B 초과 가변 컬럼이 일괄 외부화된다. 큰 컬럼 1 개만 외부화해도 fit 가능한 상황에서 작은 가변 컬럼까지 함께 OOS 로 빠진다.
- **배경**: M1 의 단순 정책. 외부화 대상 cardinality 가 워크로드 특성에 무관하게 부풀려진다.
- **변경**: `heap_attrinfo_determine_disk_layout()` (line 12167-12227) 의 demotion 블록 한 곳만 패치. 가변 컬럼을 size 내림차순으로 정렬하고, 임계값 이하로 떨어질 때까지 한 개씩 demote 한 뒤 break 한다.
- **영향 범위**: INSERT 시점 OOS 후보 선정만. recdes 포맷, MVCC 헤더, OOS 파일 구조, WAL/recovery/replication 모두 변경 없음.

---

## Description

### 배경

OOS 트리거는 두 단계로 평가된다 (`heap_file.c:12189`, 함수 본문 `heap_file.c:12167-12227`):

1. **Record 임계값**: `header_size + payload_size + mvcc_extra > DB_PAGESIZE / 4` (16 KB 페이지 기준 4 KB)
2. **컬럼 조건**: 가변 컬럼이고 `column_size > 512`

기존 코드는 1 번이 참이면 2 번을 만족하는 컬럼을 모두 일괄 외부화하므로, record 가 임계값을 살짝 넘는 경우에도 작은 가변 컬럼까지 함께 OOS 로 빠진다.

### 문제

- record 가 4 KB 를 살짝 넘는 경우에도 가장 큰 컬럼 1 개만 빼면 임계값 아래로 떨어지는 상황이 흔하다. 기존 정책은 512 B 초과 컬럼을 전부 외부화하므로 외부화가 불필요한 작은 가변 컬럼까지 OOS 로 함께 빠진다.
- CBRD-26516 가 fix 되어 redundant `oos_read` 가 제거되어도 외부화된 컬럼이 많으면 read 비용은 남는다. 본 이슈는 외부화 대상 자체를 줄여 26516 수정과 직교하게 효과를 더한다.
- UPDATE 시 새 OOS OID 발급 (M1: 항상 새 OID) 비용도 누적된다.
- OOS 파일 자체도 빨리 자라 bestspace/compaction/vacuum 부담이 커진다.

### PG TOAST 와의 비교

PostgreSQL 16 의 tuple-toaster main loop (`src/backend/access/heap/heaptoast.c`) 는 동일 시나리오를 점진 demotion 으로 처리한다. 가장 큰 가변 컬럼을 찾아 한 개씩 외부화하거나 압축하고, 매 라운드마다 record 길이를 재계산해 임계값 이하면 종료하는 구조다. CUBRID OOS 는 M1 시점에 압축이 없으므로 외부화 단계만 차용하면 되고, 압축 도입 (CBRD-26536 서베이) 이후에는 본 정책 위에 압축 라운드를 얹는 식으로 자연 확장된다.

---

## Specification Changes

### Trigger Policy

| 항목 | 기존 (M1) | 변경 후 |
|---|---|---|
| 후보 정렬 | 정렬 없음 | 가변 컬럼 size 내림차순 정렬 |
| 외부화 순서 | 512 B 초과 가변 컬럼 전부 일괄 | 큰 컬럼부터 한 개씩 순차 demotion |
| 종료 조건 | 모든 후보 처리 후 종료 | record 가 임계값 이하로 떨어지면 break. 모두 외부화해도 미달이면 후보 전부 소진 후 종료 |
| 컬럼 임계값 | 가변 + `> 512 B` | 가변 + `> 512 B` (변경 없음) |
| record 임계값 | `> DB_PAGESIZE / 4` | `> DB_PAGESIZE / 4` (변경 없음) |

### 외부 인터페이스

- 변경 없음. `oos_columns[i]` per-column 플래그 시그니처 유지.
- recdes 포맷 변경 없음. MVCC 헤더 `OR_MVCC_FLAG_HAS_OOS` 비트 의미 변경 없음.
- WAL 레코드 포맷 변경 없음.

### 복잡도

복잡도 영향 무시 가능 (가변 컬럼 N <= 수십). INSERT path 마다 `std::vector` heap alloc 1 회 추가되나, 임계값 초과 record 한정이라 hot-path 영향 미미.

---

## Implementation

### 변경 파일

| 파일 | 변경 내용 |
|---|---|
| `src/storage/heap_file.c` | STL 헤더 (`<algorithm>`, `<utility>`) 추가, `heap_attrinfo_determine_disk_layout()` 의 OOS 후보 선정 블록 교체 |

### 변경 함수

| 함수 | 위치 | 변경 내용 |
|---|---|---|
| `heap_attrinfo_determine_disk_layout()` | `heap_file.c:12167-12227` | 가변 컬럼 후보를 `std::vector<std::pair<int, int>>` 에 수집, `std::sort(.., std::greater<>())` 로 size 내림차순 정렬, 임계값 도달 시까지 큰 컬럼부터 demote |

새 블록은 함수 전체를 감싸는 `// *INDENT-OFF*` / `// *INDENT-ON*` 마커 사이에 위치한다 (CUBRID 의 `indent` 포매터가 STL 템플릿 문법을 깨지 않도록 막는 관례).

### 핵심 로직

`oos_columns` 는 호출자 (`heap_attrinfo_transform_to_disk_internal()`) 에서 `attr_info->num_values` 크기로 사전 할당되므로, 본 함수는 그중 일부 인덱스를 `true` 로 설정만 한다. 의사 코드는 다음과 같다.

```cpp
if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 4)
  {
    std::vector<std::pair<int, int>> oos_candidates;   /* {column_size, attr index} */

    for (i = 0; i < attr_info->num_values; i++)
      {
        if (!attr_info->values[i].last_attrepr->is_fixed && column_size[i] > 512)
          {
            oos_candidates.emplace_back (column_size[i], i);
          }
      }

    std::sort (oos_candidates.begin (), oos_candidates.end (),
               std::greater<std::pair<int, int>> ());

    for (auto & cand : oos_candidates)
      {
        if (header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 4)
          {
            break;
          }
        (*oos_columns)[cand.second] = true;
        payload_size -= cand.first;
        payload_size += OR_OOS_INLINE_SIZE;
        *has_oos = true;
      }

    header_size = heap_attrinfo_get_record_header_size (attr_info, payload_size,
                                                        is_mvcc_class, offset_size_ptr);
  }
```

### 다운스트림 영향 분석

- `heap_attrinfo_insert_to_oos()`, `heap_attrinfo_transform_variable_to_disk()` 등 다운스트림은 per-column `oos_columns[i]` 만 보므로 시그니처 호환.
- `heap_record_replace_oos_oids_with_values_if_exists()` 등 read 경로는 VOT `IS_OOS` 비트 기반이라 영향 없음.
- WAL 정확성: heap recdes 와 OOS 파일 모두 포맷이 동일하므로 WAL 레코드 포맷 불변, recovery 정확성 영향 없음.
- WAL 트래픽 분포: 작은 가변 컬럼이 heap 에 남는 빈도가 늘어 heap WAL 페이로드는 다소 증가하고 OOS WAL 은 감소한다. 정확성과 무관한 분포 변동이라 별도 검증 항목.

### 보수적 판정 근거

- `mvcc_extra` 정의 (`heap_file.c:12184`): `mvcc_extra = is_mvcc_class ? OR_MVCC_MAX_HEADER_SIZE - OR_MVCC_INSERT_HEADER_SIZE : 0`. 즉 INSERT 직후가 아니라 향후 UPDATE/DELETE 로 MVCC 헤더가 늘어날 worst-case 폭을 예약해 두는 값이라, 초기 demotion 도 post-update record 까지 fit 하도록 사이즈를 잡는다.
- 루프 내부 비교 `header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 4` 의 `header_size` 는 트리거 직전에 계산된 값으로, payload 가 줄어들어도 즉시 갱신되지 않는다. 그러나 다음 두 단조성으로 정확성은 유지된다.
  - (a) `column_size > 512` 이고 `OR_OOS_INLINE_SIZE = 16` 이므로 demote 1 회마다 `payload_size` 가 strict 하게 감소한다 (`-column_size + 16 < 0`).
  - (b) `heap_attrinfo_get_record_header_size()` 는 `payload_size` 의 비감소 함수라, payload 가 줄어들 때 header 의 `offset_size` 는 그대로이거나 (`OR_MAX_BYTE`/`OR_MAX_SHORT` 경계 통과 시) 더 작아진다.
  - 따라서 루프 안에서 사용한 `header_size` 는 실제 actual_header 의 over-estimate 이고, "실제 size 가 임계값 초과인데 break" 하는 경우는 발생하지 않는다.
- 후보 전부 외부화해도 임계값 미달이면 후보 모두 demote 한 뒤 종료. 후보가 0 개면 demotion 없이 종료.
- 보수적 판정으로 인해 경계 케이스 (`payload_size` 가 `OR_MAX_BYTE` 또는 `OR_MAX_SHORT` 인근) 에서 본 정책이 실제 필요량보다 1 컬럼 더 외부화할 수 있다. 정확성 영향 없고, fit 미달성 영향 없으며, I/O 측면 미세 비효율 가능.

---

## Acceptance Criteria

- [ ] (i) record `<= 4 KB`: OOS 외부화 발생하지 않음. `*has_oos = false`, `oos_columns[i] = false ∀ i`.
- [ ] (ii) record `> 4 KB`, 큰 컬럼 1 개로 fit 가능: 가장 큰 후보 1 개만 `oos_columns[i] = true`, 나머지는 heap 잔존.
- [ ] (iii) record `> 4 KB`, 큰 컬럼 1 개로 부족: 큰 컬럼부터 순서대로 추가 외부화하다 fit 시 break.
- [ ] (iv) record `> 4 KB`, 모든 후보 외부화해도 fit 실패: 모든 후보를 외부화한 결과 후보 전부 demotion 상태로 종료. 기존 무차별 정책과 결과는 같으나 도달 경로가 다름. `*has_oos = true`, 모든 후보 인덱스 `oos_columns[i] = true`.
- [ ] (v) record `> 4 KB`, 가변 컬럼이 모두 `<= 512 B` 라 후보가 0 개: demotion 미발생. `*has_oos = false`, `oos_columns[i] = false ∀ i`.
- [ ] OOS insert/read/update/delete regression 없음 (`cubrid-isolation-test` OOS suite 통과).
- [ ] CDC/replication regression 없음.
- [ ] 주요 crash recovery 시나리오 (M1 5.1-5.5 시리즈) 통과.
- [ ] wide-record 벤치 (예: 가변 8 컬럼, 그중 1 개 1.7 KB) INSERT N 회 후 SELECT pgbuf I/O count 측정. 변경 전후 OOS 측 read I/O 가 감소하는 방향임을 확인 (수치는 측정 후 채움).

## Definition of Done

- [ ] 위 Acceptance Criteria 충족
- [ ] CircleCI `test_sql`, `test_medium` 그린
- [ ] PR 리뷰 승인
- [ ] OOS 관련 내부 문서 (있는 경우) 업데이트

---

## Remarks

- M2 의 bestspace (CBRD-26658), compaction, vacuum 작업과는 독립이다.
- M3 의 OOS OID 재사용 (deduplication) 단계에서 입력 cardinality 가 줄어들기에, dedup 효과 측정 시 노이즈가 줄어든다.
- 부모 epic: CBRD-26583 (M2).
- 관련: CBRD-26536 (PG TOAST 압축 시점 서베이), CBRD-26516 (redundant `oos_read`).
