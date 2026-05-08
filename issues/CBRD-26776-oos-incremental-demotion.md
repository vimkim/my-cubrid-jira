# [OOS] [M2] heap recdes 임계값을 `DB_PAGESIZE/4` 로 상향 + 큰 컬럼부터 점진 OOS 전송

## Issue Triage

> **이슈 수행 목적** (필수): heap recdes 임계값을 `DB_PAGESIZE/4` 로 상향하고, OOS demotion 을 큰 컬럼부터 점진 적용한다.
>
> **이슈 수행 이유** (필수): 가변 1.6 KB 컬럼 1 개 + 600 B 컬럼 5 개로 구성된 record 에서 demote 대상이 6 개 -> 1 개로 줄어 SELECT 시 OOS read I/O 가 비례 감소한다.
>
> **이슈 수행 방안**: OOS 후보 선정 단계를 점진 demotion 알고리즘으로 교체하고 record 임계값을 `DB_PAGESIZE/4` 로 상향한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하고, 구현/리뷰 단계에서 본문 참고.

이하 본문은 16 KB 페이지 기준 (`DB_PAGESIZE = 16384`) 으로 서술한다.

### Summary

- **문제**: 임계값 초과 시 512 B 초과 가변 컬럼을 일괄 외부화하므로, 큰 컬럼 1 개 demote 만으로 fit 가능한 record 도 작은 가변 컬럼까지 OOS 로 빠진다.
- **배경**: M1 후보 선정이 단순해서 워크로드 특성과 무관하게 외부화 대상 cardinality 가 부풀려진다.
- **변경**: `heap_attrinfo_determine_disk_layout()` (`heap_file.c:12167-12227`) 의 demotion 블록 한 곳을 점진 알고리즘으로 교체 (자세한 정책은 Specification Changes 표 참조).
- **영향 범위**: INSERT 시점 OOS 후보 선정에 한정된다. recdes 포맷, MVCC 헤더, OOS 파일 구조, WAL/recovery/replication 모두 변경 없다.

---

## Description

### 배경

트리거 if 조건은 `heap_file.c:12189` 이고 함수 본문은 `heap_file.c:12167-12227` 이다. 트리거는 두 단계로 평가된다.

1. **Record 임계값**: `header_size + payload_size + mvcc_extra > DB_PAGESIZE / 4`
2. **컬럼 조건**: 가변 컬럼이고 `column_size > 512`

기존 코드는 1 번이 참이면 2 번을 만족하는 컬럼을 모두 일괄 외부화하므로, record 가 임계값을 살짝 넘는 경우에도 작은 가변 컬럼까지 함께 OOS 로 빠진다.

### 문제

구체 시나리오로 가변 6 컬럼 record 를 잡는다. 가변 payload 는 합 4600 B 이고 그중 1.6 KB 컬럼 1 개 + 600 B 컬럼 5 개로 구성된다. 헤더와 고정 컬럼은 약 200 B 라 record 전체는 약 4800 B 이다 (`> DB_PAGESIZE/4 = 4096 B`).

- 변경 후 정책: 1.6 KB 컬럼 1 개만 demote 하면 payload 변화량은 `-1600 + OR_OOS_INLINE_SIZE = -1584` B 이고 새 record 는 약 3216 B (`< 4096 B`) 라 추가 demote 가 불필요하다.
- 기존 정책 (M1): 600 B 컬럼 5 개도 모두 `> 512 B` 이므로 6 컬럼 전부 외부화한다.
- 차이: demote 대상 cardinality 가 6 -> 1 로 줄고, SELECT 시 OOS read I/O 가 대략 6 회 -> 1 회로 감소한다.

추가로 다음 두 부수 영향이 누적된다.

