# [OOS] [M2] [Regression] vacuum 이 HAS_OOS 레코드의 OOS 파일을 찾지 못해 abort — cub_server 크래시

## Issue Triage

**이슈 수행 목적**: vacuum 이 OOS 정리 중 abort 하지 않도록, "HAS_OOS 플래그는 켜져 있는데 그 heap 에 OOS 파일이 없다"는 불변식 위반의 근본 원인을 찾아 제거한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: 매뉴얼 QA 시나리오 `_02_show_archive_log_header` (해시 파티션 4개 테이블에 1MB VARCHAR 999건 INSERT 후 backupdb) 수행 구간에서, INSERT 로그를 처리하던 vacuum worker 가 `vacuum_oos_find_vfid_for_heap_record` (`vacuum_oos.cpp:386`) 에서 abort → cub_server core.
- **TO-BE (목표 상태 / 기대 동작)**: HAS_OOS 가 켜진 레코드의 heap 헤더에는 항상 유효한 OOS VFID 가 있어 vacuum 이 chunk 정리를 정상 수행한다.
- **영향**: QA 실패 — 매뉴얼 빌드 `11.5.0.2437-11aa26f` 에서 2개 호스트 재현 크래시로, develop 병합 게이트의 P0 블로커다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 결정. 코드 주석이 지목하는 세 후보 원인(Description 참고) 중 어느 것인지부터 가리고, 시나리오 특성상 파티션 heap(4개, heap 마다 별도 OOS 파일) 간 hfid/VFID 매칭이 어긋났는지를 우선 확인한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/QA 결과를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 조사 대상은 서버 vacuum 경로 (`src/query/vacuum_oos.cpp`, `src/query/vacuum.c`)와 OOS 플래그/VFID 를 기록하는 heap 쓰기 경로 (`src/storage/heap_file.c`). 클라이언트/프로토콜 영향 없음.

---

## Description

abort 자체는 의도된 계측이다. OOS (Out-of-row Overflow Storage — 큰 가변 컬럼 값을 heap 레코드 밖 별도 파일에 저장하는 방식) 환경에서 `vacuum_oos_find_vfid_for_heap_record` 는, 레코드에 OOS inline stub (외부화된 값을 가리키는 16 바이트 참조: head OOS OID 8B + 전체 길이 8B) 이 있는데 heap 헤더에서 OOS VFID (볼륨-파일 식별자) 를 찾지 못하면 원래는 로그만 남기고 해당 레코드의 OOS 정리를 건너뛴다(작은, 기록되는 누수). 병합 전 한시적으로 이 지점에 `abort()` 를 심어 CI/QA 에서 불변식 위반을 즉시 드러내도록 했고 (`vacuum_oos.cpp:379-386` 의 TODO 주석), 이번 크래시는 그 계측이 실제 위반을 잡아낸 것이다.

위반이 성립하려면 다음 중 하나여야 한다. OOS 파일은 OOS 데이터를 쓸 때 반드시 먼저 생성(`heap_attrinfo_insert_to_oos` 가 `heap_oos_find_vfid` 를 `docreate=true` 로 호출)되고 그 뒤에 플래그가 커밋되므로, "아직 안 만들어진 파일"은 정상 경로에서 있을 수 없다:

1. HAS_OOS 플래그가 잘못 설정된 레코드가 만들어졌다.
2. OOS 파일이 어떤 경로로 drop 됐는데 레코드는 남았다.
3. recovery/복구 순서가 꼬여 heap 헤더의 OOS VFID 기록이 유실됐다.

시나리오가 주는 단서는 파티션이다. `t2` 는 `PARTITION BY HASH ... PARTITIONS 4` 로, 실제 데이터는 4개 파티션 클래스 heap 에 나뉘어 들어가고 OOS 파일도 heap 당 하나씩 따로 만들어진다. 문자열 압축을 꺼서 1MB 값이 그대로 남으므로 모든 행이 OOS 트리거(레코드가 4KB 급 임계 초과)를 넘어 multi-chunk (한 값이 여러 OOS 페이지에 나뉘어 저장) 로 외부화된다. vacuum 은 heap 페이지의 레코드를 정리할 때 그 페이지가 속한 hfid (heap 파일 식별자) 로 VFID 를 조회하는데 (`vacuum_heap_prepare_record` 의 `REC_HOME` 분기, `vacuum.c:2241`), 이 hfid-레코드 매칭이 파티션 환경에서 어긋났는지, 아니면 쓰기 시점에 플래그/VFID 기록 자체가 어긋났는지가 조사의 갈림길이다.

호출 흐름 (`vacuum_oos_find_vfid_for_heap_record` 내부 분기):

