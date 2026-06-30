# [OOS] SHOW HEAP CAPACITY 의 OOS 외부 저장 통계 정책 검토

## Issue Triage

**이슈 수행 목적**: OOS 도입 후 `SHOW HEAP CAPACITY` 와 관련 heap 진단 출력이 레코드 크기와 외부 저장 공간을 어떻게 보여야 하는지 정리한다. 기존 heap 본체 통계와 OOS 파일 통계를 분리해서 볼 수 있는 SQL 수준의 진단 스펙을 확정할 수 있도록 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `SHOW HEAP CAPACITY` 는 `Avg_rec_len` 을 제공하며, legacy overflow 는 외부 본문까지 object length 로 취급한다. OOS 는 레코드가 `DB_PAGESIZE/4` 를 넘을 때 큰 가변 컬럼을 `OR_OOS_INLINE_SIZE`(16B) 인라인 슬롯으로 바꾸므로, 같은 논리 row 라도 heap 본체 길이는 의도적으로 작아진다.
- **영향**: QA 도구 공백 - release 빌드의 SQL 출력만으로는 "row 가 OOS 로 빠졌는지", "heap 본체가 얼마나 줄었는지", "OOS 파일이 얼마를 차지하는지" 를 한 번에 확인하기 어렵다. 현재는 debug 로그나 csql 세션 명령 `;oos_stats` 에 의존하게 된다.

**이슈 수행 방안**: 사용자 요청 범위는 "show heap & oos survey/proposals" 이다. 본문에서 후보를 비교하고 권장안을 제시하되, 최종 컬럼명과 기존 컬럼 의미 변경 여부는 `TBD - 합의 미확인` 으로 둔다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/parser/show_meta.c`, `src/parser/csql_grammar.y`, `src/query/show_scan.c`, `src/storage/heap_file.c`, `src/storage/oos_file.cpp`, `src/compat/db_oos.h`, manual `sql/query/show.rst` 가 후보 변경 지점이다. DBA 전용 진단 SQL 출력이므로 일반 DML 호환성 영향은 낮지만, 컬럼 추가는 클라이언트 스크립트와 QA 비교 파일에 영향을 줄 수 있다.

---

## Description

### 확인한 현재 동작

`SHOW HEAP CAPACITY` 는 manual 에서 "table capacity" 를 보여주는 문장으로 설명되며, `Avg_rec_len` 은 "Average object length" 로 문서화되어 있다. 구현도 단순한 home-slot 길이만 세지 않는다. 일반 `REC_HOME` / `REC_NEWHOME` 은 `spage_get_record_length()` 를 합산하지만, legacy heap overflow 인 `REC_BIGONE` 은 home 슬롯의 forwarding record 를 overhead 로 보고 `overflow_get_capacity()` 를 통해 overflow 본문 길이와 page 수를 별도로 더한다.

```
SHOW HEAP CAPACITY OF t
  -> heap_capacity_next_scan()
       -> heap_get_capacity()
            REC_HOME / REC_NEWHOME: sum_reclength += heap slot length
            REC_BIGONE           : sum_reclength += overflow body length
                                   num_pages     += overflow pages
