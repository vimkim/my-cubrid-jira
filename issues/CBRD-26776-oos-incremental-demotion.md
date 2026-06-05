# [OOS] [M2] heap recdes 가 임계값 아래로 떨어질 때까지 큰 컬럼부터 점진 OOS 전송

## Issue Triage

> **목적** (필수)
> heap recdes 임계값을 `DB_PAGESIZE/4` 로 상향하고, OOS demotion 을 큰 컬럼부터 한 개씩 점진 적용한다.
>
> **이유** (필수)
> 현재는 임계값을 1 B 만 넘어도 512 B 초과 가변 컬럼을 **일괄** 외부화한다. 큰 컬럼 1 개 demote 만으로 fit 가능한 record 도 작은 컬럼까지 OOS 로 빠져, SELECT 시 `oos_read` I/O 와 OOS 파일 증가가 누적된다.
> 예) 가변 6 컬럼(1.6 KB ×1 + 600 B ×5) record → demote 대상 **6 개 → 1 개**, OOS read **6 회 → 1 회**.
>
> **방안**
> `heap_attrinfo_determine_disk_layout()` 의 후보 선정 블록을 「size 내림차순 정렬 → 큰 컬럼부터 demote → 임계값 도달 시 break」 알고리즘으로 교체하고, record 임계값을 `DB_PAGESIZE/8 → DB_PAGESIZE/4` 로 상향, OOS 후보 floor 를 `512 B → OR_OOS_INLINE_SIZE (16 B)` 로 하향한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 만으로 충분하고, 구현/리뷰 단계에서 참고한다. 서술 기준은 16 KB 페이지 (`DB_PAGESIZE = 16384`).

### At a glance

| | 기존 (M1) | 변경 후 |
|---|---|---|
| record 임계값 | `DB_PAGESIZE/8` (= 2 KB) | `DB_PAGESIZE/4` (= 4 KB) |
| 외부화 방식 | 512 B 초과 가변 컬럼 **전부 일괄** | 큰 컬럼부터 **1 개씩**, fit 시 중단 |
| 변경 위치 | — | `heap_file.c:12167-12227` 한 함수 |
| 포맷/프로토콜 | — | recdes·MVCC 헤더·OOS 파일·WAL·replication **전부 불변** |

### 동작 원리

트리거는 두 단계다. ① **record 임계값** `header_size + payload_size + mvcc_extra > DB_PAGESIZE/4`, ② **컬럼 조건** 가변 컬럼이고 `column_size > OR_OOS_INLINE_SIZE` (16 B) — 즉 외부화가 inline record 를 실제로 줄이는 (= 자기 OOS stub 보다 큰) 컬럼만 후보.

```
① 초과?
 ├─ no  → 변경 없음 (전부 inline)
 └─ yes → ② 만족 컬럼을 size 내림차순 정렬
           for cand in 후보:
             record 가 이미 임계값 이하 → break
             cand 를 OOS 로 demote, payload 재계산
```

기존 코드는 ① 이 참이면 ② 만족 컬럼을 **모두** 외부화했다. 변경 후에는 큰 컬럼부터 demote 하다 record 가 임계값 아래로 떨어지면 즉시 멈춘다.

### Worked example

가변 6 컬럼 record: payload 합 4600 B (1.6 KB ×1 + 600 B ×5), 헤더+고정 ~200 B → 전체 ~4800 B (`> 4096 B`).

| | 외부화 대상 | inline record | SELECT 시 OOS read |
|---|---|---|---|
| **기존 (M1)** | 6 컬럼 전부 (모두 > 512 B) | ~296 B | 6 회 |
| **변경 후** | 1.6 KB ×1 (payload `−1600 + 16 = −1584` → ~3216 B) | ~3216 B | 1 회 |

### PG TOAST 와의 비교

PostgreSQL 16 의 tuple-toaster main loop (`src/backend/access/heap/heaptoast.c`) 는 가장 큰 가변 컬럼을 한 개씩 외부화/압축하고 매 라운드 길이를 재계산해 임계값 이하면 종료한다. 본 변경은 그 외부화 라운드를 차용한다. CUBRID OOS 는 M1 에 압축이 없으므로 압축은 생략하고, 도입(CBRD-26536 서베이) 후 본 정책 위에 압축 라운드를 얹어 자연 확장한다.

---