- CBRD-26516 가 fix 되어 redundant `oos_read` 가 제거되어도 외부화된 컬럼이 많으면 read 비용은 남는다. 본 이슈는 외부화 대상 자체를 줄여 26516 수정과 직교하게 효과를 더한다.
- UPDATE 시 새 OOS OID 발급 비용도 누적된다 (M1 의 OOS UPDATE 는 항상 새 OID 를 발급한다 - 컨텍스트 문서 `OOS-CONTEXT.md` 의 update flow 절 참조).
- OOS 파일 자체도 빨리 자라 bestspace/compaction/vacuum 부담이 커진다.

### PG TOAST 와의 비교

PostgreSQL 16 의 tuple-toaster main loop (`src/backend/access/heap/heaptoast.c`) 는 동일 시나리오를 점진 demotion 으로 처리한다. 가장 큰 가변 컬럼을 찾아 한 개씩 외부화하거나 압축하고, 매 라운드마다 record 길이를 재계산해 임계값 이하면 종료하는 구조다. CUBRID OOS 는 M1 시점에 압축이 없으므로 외부화 단계만 차용하면 되고, 압축 도입 (CBRD-26536 서베이) 이후에는 본 정책 위에 압축 라운드를 얹는 식으로 자연 확장된다.

---

## Specification Changes

### Trigger Policy

| 항목 | 기존 (M1) | 변경 후 |
|---|---|---|
| record 임계값 | `DB_PAGESIZE / 8` (16 KB 페이지에서 2 KB) | `DB_PAGESIZE / 4` (16 KB 페이지에서 4 KB) |
| 후보 정렬 | 정렬 없음 | 가변 컬럼 size 내림차순 정렬 |
| 외부화 순서 | 512 B 초과 가변 컬럼 전부 일괄 | 큰 컬럼부터 한 개씩 순차 demotion |
| 종료 조건 | 모든 후보 처리 후 종료 | record 가 임계값 이하로 떨어지면 break. 모두 외부화해도 미달이면 후보 전부 소진 후 종료 |
| 컬럼 임계값 | 가변 + `> 512 B` | 가변 + `> 512 B` (변경 없음) |

### 외부 인터페이스

- 변경 없다. `oos_columns[i]` per-column 플래그 시그니처 유지.
- recdes 포맷 변경 없다. MVCC 헤더 `OR_MVCC_FLAG_HAS_OOS` 비트 의미 변경 없다.
- WAL 레코드 포맷 변경 없다.

### 복잡도

복잡도 영향 무시 가능하다 (가변 컬럼 N <= 수십). demotion 진입 시에만 `oos_candidates` 1 회 추가 alloc 이 발생하고, 임계값 미만 record 는 영향 없다 (`column_size` 벡터는 본 패치 이전부터 매 호출 alloc 되므로 신규 비용 아니다). 측정 데이터는 PR 단계 micro-bench 로 보강 예정이며, 정성적으로는 임계값 초과 record 한정이라 평균 INSERT 경로에는 영향 미미할 것으로 예상한다.

---

## Implementation

### 변경 파일

| 파일 | 변경 내용 |
|---|---|
| `src/storage/heap_file.c` | STL 헤더 (`<algorithm>`, `<utility>`) 추가, `heap_attrinfo_determine_disk_layout()` 의 OOS 후보 선정 블록 교체 |

### 변경 함수

| 함수 | 위치 | 변경 내용 |
|---|---|---|
| `heap_attrinfo_determine_disk_layout()` | `heap_file.c:12167-12227` | 가변 컬럼 후보를 `std::vector<std::pair<int, int>>` 에 수집, `std::sort(.., std::greater<>())` 로 size 내림차순 정렬, 임계값 도달 시까지 큰 컬럼부터 demote (정책 상세는 Specification Changes 표) |

STL / template 라인 5 군데에 `// *INDENT-OFF*` / `// *INDENT-ON*` 쌍을 두른다 (함수 시그니처, `column_size` 선언, `oos_candidates` 선언, `std::sort`, range-for 헤더).

### 핵심 로직

`oos_columns` 는 호출자 (`heap_attrinfo_transform_to_disk_internal()`) 에서 `attr_info->num_values` 크기로 사전 할당되므로, 본 함수는 그중 일부 인덱스를 `true` 로 설정만 한다. 의사 코드는 다음과 같다.