```
vacuum worker (vacuum_process_log_block)
 └ vacuum_heap → vacuum_heap_page (n_heap_objects=4, threshold_mvccid=6)
    └ vacuum_heap_prepare_record (REC_HOME)          vacuum.c:2241
       └ vacuum_oos_find_vfid_for_heap_record        vacuum_oos.cpp
          ├ VFID 이미 확보 / 레코드에 OOS 없음 → NO_ERROR
          ├ heap_oos_find_vfid 성공 & VFID 유효 → NO_ERROR
          ├ latch 실패 & 에러 미설정 → ER_LK_PAGE_TIMEOUT (페이지 놓고 재시도)
          ★ └ 조회는 성공했으나 VFID 없음 = 불변식 위반 → abort()   vacuum_oos.cpp:386
```

핵심 분기는 마지막 줄이다: `heap_oos_find_vfid` 는 `docreate=false` 면 heap 에 OOS 파일이 없어도 true 를 반환할 수 있으므로, "조회 성공 + VFID NULL" 조합이 곧 이 불변식 위반이다.

## Test Build

`11.5.0.2437-11aa26f` (RB-11.5.0-Manual, feature/oos-m2), Linux x86_64.

## Repro

매뉴얼 QA 시나리오 `cubrid-testcases-private-ex/shell/_32_features_930/issue_12504_show_log_header/_02_show_archive_log_header`. 핵심만 추리면:

```bash
cubrid createdb --db-volume-size=20M --log-volume-size=20M tmpdb en_US.utf8
echo "enable_string_compression=no" >> $CUBRID/conf/cubrid.conf
cubrid server start tmpdb
csql -u dba tmpdb <<'SQL'
drop table if exists t2;
CREATE TABLE t2 (
  col1 VARCHAR (1000000),
  col2 VARCHAR (50)
)
PARTITION BY HASH (col1) PARTITIONS 4;
insert into t2 (col1, col2) select rpad(rownum, 1000000, ' '), rownum from db_root connect by level < 1000;
select * from t2 order by 1,2 limit 10;
SQL
cubrid backupdb -l 0 tmpdb
# INSERT 로그를 처리하는 vacuum worker 가 이 구간에서 abort (backupdb 가 원인이 아니라 시점이 겹침)
```

## Expected Result

시나리오가 끝까지 수행되고 `show archive log header` 결과가 answer 와 일치한다. vacuum 은 OOS chunk 를 정상 정리한다.

## Actual Result

`cub_server` 가 vacuum worker 스레드에서 abort, core 생성. QA 판정 NOK — 같은 빌드에서 2개 호스트 재현:

- 192.168.2.136: `core.2925069`, `core.2925275` (ERROR_BACKUP `AUTO_11.5.0.2437-11aa26f_20260716_043227`, `_043339`)
- 192.168.2.150: `/home/shell/CUBRID/core.3302392` (ERROR_BACKUP `AUTO_11.5.0.2437-11aa26f_20260716_074358`)

## Additional Information

Core 스택 (host 192.168.2.136, `core.2925275`):

```
#0  raise ()
#1  abort ()
#2  vacuum_oos_find_vfid_for_heap_record (thread_p=..., hfid=..., record=...,
    slotid=..., record_type=..., oos_vfid=..., conditional_latch=true)
    at src/query/vacuum_oos.cpp:386
#3  vacuum_heap_prepare_record at src/query/vacuum.c:2241
#4  vacuum_heap_page (n_heap_objects=4, threshold_mvccid=6, ...) at src/query/vacuum.c:1729
#5  vacuum_heap at src/query/vacuum.c:1562
#6  vacuum_process_log_block at src/query/vacuum.c:3784
#7  cubthread::worker_pool_impl::wrapped_task::execute
```

- qahome: RB-11.5.0-Manual → `11.5.0.2437-11aa26f`, showstat treeId=5258.
- 관련: CBRD-27028 — 같은 TC 라인에서 직전에 수정된 FILE_OOS tracker assert (7/20 Resolved). 크래시 지점이 달라 별개 결함이며, 27028 수정 반영 후에도 본 건이 남는지 차기 빌드에서 확인 필요.
- 관련: CBRD-26668 (vacuum OOS 정리 도입), CBRD-26835 (develop 병합 준비 EPIC, 본 이슈의 parent).
- abort 계측 자체의 존치 여부는 별도 논의 중이다 — vacuum 불능은 critical 이므로 abort 유지가 타당하다는 의견이 있으며, 본 이슈의 범위는 계측이 아니라 계측이 드러낸 불변식 위반이다.