## Specification Changes

### Trigger policy

| 항목 | 기존 (M1) | 변경 후 |
|---|---|---|
| record 임계값 | `DB_PAGESIZE / 8` (2 KB) | `DB_PAGESIZE / 4` (4 KB) |
| 후보 정렬 | 없음 | 가변 컬럼 size 내림차순 |
| 외부화 순서 | 후보 전부 일괄 | 큰 컬럼부터 1 개씩 순차 |
| 종료 조건 | 모든 후보 처리 후 | 임계값 이하면 `break`; 전부 외부화해도 미달이면 후보 소진 후 종료 |
| 컬럼 floor (OOS 후보) | 가변 + `> 512 B` | 가변 + `> OR_OOS_INLINE_SIZE` (16 B) |

### 외부 인터페이스 — 변경 없음

- `oos_columns[i]` per-column 플래그 시그니처 유지.
- recdes 포맷, MVCC `OR_MVCC_FLAG_HAS_OOS` 비트 의미, WAL 레코드 포맷 모두 불변.

### 복잡도

무시 가능 (가변 컬럼 N ≤ 수십). demotion 진입 시에만 `oos_candidates` 1 회 alloc + 정렬이 발생하고, 임계값 미만 record 는 영향 없다 (`column_size` 벡터는 기존부터 매 호출 alloc 되므로 신규 비용 아님). 측정은 Benchmark Plan 의 micro-bench 로 보강.

---

## Implementation

### 변경 함수

| 함수 | 위치 | 변경 |
|---|---|---|
| `heap_attrinfo_determine_disk_layout()` | `heap_file.c:12167-12227` | 후보를 `std::vector<std::pair<int,int>>` 에 수집 → `std::sort(.., std::greater<>())` 로 내림차순 → 임계값 도달까지 큰 컬럼부터 demote |

STL 헤더 (`<algorithm>`, `<utility>`) 추가. STL/template 라인 5 군데 (함수 시그니처, `column_size`·`oos_candidates` 선언, `std::sort`, range-for 헤더) 에 `// *INDENT-OFF*` / `// *INDENT-ON*` 쌍.

> `oos_columns` 는 호출자 `heap_attrinfo_transform_to_disk_internal()` 에서 `num_values` 크기로 false 초기화되어 단 1 회만 넘어오므로, 본 함수는 demote 한 인덱스만 `true` 로 설정한다.