```cpp
static size_t
heap_attrinfo_determine_disk_layout (HEAP_CACHE_ATTRINFO * attr_info, bool is_mvcc_class,
                                     size_t * offset_size_ptr,
                                     std::vector<bool> * oos_columns, bool * has_oos)
{
  std::vector<int> column_size (attr_info->num_values);
  int payload_size, header_size, mvcc_extra;

  *has_oos = false;
  payload_size = heap_attrinfo_get_record_payload_size (attr_info, &column_size);
  header_size  = heap_attrinfo_get_record_header_size  (attr_info, payload_size,
                                                        is_mvcc_class, offset_size_ptr);
  mvcc_extra   = is_mvcc_class ? OR_MVCC_MAX_HEADER_SIZE - OR_MVCC_INSERT_HEADER_SIZE : 0;

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

  return header_size + payload_size;
}
```

### 다운스트림 영향 분석

- `heap_attrinfo_insert_to_oos()`, `heap_attrinfo_transform_variable_to_disk()` 등 다운스트림은 per-column `oos_columns[i]` 만 보므로 시그니처 호환된다.
- `heap_record_replace_oos_oids_with_values_if_exists()` 등 read 경로는 VOT `IS_OOS` 비트 기반이라 영향 없다.
- WAL 정확성: heap recdes 와 OOS 파일 모두 포맷이 동일하므로 WAL 레코드 포맷 불변하고 recovery 정확성 영향 없다.
- WAL 트래픽 분포: 작은 가변 컬럼이 heap 에 남는 빈도가 늘어 heap WAL 페이로드는 다소 증가하고 OOS WAL 은 감소한다. 정확성과 무관한 분포 변동이라 측정 항목으로 별도 분리한다 (Benchmark Plan 의 WAL volume 측정 참조).
- bestspace (CBRD-26658), compaction, vacuum 영향: OOS 후보 cardinality 가 줄면 OOS 페이지 사용량이 줄어 bestspace hot-spot 도 자연 감소한다. compaction/vacuum 정확성에는 영향 없다.

### 보수적 판정 근거

- `mvcc_extra` 정의 (`heap_file.c:12184`): `mvcc_extra = is_mvcc_class ? OR_MVCC_MAX_HEADER_SIZE - OR_MVCC_INSERT_HEADER_SIZE : 0`. 즉 INSERT 직후가 아니라 향후 UPDATE/DELETE 로 MVCC 헤더가 늘어날 worst-case 폭을 예약해 두는 값이라, 초기 demotion 도 post-update record 까지 fit 하도록 사이즈를 잡는다.
- 루프 내부 비교 `header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 4` 의 `header_size` 는 트리거 직전에 계산된 값으로, payload 가 줄어들어도 즉시 갱신되지 않는다. 그러나 다음 두 단조성으로 정확성은 유지된다.
  - (a) `column_size > 512` 이고 `OR_OOS_INLINE_SIZE = 16` 이므로 demote 1 회마다 `payload_size` 가 strict 하게 감소한다 (`-column_size + 16 < 0`).
  - (b) `payload_size` 가 감소하면 `header_size` 도 감소하거나 동일하다. `offset_size` 가 BYTE -> SHORT -> INT 경계를 역방향으로 통과할 수 있을 뿐 증가하지는 않기 때문이다.
  - 따라서 루프 안에서 사용한 `header_size` 는 실제 actual_header 의 over-estimate 이고, "실제 size 가 임계값 초과인데 break" 하는 경우는 발생하지 않는다.
