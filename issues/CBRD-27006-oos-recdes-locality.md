# [OOS] heap RECDES 내 여러 OOS 컬럼의 page locality 개선

## Issue Triage

**이슈 수행 목적**: 하나의 heap `RECDES` 에 여러 OOS 컬럼이 있을 때 단일 청크 OOS 값들이 같은 OOS page 에 배치되도록 하고, 같은 `(volid,pageid)` 를 가리키는 OOS 값은 page 를 한 번만 fix 해서 읽도록 한다. 결과적으로 OOS column 수에 비례하던 `pgbuf_fix` churn 을 줄인다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: OOS demotion 은 record 가 `DB_PAGESIZE/4` 를 넘고 variable value 가 `OR_OOS_INLINE_SIZE` 보다 클 때 발생한다. 현재 write 는 `heap_attrinfo_insert_to_oos()` 가 OOS column 마다 `oos_insert()` 를 호출하고, single-chunk 값도 `oos_find_best_page()` 를 매번 거치므로 한 heap `RECDES` 의 여러 OOS 값이 page 단위로 묶이지 않는다. read 도 record-level Expand 는 `heap_record_replace_oos_oids()` / `heap_oos_read_blobs()` 에서, lazy Resolve 는 `heap_attrvalue_read_oos_inline()` 에서 각각 `oos_read()` 를 값마다 호출한다.
- **영향**: 성능 저하 - 같은 row 안의 OOS 값들이 같은 page 에 들어갈 수 있어도 insert/find/fix/update-bestspace 가 값 단위로 반복되고, read 에서도 같은 OOS page 를 여러 번 `pgbuf_fix` 할 수 있다. 여러 OOS 컬럼을 가진 row 를 많이 쓰거나 읽는 workload 에서 buffer latch/lookup 비용이 컬럼 수만큼 커진다.

**이슈 수행 방안**:

이번 이슈에서 합의된 범위만 수행한다.

| 범위 | 결정 |
|------|------|
| write locality | single-chunk OOS 값들을 batch 로 모아, 한 subrun 이 통째로 들어갈 수 있는 page 를 재사용하거나 fresh page 를 할당한다. |
| read locality | `oos_read_many()` 에서 head OOS OID 를 `(volid,pageid)` 로 group 해서 같은 OOS page 를 한 번만 read latch 로 fix 한다. |
| OOS OID 모델 | value 하나당 OOS OID 하나를 유지한다. OID sharing, deduplication, multi-column combined OOS record format 은 하지 않는다. |
| format / log | heap inline format, OOS on-disk record format, WAL/replication log format 은 바꾸지 않는다. |
| multi-chunk | 기존 multi-chunk path 는 유지한다. phase 1 에서 continuation page locality 최적화는 범위 밖이다. |

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 요약

- **변경 범위 / 영향**: 주 대상은 `src/storage/heap_file.c`, `src/storage/heap_oos.cpp`, `src/storage/oos_file.cpp`, `src/storage/oos_file.hpp` 이다. 단위 테스트는 `unit_tests/oos/` 쪽 보강이 필요하다.
- **주요 검증 축**: replication OID 순서, latch 순서, partial insert 실패 처리, lazy Resolve 의 requested-column 범위, 같은 page read 의 fix count 를 확인한다.

## Description

OOS(Out-of-row Storage, heap 의 큰 가변 컬럼을 별도 OOS file 로 분리하는 저장 방식) 는 write 시점에 큰 variable column 을 OOS record 로 옮긴다. heap record 에는 실제 payload 대신 OOS OID 와 length 로 된 inline slot 이 남는다.

이번 이슈는 demotion 정책을 바꾸지 않는다. 대상은 이미 OOS 로 선택된 값들을 OOS file 에 넣고 다시 읽는 과정이다. 지금은 같은 heap `RECDES` 안에 OOS 값이 여러 개 있어도 각 값이 독립적인 scalar call 로 처리된다. `pgbuf_fix` 는 page buffer pool 에서 page 를 latch 하고 가져오는 함수라, 같은 page 를 반복해서 fix/unfix 하면 실제 I/O 가 없더라도 latch, hash lookup, page validation, bestspace 갱신 비용이 값 수만큼 반복된다.

현재 write 흐름은 아래처럼 OOS column 1개가 반복 단위다.

```text
[write]
heap_attrinfo_insert_to_oos()
  for each OOS column
    -> heap_attrinfo_dbvalue_to_recdes()
    -> oos_insert()
       -> oos_insert_within_page()
          -> oos_find_best_page()
          -> spage_insert()
          -> oos_log_insert_physical()
          -> oos_stats_add_bestspace()

* 반복 경계: OOS column 1개
```

`oos_find_best_page()` 는 필요한 record 길이 하나를 기준으로 page 를 찾는다. 따라서 한 row 의 single-chunk OOS 값들이 모두 한 page 에 들어갈 수 있어도, 값별 page 선택 결과가 갈라질 수 있다. page 를 재사용하더라도 `spage_insert()` 와 bestspace 갱신이 value 단위로 수행된다.