### 의사 코드

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
  header_size  = heap_attrinfo_get_record_header_size  (attr_info, payload_size, is_mvcc_class, offset_size_ptr);
  mvcc_extra   = is_mvcc_class ? OR_MVCC_MAX_HEADER_SIZE - OR_MVCC_INSERT_HEADER_SIZE : 0;

  if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 4)
    {
      std::vector<std::pair<int, int>> oos_candidates;   /* {column_size, attr index} */

      for (i = 0; i < attr_info->num_values; i++)
        if (!attr_info->values[i].last_attrepr->is_fixed && column_size[i] > OR_OOS_INLINE_SIZE)
          oos_candidates.emplace_back (column_size[i], i);

      std::sort (oos_candidates.begin (), oos_candidates.end (), std::greater<std::pair<int, int>> ());

      for (auto & cand : oos_candidates)
        {
          if (header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 4)
            break;
          (*oos_columns)[cand.second] = true;
          payload_size -= cand.first;
          payload_size += OR_OOS_INLINE_SIZE;
          *has_oos = true;
        }

      header_size = heap_attrinfo_get_record_header_size (attr_info, payload_size, is_mvcc_class, offset_size_ptr);
    }

  return header_size + payload_size;
}
```

### 다운스트림 영향

- `heap_attrinfo_insert_to_oos()`, `heap_attrinfo_transform_variable_to_disk()` 등은 per-column `oos_columns[i]` 만 보므로 호환.
- read 경로 (`heap_record_replace_oos_oids_with_values_if_exists()` 등) 는 VOT `IS_OOS` 비트 기반이라 부분 집합 demote 도 정상 판별.
- **WAL 정확성**: heap recdes·OOS 파일 포맷 동일 → WAL 포맷 불변, recovery 영향 없음.
- **WAL 분포** (정확성 무관): 작은 가변 컬럼이 heap 에 남아 heap WAL 은 다소 증가, OOS WAL 은 감소. → Benchmark Plan 에서 별도 측정.
- **bestspace (CBRD-26658)/compaction/vacuum**: OOS 후보 cardinality 감소로 OOS 페이지 사용량·hot-spot 자연 감소. 정확성 영향 없음.

### 보수적 판정 근거 (stale `header_size`)

루프 내부 비교의 `header_size` 는 트리거 직전 값으로, payload 가 줄어도 즉시 갱신되지 않는다 (루프 후 1 회 재계산). 그래도 정확성은 **항상 안전한 방향** 으로 유지된다:

- **(a) payload 단조 감소** — 후보는 `column_size > OR_OOS_INLINE_SIZE (16)` 이므로 demote 1 회당 `payload_size` 가 `-column_size + 16 < 0` 만큼 strict 감소.
- **(b) header 단조 비감소** — payload 가 줄면 `header_size` 는 감소하거나 동일 (`offset_size` 가 BYTE→SHORT→INT 경계를 역방향 통과할 뿐 증가 없음).
- **⇒ 결론** — 루프의 `header_size` 는 실제값의 over-estimate. 따라서 "실제 size 가 임계값 초과인데 break" 는 불가능 → **over-demote 만 가능, under-demote 불가**.
- **trade-off** — 경계 (`payload_size` 가 `OR_MAX_BYTE = 255` 또는 `OR_MAX_SHORT = 65535` 인근) 에서 실제 필요량보다 1 컬럼 더 외부화할 수 있다. 정확성·fit 영향 없고 I/O 미세 비효율만 존재하며, 경계가 2 개이므로 record 당 최대 2 회로 제한.

---

## Acceptance Criteria

| # | 입력 | 기대 결과 |
|---|---|---|
| i | record `≤ DB_PAGESIZE/4` | 외부화 없음. `has_oos = false`, 모든 `oos_columns[i] = false` |
| ii | `>` 임계값, 큰 컬럼 1 개로 fit | 가장 큰 후보 1 개만 `true`, 나머지 heap 잔존 |
| iii | `>` 임계값, 1 개로 부족 | 큰 컬럼부터 순차 외부화하다 fit 시 `break` |
| iv | `>` 임계값, 전부 외부화해도 미달 | 후보 전부 demote 후 종료. `has_oos = true`, 모든 후보 인덱스 `true` (M1 과 결과 동일, 경로만 상이) |
| v | `>` 임계값, 가변 컬럼 전부 `≤ OR_OOS_INLINE_SIZE (16 B)` (후보 0 개) | demotion 미발생. `has_oos = false`, 모든 `oos_columns[i] = false` |

- [ ] AC i–v 충족
- [ ] OOS isolation `.ctl` 시리즈 (CircleCI `test_sql`) 그린
- [ ] CircleCI `test_sql` / `test_medium` 그린 (CDC/replication 회귀 포함)
- [ ] crash recovery 시나리오 (M1 5.1-5.5) 통과

## Definition of Done

- [ ] Acceptance Criteria 충족
- [ ] CircleCI `test_sql`, `test_medium` 그린
- [ ] PR 리뷰 승인
- [ ] OOS 내부 문서 (있는 경우) 업데이트

---

## Benchmark Plan

> PR merge gate 아님. AC 와 별도로 PR 본문/코멘트에 결과 첨부.

- **(a) case (ii)** — 가변 6 컬럼 (1.6 KB ×1 + 600 B ×5): INSERT N 회 후 SELECT 시 pgbuf I/O count 측정, OOS read I/O 변화량 기록.
- **(b) case (iii)** — 가변 6 컬럼 모두 700 B: 큰 순서로 N 개 demote 후 fit 하는 경로 강제, 외부화 컬럼 수·OOS 페이지 사용량 전후 비교.
- **WAL volume** — heap/OOS WAL 분량 전후 비교. 분포 이동 폭 기록, heap WAL 증가 ≥ 5% 면 후속 검토.

---

## Remarks

- 부모 epic: CBRD-26583 (M2)
- 관련: CBRD-26536 (TOAST 압축 서베이), CBRD-26516 (redundant `oos_read`)
- bestspace (CBRD-26658)/compaction/vacuum 와 의존 없이 병렬 진행 가능
- M3 OOS OID 재사용(dedup) 단계의 입력 cardinality 감소 → dedup 효과 측정 시 노이즈 감소
