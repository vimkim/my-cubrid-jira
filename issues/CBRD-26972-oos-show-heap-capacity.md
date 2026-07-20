# [OOS] SHOW HEAP OOS 진단 SQL 추가

## Issue Triage

**이슈 수행 목적**: OOS (Out-of-row Storage - 큰 가변 길이 컬럼 값을 heap 레코드 밖의 별도 파일에 저장하는 기능) 상태를 DBA 전용 SQL로 확인할 수 있게 한다.

**이슈 수행 이유**:

| 구분 | 진단 스펙 |
|------|-----------|
| **AS-IS (현재 동작 / 배경)** | 기존 `SHOW HEAP` 은 heap 정보만 제공하고, OOS 파일 상태는 개발자용 csql 세션 명령 `;oos_stats` 로 따로 확인한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 신규 `SHOW HEAP OOS` 와 `SHOW ALL HEAP OOS` 가 heap과 연결된 OOS 파일의 존재 여부, VFID, page/record 통계를 반환한다. 기존 `SHOW HEAP CAPACITY` 와 `;oos_stats` 출력 스펙은 유지한다. |
| **영향** | QA 도구 공백 - release 빌드의 SQL만으로 특정 table에 OOS 파일이 생겼는지 확인하기 어려웠다. 반대로 기존 진단 결과에 컬럼을 추가하면 QA answer와 외부 스크립트의 결과 스키마가 바뀐다. |

**이슈 수행 방안**: PR #7382의 범위를 독립된 `SHOW HEAP OOS` 진단 SQL 추가로 한정한다. OOS 파일이 없는 heap은 오류 대신 `Has_oos_file = 0`, OOS VFID는 `NULL`, 통계는 0으로 반환한다. `SHOW HEAP CAPACITY` 확장과 공유 OOS 통계 구조의 free-space 구간 지표 추가는 스펙 변경이므로 이 PR에서 제외한다.

---

## AI-Generated Context

> 아래는 AI가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: parser의 SHOW 문법과 metadata, SHOW scan dispatch, heap/OOS scan 구현, OOS SQL 단위 테스트가 바뀐다. 일반 DML, OOS record format, MVCC, vacuum, recovery, replication에는 영향이 없다.

## Description

heap header에는 해당 heap과 연결된 OOS VFID가 저장되지만, 기존 SQL 진단 명령은 이를 OOS 파일 통계와 묶어 보여주지 않는다. `;oos_stats <class>` 는 같은 정보를 일부 제공하지만 csql 세션 명령이라 SQL 결과셋을 사용하는 QA와 자동화에서 재사용하기 어렵다.

초기 구현 뒤 `SHOW HEAP CAPACITY` 에 OOS 요약 컬럼을 추가하고 OOS 통계 수집 구조에 page free-space 구간 지표를 넣는 변경도 검토했다. 두 변경은 기존 결과 스키마 또는 공유 통계 의미를 바꾸므로, 논의 결과 독립된 `SHOW HEAP OOS` 만 유지하기로 결정했다.

## Specification Changes

### 추가 SQL

```sql
SHOW HEAP OOS OF <class>;
SHOW ALL HEAP OOS OF <class>;
```

`SHOW ALL` 은 기존 `SHOW ALL HEAP HEADER/CAPACITY` 와 같은 partition expansion 규칙을 사용한다. 두 명령은 기존 heap 진단과 마찬가지로 DBA 전용이다.

### 출력 컬럼

| 컬럼 | 타입 | 의미 |
|------|------|------|
| `Table_name` | `varchar(255)` | class 이름 |
| `Class_oid` | `varchar(255)` | class OID |
| `Heap_volume_id` | `int` | heap volume ID |
| `Heap_file_id` | `int` | heap file ID |
| `Heap_header_page_id` | `int` | heap header page ID |
| `Has_oos_file` | `int` | 연결된 OOS 파일 존재 여부 |
| `Oos_volume_id` | `int` | OOS volume ID, 파일이 없으면 `NULL` |
| `Oos_file_id` | `int` | OOS file ID, 파일이 없으면 `NULL` |
| `Oos_num_user_pages` | `int` | OOS user page 수 |
| `Oos_page_size` | `int` | `DB_PAGESIZE` |
| `Oos_num_recs` | `int` | 수집된 OOS chunk record 수 |
| `Oos_recs_sumlen` | `bigint` | 수집된 OOS chunk record 길이 합 |
| `Oos_physical_bytes` | `bigint` | `Oos_num_user_pages * Oos_page_size` |
| `Oos_unused_bytes` | `bigint` | `max(Oos_physical_bytes - Oos_recs_sumlen, 0)` |

`Oos_recs_sumlen` 은 SQL 컬럼의 논리 payload 길이가 아니라 OOS slot에 저장된 chunk record 길이의 합이다. 통계 scan은 busy page를 건너뛸 수 있으므로 결과는 DBA 진단용 현재 통계로 취급한다.

### 범위에서 제외한 스펙 변경

| 제외 항목 | 최종 결정 |
|-----------|-----------|
| `SHOW HEAP CAPACITY` 에 OOS 요약 컬럼 추가 | 기존 결과 스키마를 유지한다. |
| OOS 통계 구조에 free-space byte 및 0-25%/25-50%/50-75%/75-100% page 수 추가 | 공유 통계와 `;oos_stats` 의미를 유지한다. |

## Implementation

```text
SHOW HEAP OOS OF <class>
  parser: csql_grammar.y / csql_lexer.l / keyword.c
    -> metadata_of_heap_oos()
    -> heap_header_capacity_start_scan()
    -> heap_oos_next_scan()
         -> heap_oos_find_vfid(..., false)
              OOS 파일을 생성하지 않고 heap header에서 VFID 조회
         -> oos_get_stats_by_vfid()
    -> heap_header_capacity_end_scan()
```

`heap_oos_next_scan()` 은 `src/storage/heap_oos.cpp` 에 둔다. heap header layout을 직접 다루는 `heap_oos_find_vfid()` 는 `src/storage/heap_file.c` 에 유지하고, 두 모듈이 공유하는 SHOW scan context만 `src/storage/heap_show_scan_context.hpp` 로 분리한다.

단위 테스트 `unit_tests/oos/sql/test_oos_sql_show.cpp` 는 OOS 파일이 없는 table, OOS 파일이 있는 table, non-partitioned class의 `SHOW ALL`, partitioned class의 row expansion을 확인한다.

## Acceptance Criteria

- [x] `SHOW HEAP OOS OF <class>` 가 OOS 파일이 없는 heap을 zero/`NULL` row로 반환한다.
- [x] OOS-backed attribute가 있는 heap에서 OOS VFID와 양수 page/record 통계를 반환한다.
- [x] `SHOW ALL HEAP OOS OF <class>` 가 일반 table과 partition table에서 기존 heap 진단의 row expansion 규칙을 따른다.
- [x] 기존 `SHOW HEAP CAPACITY` 결과 컬럼과 공유 OOS 통계 구조를 변경하지 않는다.

## Definition of done

- [x] CUBRID debug GCC 빌드 통과
- [x] `test_oos_sql_show` 통과
- [ ] PR #7382 CI 통과
- [x] PR 설명과 상세 문서에 최종 범위 반영

## Remarks

- PR: https://github.com/CUBRID/cubrid/pull/7382
- 상세 문서: https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26972/CBRD-26972-show-heap-oos.md