```

OOS (Out-of-row Storage - heap 의 큰 가변 컬럼을 별도 OOS 파일로 분리하는 저장 방식) 는 이 전제에 새 축을 추가한다. write 시점에 record 가 `DB_PAGESIZE/4` 를 넘으면 가장 큰 가변 컬럼부터 OOS 로 보내고, heap record 의 variable area 에는 `[OOS OID | full_length]` 로 구성된 16바이트 슬롯만 남긴다. 따라서 기존 `heap_get_capacity()` 를 그대로 두면 `Avg_rec_len` 은 "확장한 object 길이" 가 아니라 "OOS OID 를 품은 compact heap record 길이" 에 가까워진다.

### 현황 조사

| 진단 경로 | 현재 제공 값 | 소스 | OOS 관점 |
|-----------|--------------|------|----------|
| `SHOW HEAP HEADER` | `Overflow_vfid`, `Estimates_avg_rec_len` 등 | `show_meta.c:317`, `heap_file.c:19401` | `HEAP_HDR_STATS` 에 `oos_vfid` 가 있으나 출력하지 않는다. estimate 는 bestspace hint 이므로 heap 본체 기준으로 남기는 편이 자연스럽다. |
| `SHOW HEAP CAPACITY` | `Num_pages`, `Num_overflowed_recs`, `Avg_rec_len` 등 | `show_meta.c:346`, `heap_file.c:9554` | legacy overflow 는 포함하지만 OOS file page/payload 는 포함하지 않는다. |
| `SHOW SLOTTED PAGE SLOTS` | page slot 별 `Length` | `show_meta.c:244`, `heap_file.c:20093` | 물리 page slot 진단이다. heap page 에서는 OOS inline slot 이 포함된 compact record 길이를, OOS page 에서는 OOS chunk record 길이를 보여야 한다. 의미 변경이 필요하지 않다. |
| `;oos_stats <class>` | OOS VFID, page 수, record slot 수, `recs_sumlen` | `csql.c:1245`, `oos_file.cpp:2043` | csql 세션 명령이라 SQL `SHOW` 문이 아니고 manual 의 `SHOW` 계열과 분리되어 있다. |
| `cubrid spacedb` | file type 별 page 수 | `file_manager.c:12235` | 현재 `FILE_OOS` 를 별도 분류하지 못하고 heap 으로 임시 집계한다. |

> **요지**: 기존 heap overflow 는 `SHOW HEAP CAPACITY` 에서 이미 "외부 본문까지 포함한 object length" 로 취급된다. OOS 를 같은 수준으로 다루려면 heap 본체 길이, OOS logical payload, OOS file footprint 를 같은 출력에서 구분해야 한다.

### 용어 분리

| 용어 | 의미 | 계산 방향 |
|------|------|-----------|
| heap inline length | heap page slot 에 실제 저장된 record 길이 | `spage_get_record_length()` 기준. OOS column 은 16B inline slot 으로 계산된다. |
| expanded object length | OOS 값을 다시 펼쳤을 때의 논리 record 길이 | `heap inline length + Σ(oos_full_length - OR_OOS_INLINE_SIZE)` |
| OOS payload bytes | heap record 들이 참조하는 OOS 값의 논리 byte 합 | heap recdes 의 inline `full_length` 를 읽어 합산한다. OOS page I/O 없이 계산 가능하다. |
| OOS file footprint | OOS 파일이 실제 점유한 page/byte 수 | `file_get_num_user_pages()` 와 `DB_PAGESIZE` 기준. vacuum 전 dead version 이 남긴 공간도 포함될 수 있다. |
| OOS occupied slots | OOS page 에 남아 있는 slotted record 수 | multi-chunk 값은 chunk 수만큼 늘어나므로 row 수나 column 수와 다르다. |

## Specification Changes

### 후보 비교

| 순위 | 후보 | 설명 / 고려사항 |
|------|------|-----------------|
| 1 | `SHOW HEAP CAPACITY` 를 OOS-aware 로 확장 | 기존 `Avg_rec_len` 을 "expanded object length" 로 맞추고, heap 본체 길이와 OOS 파일 footprint 를 별도 컬럼으로 추가한다. manual 의 "Average object length" 설명 및 `REC_BIGONE` 처리와 가장 잘 맞는다. 컬럼 추가가 있으므로 QA answer 와 외부 스크립트 영향 확인이 필요하다. |
| 2 | `Avg_rec_len` 은 compact heap 기준으로 두고 `Avg_expanded_rec_len` 을 새로 추가 | 현재 OOS branch 의 물리 동작을 보존한다. 다만 `REC_BIGONE` 에서 overflow 본문을 더하던 기존 의미와 달라져, 같은 "외부 저장" 을 overflow 와 OOS 에서 다르게 설명해야 한다. |
| 3 | `SHOW OOS CAPACITY OF <table>` 를 별도 신설 | `;oos_stats` 를 SQL `SHOW` 체계로 승격하는 방식이다. heap output 호환성은 가장 좋지만, 사용자는 heap 과 OOS 를 두 문장으로 합쳐 해석해야 한다. |
| 4 | `;oos_stats` 만 유지하고 manual 에만 보강 | 구현량은 가장 작다. 그러나 SQL `SHOW` 계열과 분리되어 자동화와 QA 비교에 쓰기 어렵고, release 빌드 진단 문장으로 자리잡기 힘들다. 권장하지 않는다. |

### 권장 스펙 초안

권장안은 후보 1 을 기본으로 한다. 기존 `SHOW HEAP CAPACITY` 는 table 의 row 저장 상태를 보는 문장이므로, OOS 가 생긴 뒤에도 "row 의 논리 크기" 와 "저장 위치별 물리 크기" 를 한 번에 보여야 한다.

기존 컬럼은 가능한 유지하고, 새 컬럼은 뒤에 추가한다.

| 컬럼 | 타입 | 의미 |
|------|------|------|
| `Avg_rec_len` | `int` | OOS 값을 펼친 평균 object 길이. OOS 가 없는 table 은 현재와 동일하다. |
| `Avg_heap_inline_rec_len` | `int` | heap page 에 실제 저장된 평균 compact record 길이. |
| `Num_oos_values` | `bigint` | heap record 가 참조하는 OOS value 수. multi-chunk 값도 value 1개로 센다. |
| `Oos_payload_bytes` | `bigint` | heap record 가 참조하는 OOS 값의 `full_length` 합. |
| `Oos_file_pages` | `bigint` | OOS 파일의 user page 수. 파일이 없으면 0. |
| `Oos_file_bytes` | `bigint` | `Oos_file_pages * DB_PAGESIZE`. |
| `Oos_file_occupied_slots` | `bigint` | OOS page 에 남아 있는 slotted record 수. multi-chunk 값은 chunk 수만큼 센다. |
| `Oos_file_record_bytes` | `bigint` | OOS page 에 남아 있는 record body 길이 합. vacuum 전 잔여 record 가 있으면 `Oos_payload_bytes` 와 다를 수 있다. |

`SHOW HEAP HEADER` 는 `Overflow_vfid` 옆에 `OOS_vfid` 를 추가하는 후보가 있다. header record 에 이미 `oos_vfid` 가 있으므로, 출력만 보강하면 table 과 OOS file 의 연결을 직접 확인할 수 있다.

`SHOW SLOTTED PAGE SLOTS` 의 `Length` 는 바꾸지 않는 편이 맞다. 이 문장은 특정 page 의 slot 구조를 보는 물리 진단 도구이며, heap page 에서는 compact record 길이를 그대로 보여야 한다. OOS page 를 지정하면 OOS chunk record 길이를 보여주는 것으로 충분하다.

## Implementation

### 코드 흐름

```
SHOW HEAP CAPACITY
  parser/show_meta.c
    -> metadata_of_heap_capacity()
  query/show_scan.c
    -> heap_capacity_next_scan()
  storage/heap_file.c
    -> heap_get_capacity()