read 쪽도 같은 패턴이다. raw `RECDES` bytes 를 소비하는 경로는 OOS Expand(레코드 단위로 모든 OOS inline slot 을 실제 값으로 치환하는 eager 처리) 를 사용하고, attribute layer 는 OOS Resolve(요청된 OOS column 만 읽는 lazy 처리) 를 사용한다.

```text
[record-level Expand]
heap_record_replace_oos_oids()
  -> heap_oos_read_blobs()
     for each OOS VOT entry
       -> oos_read()
          -> oos_read_within_page()
             -> pgbuf_fix(..., PGBUF_LATCH_READ, ...)

[lazy Resolve]
heap_attrinfo_read_dbvalues()
  -> heap_attrvalue_read()
     -> heap_attrvalue_point_variable()
        -> heap_attrvalue_read_oos_inline()
           -> oos_read()
```

`oos_read()` 는 caller 의 OID 가 chain head 인지, OOS header 의 total length 가 caller buffer 길이와 맞는지, output writer 가 정확히 채워졌는지를 검증한다. 이 검증은 유지해야 한다. 바뀌는 것은 같은 head page 에 있는 여러 requested OOS 값의 첫 page 를 묶어서 읽는 방식이다. multi-chunk continuation chain 은 기존 경로를 유지해도 된다.

## Specification Changes

SQL 과 외부 사용자 문법 변경은 없다. manual 관점에서는 N/A 이다.

내부 동작 스펙은 다음과 같이 정의한다.

| 항목 | 스펙 |
|------|------|
| write batch 단위 | 한 heap `RECDES` 에서 OOS 로 선택된 single-chunk 값들의 연속 run. |
| page reuse 기준 | 기존 OOS page 를 재사용하려면 현재 subrun 전체가 들어가야 한다. 일부 value 만 들어가서 같은 `RECDES` 가 여러 page 로 흩어지는 reuse 는 피한다. |
| subrun split | 한 empty OOS page 에 모두 들어가지 않는 single-chunk run 은 request 순서를 유지한 채 page capacity 경계에서 나눈다. |
| OOS OID | 각 value 는 독립 OOS OID 를 가진다. 여러 column 이 한 OID 를 공유하지 않는다. |
| read grouping | head OOS OID 의 `(volid,pageid)` 가 같은 request 를 같은 page fix 안에서 처리한다. |
| lazy Resolve 범위 | `heap_attrinfo_read_dbvalues()` 계열은 requested attribute 만 pre-scan 한다. 같은 `RECDES` 안에 있다는 이유로 미요청 OOS column 을 읽지 않는다. |
| multi-chunk | head chunk read 의 correctness 는 유지한다. continuation page locality 는 이번 phase 의 목표가 아니다. |

## Implementation

쓰기 경로에는 scalar `oos_insert()` 옆에 batch API 를 추가한다. container type 은 local style 에 맞춰 조정할 수 있지만, request order 와 output contract 는 고정한다.

```c++
struct oos_insert_request
{
  oos_buffer src;
  OID *oid_out;
  DB_BIGINT *length_out;
};

int oos_insert_many (THREAD_ENTRY *thread_p, const VFID &oos_vfid,
                     cubbase::span<oos_insert_request> requests);
```

`heap_attrinfo_insert_to_oos()` 는 OOS 로 선택된 attribute 를 `attr_info->values[]` 순서대로 모은다. 각 DB_VALUE 는 `heap_attrinfo_dbvalue_to_recdes()` 로 serialize 하고, batch call 이 끝날 때까지 source bytes 를 안정적인 memory 에 둔다. `oos_insert_many()` 성공 후에는 기존처럼 `oos_oids[]`, `oos_lengths[]`, `thread_p->oos_oids` 에 결과를 logical attribute order 로 반영한다.

`oos_insert_many()` 내부는 request 를 single-chunk run 과 multi-chunk item 으로 나눈다.

```text
requests in logical attribute order
  -> single-chunk run
       -> page-sized subrun
          -> find page by total required space
          -> fix page once with write latch
          -> spage_insert() for each request
          -> RVOOS_INSERT per physical slot
          -> bestspace update once
  -> multi-chunk item
       -> flush active single-chunk run
       -> existing oos_insert_across_pages()
       -> keep dummy/head replication behavior
```

batch write fix 를 잡은 상태에서 bestspace/header page 탐색을 새로 수행하지 않는다. page 선택은 subrun 전체 필요 공간을 기준으로 먼저 끝내고, 그 뒤 data page 를 write latch 로 fix 해서 여러 slot 을 넣는다. 이 순서를 깨면 OOS data page 와 bestspace/header page 사이의 latch-order 위험이 생긴다.

replication 순서는 반드시 보존한다. `locator_fixup_oos_oids_in_recdes()` 는 `thread_p->oos_oids` 를 attribute order 로 소비한다. batch 가 physical page locality 를 위해 내부 page 선택을 묶더라도 logical insert result 의 순서가 바뀌면 안 된다. multi-chunk 의 dummy OID marker 와 head OID pairing 도 기존 방식 그대로 유지한다.

읽기 경로에는 scalar `oos_read()` 옆에 grouped API 를 추가한다.