- 후보 전부 외부화해도 임계값 미달이면 후보 모두 demote 한 뒤 종료한다. 후보가 0 개면 demotion 없이 종료한다.
- 보수적 판정 trade-off: 경계 케이스 (`payload_size` 가 `OR_MAX_BYTE` 또는 `OR_MAX_SHORT` 인근) 에서 본 정책이 실제 필요량보다 1 컬럼 더 외부화할 수 있다. 정확성 영향 없고 fit 미달성 영향 없으며 I/O 미세 비효율만 존재한다. `heap_attrinfo_get_record_header_size` 의 `offset_size` 결정에는 두 경계 (BYTE-SHORT 는 `OR_MAX_BYTE = 255`, SHORT-INT 는 `OR_MAX_SHORT = 65535`) 가 있어 이 over-estimate 가 실제로 추가 외부화를 유발하는 경우는 record 당 최대 2 회로 제한된다.

---

## Acceptance Criteria

- [ ] (i) record `<= DB_PAGESIZE/4`: OOS 외부화 발생하지 않음. `*has_oos = false`, 모든 i 에 대해 `oos_columns[i] = false`.
- [ ] (ii) record `> DB_PAGESIZE/4`, 큰 컬럼 1 개로 fit 가능: 가장 큰 후보 1 개만 `oos_columns[i] = true`, 나머지는 heap 잔존.
- [ ] (iii) record `> DB_PAGESIZE/4`, 큰 컬럼 1 개로 부족: 큰 컬럼부터 순서대로 추가 외부화하다 fit 시 break.
- [ ] (iv) record `> DB_PAGESIZE/4`, 모든 후보 외부화해도 fit 실패: 모든 후보를 외부화한 결과 후보 전부 demotion 상태로 종료. 기존 무차별 정책과 결과는 같으나 도달 경로가 다름. `*has_oos = true`, 모든 후보 인덱스에 대해 `oos_columns[i] = true`.
- [ ] (v) record `> DB_PAGESIZE/4`, 가변 컬럼이 모두 `<= 512 B` 라 후보가 0 개: demotion 미발생. `*has_oos = false`, 모든 i 에 대해 `oos_columns[i] = false`.
- [ ] OOS isolation `.ctl` 시리즈 (CircleCI `test_sql` job) 그린.
- [ ] CircleCI `test_sql` / `test_medium` 그린 (CDC/replication 회귀 항목 포함).
- [ ] 주요 crash recovery 시나리오 (M1 5.1-5.5 시리즈) 통과.

## Definition of Done

- [ ] 위 Acceptance Criteria 충족
- [ ] CircleCI `test_sql`, `test_medium` 그린
- [ ] PR 리뷰 승인
- [ ] OOS 관련 내부 문서 (있는 경우) 업데이트

---

## Benchmark Plan

PR merge gate 가 아닌 측정 항목이다. AC 와 별도로 PR 본문 또는 후속 코멘트에 결과를 첨부한다.

- 시나리오 (a) - case (ii) 검증 (이유 절 numerical example 과 동일 구성): 가변 6 컬럼 record (1.6 KB 1 개 + 600 B 5 개), INSERT N 회 후 SELECT 시 pgbuf I/O count 측정. 변경 전후 OOS 측 read I/O 변화량을 기록한다.
- 시나리오 (b) - case (iii) 검증: 가변 6 컬럼 모두 700 B (각각 `> 512 B` 후보). 큰 순서로 N 개 demotion 후 fit 하는 경로를 강제하고, 외부화된 컬럼 수와 OOS 페이지 사용량을 변경 전후 비교한다.
- WAL volume 측정: heap WAL 과 OOS WAL 분량을 변경 전후 비교한다. 분포 이동 (heap WAL 증가, OOS WAL 감소) 의 절대 폭을 기록하고, heap WAL 증가가 5% 이상이면 후속 검토 대상으로 분류한다.

---

## Remarks

- bestspace (CBRD-26658), compaction, vacuum 작업과 병렬 진행 가능하다 (의존 관계 없음).
- M3 의 OOS OID 재사용 (deduplication) 단계에서 입력 cardinality 가 줄어들기에, dedup 효과 측정 시 노이즈가 줄어든다.
- 부모 epic: CBRD-26583 (M2).
- 관련: CBRD-26536 (PG TOAST 압축 시점 서베이), CBRD-26516 (redundant `oos_read`).