추가 필요:
  heap_get_capacity()
    -> heap slot scan 중 OOS inline flag 확인
    -> inline full_length 를 읽어 expanded length 계산
    -> 필요 시 OOS VFID 를 찾아 file footprint 통계 결합
```

### 구현 메모

`Avg_rec_len` 을 expanded object length 로 계산하려면 OOS page 를 읽을 필요가 없다. heap record 의 OOS inline layout 은 `[OID (8B) | full_length (8B)]` 이고, `heap_oos.cpp` 와 `heap_attrvalue_read_oos_inline()` 이 이미 `or_get_bigint()` 로 `full_length` 를 읽는다. capacity scan 에서는 같은 파싱 규칙을 별도 helper 로 묶어 `oos_extra = full_length - OR_OOS_INLINE_SIZE` 를 더하면 된다.

`HEAP_HDR_STATS.estimates.recs_sumlen` 은 bestspace hint 에 쓰이는 내부 값이므로 논리 record 길이로 바꾸면 안 된다. `SHOW HEAP HEADER` 의 `Estimates_avg_rec_len` 은 heap 본체 기준 estimate 로 두고, manual 에 "heap inline estimate" 라는 설명을 보강하는 쪽이 안전하다.

OOS file footprint 는 기존 `oos_get_stats_by_vfid()` / `xoos_get_stats_by_class_oid()` 를 재사용할 수 있다. 다만 현재 `oos_get_stats_by_vfid()` 는 모든 page 를 순회하고 conditional latch 실패 page 를 건너뛰므로, `SHOW HEAP CAPACITY` 의 exact 통계와 결합할 때 "best-effort file footprint" 인지 "blocking exact footprint" 인지 정책을 정해야 한다.

`FILE_OOS` 가 `cubrid spacedb` 에서 heap 으로 임시 집계되는 문제는 별도 도구 이슈와 연결된다. 이 이슈에서는 `SHOW HEAP CAPACITY` 의 table 단위 진단을 우선 정하고, 전체 DB 공간 도구의 file type 분리는 후속 또는 관련 이슈로 두는 편이 낫다.

## Acceptance Criteria

- [ ] `SHOW HEAP CAPACITY OF <table>` 이 OOS 없는 table 에서 기존 `Avg_rec_len` 결과와 동일하게 동작한다.
- [ ] OOS table 에서 `Avg_rec_len` 과 `Avg_heap_inline_rec_len` 이 구분되어 출력된다.
- [ ] OOS table 에서 `Oos_payload_bytes`, `Oos_file_pages`, `Oos_file_bytes` 등 외부 저장 지표가 SQL 결과로 확인된다.
- [ ] `REC_BIGONE` legacy overflow table 과 OOS table 의 `Avg_rec_len` 의미가 manual 에서 일관되게 설명된다.
- [ ] `SHOW SLOTTED PAGE SLOTS` 의 `Length` 는 물리 slot 길이로 유지되고, manual 에 OOS page 를 볼 때의 의미가 보강된다.
- [ ] partition table 의 `SHOW ALL HEAP CAPACITY` 에서 base/partition 별 OOS 지표가 각 row 에 맞게 출력된다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] manual `SHOW HEAP HEADER`, `SHOW HEAP CAPACITY`, `SHOW SLOTTED PAGE SLOTS` 설명 갱신
- [ ] 기존 `;oos_stats` 를 유지할지 SQL `SHOW` 로 대체/병행할지 결정

## Open Questions

- `Avg_rec_len` 의 의미를 권장안처럼 expanded object length 로 고정할지, 기존 OOS branch 동작을 보존하고 새 `Avg_expanded_rec_len` 을 추가할지 결정해야 한다.
- OOS file footprint 를 `SHOW HEAP CAPACITY` 에서 blocking exact scan 으로 계산할지, 현재 `;oos_stats` 처럼 conditional latch 기반 best-effort 로 둘지 결정해야 한다.
- `Oos_file_record_bytes` 가 OOS record header 를 포함하는 page record body 합인지, 순수 payload 합인지 컬럼명을 통해 명확히 해야 한다.
- `SHOW HEAP HEADER` 에 `OOS_vfid` 를 추가할 경우 기존 `Overflow_vfid` 와의 출력 순서 및 manual 예제를 갱신해야 한다.
- `cubrid spacedb` 의 `FILE_OOS` 분리까지 같은 이슈에서 처리할지, 별도 이슈로 연결할지 결정해야 한다.

## Reference Code

- `src/parser/show_meta.c:346` - `SHOW HEAP CAPACITY` metadata 와 `Avg_rec_len` 컬럼
- `src/parser/csql_grammar.y:7555` - `HEAP CAPACITY` show type grammar
- `src/storage/heap_file.c:9554` - `heap_get_capacity()`
- `src/storage/heap_file.c:9639` - 일반 heap record 길이 합산
- `src/storage/heap_file.c:9641` - `REC_BIGONE` 처리
- `src/storage/heap_file.c:9650` - legacy overflow 본문 길이 합산
- `src/storage/heap_file.c:9696` - `Avg_rec_len` 계산
- `src/storage/heap_file.c:12203` - OOS largest-first demotion 과 statistics TODO
- `src/base/object_representation.h:455` - `OR_OOS_INLINE_SIZE`
- `src/storage/heap_oos.cpp:146` - OOS inline layout `[OID | full_length]`
- `src/storage/oos_file.cpp:2043` - OOS file stats scan
- `src/executables/csql.c:1245` - `;oos_stats` csql session command
- `src/storage/file_manager.c:12235` - `FILE_OOS` spacedb 임시 heap 집계