```c++
struct oos_read_request
{
  OID oid;
  oos_buffer dest;
};

int oos_read_many (THREAD_ENTRY *thread_p, cubbase::span<oos_read_request> requests);
```

`oos_read_many()` 는 request buffer 를 먼저 검증한 뒤 head OOS OID 의 `(volid,pageid)` 로 request 를 group 한다. 각 group 은 page 를 read latch 로 한 번 fix 하고, group 안의 slot 을 `spage_get_record(..., PEEK)` 로 읽는다. scalar `oos_read()` 가 가진 header 검증은 같은 수준으로 유지한다.

- requested OID 는 head chunk 이어야 한다.
- `OOS_RECORD_HEADER.total_data_length` 는 caller destination size 와 같아야 한다.
- slot length 는 `OOS_RECORD_HEADER_SIZE` 이상이어야 한다.
- destination buffer 는 정확히 채워져야 한다.

record-level Expand 는 `heap_oos_read_blobs()` 가 모든 OOS inline header 를 먼저 파싱하고 buffer 를 할당한 뒤, request array 를 만들어 `oos_read_many()` 를 한 번 호출하는 형태로 바꾼다. lazy Resolve 는 `heap_attrinfo_read_dbvalues()` 와 `heap_attrinfo_read_dbvalues_without_oid()` 에서 requested attribute 만 pre-scan 해 OOS request 를 만든다. 이후 preloaded buffer 에서 DB_VALUE transform 을 수행하고, error path 포함 모든 temporary buffer 를 정리한다. index key extraction 처럼 단일 attribute helper 를 직접 쓰는 경로는 profiling 전까지 scalar path 에 남겨 둔다.

debug instrumentation 은 기존 OOS debug style 안에서만 추가한다. release hot path 에 무조건적인 비용을 얹지 않는다.

| 지표 | 용도 |
|------|------|
| insert batch request count | batch 적용 여부 확인 |
| single-chunk subrun count | page capacity split 확인 |
| reused page / fresh page count | locality-preserving reuse 정책 확인 |
| values inserted per fixed page | write-side fix 절감 확인 |
| read request count | grouped read 적용 범위 확인 |
| distinct OOS pages fixed | read-side fix 절감 확인 |
| values read per fixed page | 같은 page grouping 효과 확인 |

## Acceptance Criteria

- [ ] 여러 single-chunk OOS 값의 combined record length 가 한 OOS page 에 들어가면, 반환된 OOS OID 들의 `(volid,pageid)` 가 같아진다.
- [ ] 기존 OOS page 가 current subrun 전체를 담을 수 있을 때만 재사용된다.
- [ ] 개별 value 는 들어가지만 subrun 전체는 못 담는 partial free page 만 있을 때, fresh page 를 할당해 한 `RECDES` 의 single-chunk run 이 흩어지지 않는다.
- [ ] 한 page 에 못 들어가는 single-chunk run 은 request order 를 보존하며 page-sized subrun 으로 나뉜다.
- [ ] single-chunk 와 multi-chunk 가 섞여도 반환 OID order, `thread_p->oos_oids`, replication dummy/head pairing 이 기존 의미를 유지한다.
- [ ] batch insert 중 일부 slot insert 이후 에러가 나도 기존 OOS insert 와 같은 transaction-abort 계약을 유지하며, caller 가 같은 transaction 을 계속 진행하지 않는다.
- [ ] write latch 로 data page 를 잡은 상태에서 bestspace/header page 탐색을 수행하지 않는다.
- [ ] record-level Expand 가 같은 OOS page 의 여러 OID 를 읽을 때 page fix count 가 distinct `(volid,pageid)` 수와 일치한다.
- [ ] lazy Resolve 는 requested OOS attribute 만 읽고, 같은 `RECDES` 안의 미요청 OOS attribute 는 읽지 않는다.
- [ ] SQL level 에서 여러 OOS column 의 INSERT / SELECT / UPDATE 값 동등성이 유지된다. predictable disk size 를 위해 `BIT VARYING` 값을 사용한다.
- [ ] heap inline format, OOS on-disk format, WAL/replication log format 변경이 없다.

## Definition of done

- [ ] 위 Acceptance Criteria 를 만족한다.
- [ ] `./build.sh -m debug -c "-DUNIT_TESTS=ON"` 또는 동일한 공개 CMake preset 기반 debug unit-test build 가 통과한다.
- [ ] OOS unit test 단독 실행 명령은 `TBD - 합의 미확인` 이다.
- [ ] 여러 OOS column 을 가진 SQL regression 또는 shell scenario 가 추가되고 통과한다.
- [ ] debug instrumentation 으로 write/read page fix 절감이 확인된다.
- [ ] 문서/매뉴얼 변경 필요 여부를 확인한다. 현재 스펙상 사용자-facing 문법 변경은 N/A 이다.

## Remarks

- issue type 은 `Improve Function/Performance` 로 둔다.
- OOS unit test 의 portable 단독 실행 명령은 아직 확인하지 않았다. 구현 PR 단계에서 CI 와 같은 공개 명령으로 확정해야 한다.
