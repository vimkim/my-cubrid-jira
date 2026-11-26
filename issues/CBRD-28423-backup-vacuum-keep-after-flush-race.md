# [BACKUP][VACUUM] logpb_backup에서 로그 flush 이후 vacuum_min_log_pageid_to_keep를 읽어 필요한 아카이브가 누락될 수 있다

**한 줄 요약**: [CUBRID/cubrid PR #8721](https://github.com/CUBRID/cubrid/pull/8721)(CBRD-28142) 리뷰([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28142/pr8721-review.md)) 과정에서 vacuum 활성화 경로(`SERVER_MODE`)의 `logpb_backup ()` 가 로그 flush 이후에 `vacuum_min_log_pageid_to_keep ()` 를 읽어 복구된 vacuum data가 필요로 하는 로그 아카이브를 빠뜨릴 수 있는 기존 경합 가능성을 발견했으며, 이 경합의 실재 여부를 검증하고 백업이 복원 DB의 vacuum에 필요한 아카이브를 빠뜨리지 않도록 보장하는 이슈다.

## Issue Triage

**이슈 수행 목적**: vacuum이 활성화된 온라인 백업(`logpb_backup ()`)에서 로그 아카이브 선택 기준(`keep_from_log_pageid`)과 백업에 포함되는 로그 이미지 시점 사이의 불일치를 검증하고, 복원된 DB의 vacuum이 백업에 누락된 아카이브를 참조해 치명적 오류로 중단되지 않도록 한다.

**이슈 수행 이유**: PR #8721 코드 리뷰 중 변경되지 않은 vacuum 활성화(`else`) 분기를 점검하면서 확인했다(PR #8721 자체의 변경과는 무관한 기존 코드). `logpb_backup ()` 은 `LOG_CS` 진입 후 `logpb_flush_pages_direct ()` 와 `logpb_flush_header ()` 로 디스크 로그를 특정 시점 `F` 까지 고정한 뒤 `vacuum_min_log_pageid_to_keep ()` 를 읽는다. 그러나 vacuum 마스터가 `RVVAC_DATA_FINISHED_BLOCKS` 를 prior list로 기록하고 메모리상 `keep_from_log_pageid` 를 전진시키는 동작은 `LOG_CS` 를 잡지 않으므로 flush와 읽기 사이에 끼어들 수 있다. 현재까지 재현하지 않은 코드 분석(source-level) 가설이며, 실제 재현 프로브로 발생 가능성과 관련 아카이브 삭제 경로 위험을 함께 점검할 필요가 있다.

**영향**: 만약 해당 타이밍(수 밀리초 수준으로 추정되는 좁은 창)에서 백업이 수행되면, 백업에 포함된 활성 로그(시점 `F`)에는 블록 완료 로그(`RVVAC_DATA_FINISHED_BLOCKS`)가 빠진 채로 복원되는 반면 백업 아카이브 목록은 이미 전진한 `keep_from_log_pageid`(아카이브 `A+1`) 기준으로 선택되어 아카이브 `A` 가 누락될 수 있다. 이 경우 복원된 DB에서 vacuum이 동작할 때 아카이브 `A` 의 로그 페이지를 읽으려다 `ER_LOG_NOTIN_ARCHIVE` (`Internal error: unable to find log page N in log archives`) 치명적 오류(FATAL)로 종료될 위험이 있다. 재현 전 단계이므로 실제 발생 빈도와 운영 환경에서의 노출 정도는 아직 확인되지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` PR #8721 head `5d6b8cc8fb9a547eba365f1ce217b5b4858b1dd6` (`develop` merge-base `af6f1df42bb044376159ab06784526e57cb56647` 기준 vacuum 활성화 경로와 동일).

### 1. 코드상 확인된 경합 시나리오 (미재현)

`src/transaction/log_page_buffer.c` 의 `logpb_backup ()` (`SERVER_MODE`, vacuum 활성화 분기) 실행 순서와 vacuum 마스터의 블록 완료 갱신은 다음과 같이 맞물린다.

1. **백업 스레드(T1)**: `src/transaction/log_page_buffer.c:8756` 에서 `LOG_CS_ENTER (thread_p)` 를 획득하고, `:8759` 에서 `logpb_flush_pages_direct (thread_p)` 를 호출한다. `logpb_flush_pages_direct ()` (`:4044-4060`)는 `logpb_prior_lsa_append_all_list ()` (`:3180-3207`)로 그 시점까지의 prior list를 로그 페이지 버퍼에 반영한 뒤(`prior_lsa_mutex` 는 `:3192` 에서 해제), `logpb_flush_all_append_pages ()` 로 활성 로그를 시점 `F` 까지 디스크에 flush한다. 이어 `:8760` 에서 `logpb_flush_header (thread_p)` (`:1741`)가 로그 헤더 페이지를 디스크에 기록한다.
2. **vacuum 마스터(T2)**: vacuum 마스터(`vacuum_master_task::execute` `src/query/vacuum.c:3339, 3372` → `vacuum_job_cursor::force_data_update` `:8814` → `vacuum_data::update` `:8562` → `vacuum_data_mark_finished` `:4991`)는 `LOG_CS` 를 잡지 않는다. T1이 `:8759` 의 prior list drain을 마친 뒤 `:8814` 에 도달하기 전(주로 `:8760` 헤더 쓰기 중)에 T2가 아카이브 `A` 의 마지막 블록 완료를 처리하면 다음 순서로 실행된다.
   - `src/query/vacuum.c:5144` 에서 `log_append_redo_data2 (thread_p, RVVAC_DATA_FINISHED_BLOCKS, ...)` 를 호출해 `log_append_redo_crumbs` (`src/transaction/log_manager.c:2547, 2629`) → `prior_lsa_next_record` (`src/transaction/log_append.cpp:1580-1584, 1625-1630`) 경로를 탄다. 이 경로는 `prior_lsa_mutex` 만 잡고 레코드를 prior list에 넣으며, 해당 레코드의 LSA는 `F` 이후이고 아직 디스크에 flush되지 않는다.
   - 직후 `src/query/vacuum.c:5187` 에서 `vacuum_update_keep_from_log_pageid (thread_p)` (`:6213-6231`)를 호출해 메모리상 `vacuum_Data.keep_from_log_pageid` 를 아카이브 `A+1` 쪽으로 전진시킨다.
3. **백업 스레드(T1)**: `src/transaction/log_page_buffer.c:8814` 에서 `vacuum_min_log_pageid_to_keep (thread_p)` (`src/query/vacuum.c:6153-6169`)를 호출해 이미 전진한 `vacuum_Data.keep_from_log_pageid` 를 읽는다. `log_Gl.hdr.last_arv_num_for_syscrashes` 가 `A+1` 이상이면 `first_arv_needed` 도 `A+1` 로 결정되어(`:8826-8833`) 아카이브 `A` 가 백업 대상에서 빠진다.
4. **백업 및 복원 결과**: T1은 `:8881` 에서 `log_Name_active` 를 복사하지만, `LOG_CS` 안의 prior list는 다시 drain되거나 flush되지 않으므로 백업된 활성 로그에는 `F` 이후에 추가된 `RVVAC_DATA_FINISHED_BLOCKS` 레코드가 없다. (단, 백업 중 데이터 파일 복사 시점에 해당 dirty `VACUUM_DATA_PAGE` 가 디스크에 반영되었는지 여부는 별도 확인 대상이다.) 만약 복원 후 redo가 `F` 까지만 재실행되어 복원된 vacuum data에 아카이브 `A` 의 블록이 남아 있으면, 이후 vacuum이 아카이브 `A` 를 읽으려다 `log_page_buffer.c:5810-5814` 에서 `ER_LOG_NOTIN_ARCHIVE` 로 치명적 오류를 일으킬 수 있다.

### 2. 소스에서 함께 확인된 관련 위험 (아카이브 삭제 경로와 WAL flush 순서)

리뷰 과정에서 동일한 구조의 위험이 일반 아카이브 삭제 경로에도 존재하는 점이 소스 코드로 확인되었다(역시 미재현).

- `vacuum_data_mark_finished ()` (`src/query/vacuum.c:5144, 5187`)와 `vacuum_data_empty_page ()` (`src/query/vacuum.c:5224, 5255-5296`)는 vacuum data 변경 WAL 레코드를 디스크에 flush하지 않은 채 메모리상 `vacuum_Data.keep_from_log_pageid` 를 전진시킨다.
- `logpb_remove_archive_logs_exceed_limit ()` (`src/transaction/log_page_buffer.c:6302, 6370-6378, 6477-6486, 6511`)와 `logpb_remove_archive_logs ()` (`src/transaction/log_page_buffer.c:6613-6619, 6697-6700`, `SERVER_MODE`)는 메모리상 `keep_from_log_pageid` 를 기준으로 아카이브를 삭제하면서 `logpb_flush_header ()` (헤더 페이지 단독 기록)만 호출하고 해당 vacuum data WAL 레코드의 flush를 보장하지 않는다.
- 그 결과 WAL flush 이전에 비정상 종료가 발생하면, 복구 시 더 이전 상태의 vacuum data가 되살아나 이미 삭제된 아카이브를 참조할 여지가 있다.

### 3. ANALYSIS 확인 사항 및 후보 방향

- **후보 방향 (분석 대상, 미확정)**: `logpb_remove_archive_logs_exceed_limit ()` 가 `LOG_CS_ENTER` 이전에 `vacuum_min_log_pageid_to_keep ()` 를 읽는 방식(`src/transaction/log_page_buffer.c:6301-6304`)과 마찬가지로, `logpb_backup ()` 에서도 `vacuum_min_log_pageid_to_keep ()` 를 `logpb_flush_pages_direct ()` 호출 이전에 읽는 방향을 검토할 수 있다(`keep_from_log_pageid` 는 단조 증가).
- **ANALYSIS 질문 1 (데이터 페이지 선반영 여부)**: 백업의 데이터 볼륨 복사(`log_page_buffer.c:8749` 이전)가 `LOG_CS` 진입 전에 끝나므로 dirty `VACUUM_DATA_PAGE` 가 선반영될 가능성은 낮아 보이지만, checkpoint 차단 중 백업과 flush 사이의 `pgbuf` flush 및 `VACUUM_DATA_PAGE` 의 page LSN과 `F` 관계에 따라 실제로 `RVVAC_DATA_FINISHED_BLOCKS` 가 누락된 상태로 복원되는지 확인이 필요하다.
- **ANALYSIS 질문 2 (아카이브 삭제 경로와 범위 분리 여부)**: 위 2절의 아카이브 삭제 경로 위험(WAL 미flush 상태에서 메모리상 `keep` 으로 아카이브 삭제)을 이번 이슈에서 함께 다룰지(예: flushed LSA 기반 `keep` 제한 또는 WAL flush), 별도 이슈로 분리할지 결정이 필요하다.

## Test Build

- 재현 테스트는 아직 수행하지 않았다(코드 읽기를 통한 가설 단계).
- 기준 소스 리비전: `5d6b8cc8fb9a547eba365f1ce217b5b4858b1dd6` (`src/transaction/log_page_buffer.c`, `src/query/vacuum.c`, `src/transaction/log_manager.c`, `src/transaction/log_append.cpp`).

## Expected Result

- 온라인 백업(`logpb_backup ()`)이 아카이브 선택 시점에 기준으로 삼는 `vacuum_min_log_pageid_to_keep ()` 의 상태가 백업에 포함된 로그(`F` 까지의 활성 로그 및 아카이브) 또는 복원 후 vacuum data 상태와 모순되지 않으며, 복원된 DB에서 vacuum이 정상 동작한다.

## Actual Result

- 소스 코드상 `logpb_backup ()` 이 `logpb_flush_pages_direct ()` 이후(`log_page_buffer.c:8814`)에 `vacuum_min_log_pageid_to_keep ()` 를 읽고 있어, 사이에 vacuum 마스터가 `RVVAC_DATA_FINISHED_BLOCKS` 를 prior list에 넣고 `keep_from_log_pageid` 를 아카이브 경계 너머로 올릴 경우 필요한 아카이브가 백업에서 빠질 수 있는 구조다(런타임 미검증).

## Proposed Verification

아래 절차는 미실행 상태이며, 본 이슈의 첫 검증(재현 확인) 방법으로 제안한다.

1. Debug 빌드(`CMAKE_BUILD_TYPE=Debug`) 서버에서 로그 아카이브가 여러 개(`000..A+1`) 쌓이고 `last_arv_num_for_syscrashes > A` 인 상태를 만든다.
2. 온라인 백업(`cubrid backupdb -C`) 스레드에서 `src/transaction/log_page_buffer.c:8760`(`logpb_flush_pages_direct ()` 직후, `LOG_CS` 보유 상태)에 `gdb` 중단점을 건다.
3. 백업 스레드가 멈춘 상태에서 vacuum 마스터가 아카이브 `A` 에 걸친 마지막 블록을 완료해 `RVVAC_DATA_FINISHED_BLOCKS` 를 기록(prior list 유지)하고 `keep_from_log_pageid` 를 아카이브 `A+1` 로 전진시키도록 진행한 뒤 백업 스레드를 재개한다.
4. 생성된 백업을 새 위치에 복원(`cubrid restoredb`)하고 vacuum 활성화 상태로 서버를 기동했을 때 아카이브 `A` 누락으로 `ER_LOG_NOTIN_ARCHIVE` FATAL이 발생하는지 확인한다.

## Additional Information

- **출처**: [CUBRID/cubrid PR #8721](https://github.com/CUBRID/cubrid/pull/8721) 리뷰([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28142/pr8721-review.md))의 Pre-existing 항목(PE-1, PE-2).
- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-26, 인덱스 8,403건 완전 동기화): 중복 이슈 없음.
- **관련 이슈**:
  - [CBRD-28142](https://jira.cubrid.org/browse/CBRD-28142) (Develop): `vacuum_disable=yes` 경로의 백업 아카이브 누락을 다루는 원본 이슈. 본 초안은 `vacuum_disable=no` 활성화 경로의 경합을 다룬다.
  - [CBRD-27185](https://jira.cubrid.org/browse/CBRD-27185) (Resolved): 같은 `logpb_backup ()` 에서 아카이브가 빠지는 문제이나 온라인 인덱스 빌드 시스템 트랜잭션 경계 누락이 원인이었다.
  - [CBRD-28392](https://jira.cubrid.org/browse/CBRD-28392) (Develop): `logpb_backup ()` 을 단계별 함수로 리팩터링하는 진행 중 이슈(동작 비변경).

