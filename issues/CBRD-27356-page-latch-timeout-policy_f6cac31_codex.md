# [PGBUF] transaction lock timeout과 page latch 정책의 결합 및 debug 중단을 해결한다

## Issue Triage

**이슈 수행 목적**: transaction lock 대기 설정과 page latch의 획득·대기·실패 계약을 구분하여, 내부 페이지 작업이 호출부에서 예상하지 못한 경합 오류나 서버 중단으로 이어지지 않게 한다.

**이슈 수행 이유**: 현재 소스는 zero-wait 상태에 따라 unconditional page latch 요청을 conditional로 바꾸고, 대기 만료 결과와 ordered fix의 재시도 판단에도 같은 상태를 사용한다. 2026-09-29 개발자 댓글에는 이 동작이 두 debug 빌드의 DROP TABLE commit 처리에서 서버 abort로 이어졌다는 재현 결과가 있다. 현재 소스의 국소 보완만으로 공통 정책 문제가 해소되었는지 확인해야 한다.

**영향**: 확인된 실행 증거는 댓글에 보고된 debug 서버 중단과 작업 실패이다. 내부적으로 경합을 건너뛰려는 호출부와 실패를 불변식 위반으로 취급하는 호출부가 공존하므로 공통 정책 변경 시 양쪽의 회귀 위험이 있다. 현재 기준 소스에서의 재현 여부, release 빌드 영향, 운영 발생 빈도와 데이터 영향은 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

transaction lock은 트랜잭션 사이의 논리 객체 접근을 조정한다. page latch는 페이지 버퍼에 있는 페이지 내용의 동시 접근을 조정한다. fix/unfix는 페이지의 사용을 등록·해제하는 절차이며, BCB(Buffer Control Block)는 버퍼 슬롯의 fix 수와 latch 상태 등을 관리하는 제어 상태이다. 두 잠금의 목적이 다르므로 사용자 transaction lock 설정이 내부 페이지 작업에 미치는 효과와 호출부가 처리해야 하는 실패를 명시해야 한다.

현재 분석 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이 기준에서 `LOG_TDES::wait_msecs`는 lock 대기 값으로 정의되어 있다. 페이지 버퍼는 `pgbuf_find_current_wait_msecs()`를 통해 먼저 현재 스레드의 `wait_msecs_override`를 읽고, override가 없으면 transaction의 `wait_msecs`를 읽는다. transaction descriptor가 없으면 `LK_ZERO_WAIT`를 반환한다. 따라서 현재 결합을 transaction 필드의 직접 조회만으로 설명하면 thread-local 보완을 놓친다. [transaction 필드](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_impl.h#L476-L486), [페이지 버퍼의 조회 순서](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16914-L16948)

| 지점 | 기준 소스에서 확인한 동작 | 정책상의 의미 |
|---|---|---|
| `pgbuf_fix_internal()` | unconditional 요청도 조회 값이 `LK_ZERO_WAIT` 또는 `LK_FORCE_ZERO_WAIT`이면 conditional로 바꾼다. | 호출 인자의 획득 조건만으로 대기 진입을 판단할 수 없다. |
| 경합한 conditional 요청 | 사용자 zero-wait에는 `ER_LK_PAGE_TIMEOUT`을 설정한다. 해당 즉시 거절 분기에서 force-zero는 같은 오류를 설정하지 않는다. | 사용자 no-wait와 내부 경합 탐색의 오류 계약이 다르다. |
| `pgbuf_timed_sleep()` | zero/force-zero이면 0ms, 그 외에는 별도 `pgbuf_latch_timeout_msecs`로 대기한다. | 양수 `lock_timeout`의 수치가 latch 대기 시간을 직접 정하지 않는다. |
| 대기 만료 | inactive transaction은 다시 대기한다. active 양수 정책은 `ER_LK_PAGE_TIMEOUT`, active infinite 정책은 debug assert 후 계속 실행되는 경우 `ER_LK_UNILATERALLY_ABORTED` 경로로 간다. 현재 zero/force-zero 만료 분기도 오류를 설정한다. | 대기 시간뿐 아니라 transaction 상태와 조회 값에 따라 실패 의미가 달라진다. |
| `pgbuf_ordered_fix()` | zero/force-zero이면 unfix/refix에 의한 순서 재조정으로 진행하지 않고 실패를 반환하는 분기가 있다. | 이 결합은 일반 fix의 대기 진입에만 한정되지 않는다. |

근거는 [대기 진입 변환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2228-L2237), [conditional 거절](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6518-L6549), [대기 시간·inactive 재대기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7256-L7329), [만료 오류 분류](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7339-L7413), [ordered fix의 조기 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12369-L12383)이다. 위 분기들은 소스 확인 결과이며, 이번 작성에서 각각 실행한 결과는 아니다.

### 왜 문제인가

2026-09-29 Il Han, Song의 [개발자 댓글](https://jira.cubrid.org/browse/CBRD-27356?focusedCommentId=4776561&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4776561)은 이 결합으로 DROP TABLE의 commit 중 서버가 abort한 사례를 보고한다. 호출부는 unconditional fix를 요청했지만 세션의 zero-wait 때문에 conditional로 바뀌었고, 경합 오류 `-76(ER_LK_PAGE_TIMEOUT)`이 실패를 예상하지 않은 assert에 도달했다는 설명이다. 이는 공개 설정과 내부 정리 경로의 계약 불일치가 debug 검증을 중단시킬 수 있다는 구체적인 착수 근거이다.

기준 소스에도 해당 호출부의 구조가 남아 있다. `vacuum_fix_dropped_entries_page`는 unconditional fix를 사용하고, `vacuum_add_dropped_file()`은 NULL 반환에 assert한다. `log_execute_run_postpone()`도 unconditional `pgbuf_fix_if_not_deallocated()`의 오류에 assert한다. 다만 이 코드와 댓글의 실행 경로가 현재 빌드에서도 같은 스케줄로 연결되는지는 별도 재현이 필요하다. [vacuum의 fix 매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/vacuum.c#L614-L620), [vacuum 실패 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/vacuum.c#L5914-L5929), [postpone 실패 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L8643-L8657)

반대로 일부 호출부는 경합 시 기다리지 않는 동작을 필요로 한다. 현재 `bestspace::shard::L1_fix()`는 thread-local `LK_FORCE_ZERO_WAIT`로 ordered fix를 수행하고 `ER_LK_PAGE_TIMEOUT`을 `CONTENDED`로 처리한다. B-tree 오류 메시지 작성 경로도 이미 B-tree latch를 보유한 상태에서 class name을 읽다가 latch 순환 대기가 생기지 않도록 force-zero를 사용한다. 공통 조회를 제거하거나 두 zero-wait 값을 모두 무시하는 변경은 이 동작까지 바꿀 수 있다. [best-space](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/bestspace.cpp#L672-L702), [B-tree](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L22639-L22659)

따라서 모든 `-76`을 새 결함으로 보거나, unconditional이라는 이름만으로 모든 실패가 금지된다고 판단해서는 안 된다. 현재 헤더에는 latch 거절·만료 오류를 구분하는 `PGBUF_IS_LATCH_REFUSED_ERROR`가 있으며 disk 예약 경로도 이를 정상 반환할 오류로 다룬다. 조사 대상은 각 호출부가 허용하는 실패 집합과 실제로 유입되는 실패의 불일치이다. [오류 분류](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L199-L209), [disk 예약 오류 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L4432-L4445)

### 왜 해결해야 하는가

호출부별 예외만으로 대응하면 같은 transaction 설정이 다른 내부 페이지 작업에서는 예상 밖의 오류로 남을 수 있다. 반대로 경합 거절을 일괄 대기로 바꾸면 busy 페이지를 건너뛰는 탐색이나 latch 순환 회피를 훼손할 수 있다. 개발자가 어느 fix는 대기해야 하고 어느 fix는 실패를 반환해야 하는지 판단할 수 있는 공통 계약과 회귀 근거가 필요하다.

[CBRD-27198](https://jira.cubrid.org/browse/CBRD-27198) / [PR #7630](https://github.com/CUBRID/cubrid/pull/7630)과 관련된 디스크 경로의 국소 대응은 기준 소스에 존재한다. volume header와 sector allocation table의 fix 직전에 `pgbuf_force_latch_wait()`를 사용하고 이후 이전 override를 복원한다. helper는 두 zero-wait 값을 infinite로 바꾸되 기존 양수·infinite 값은 보존한다. 이 두 호출부의 처리가 페이지 버퍼 전체의 정책 분리를 완료한 것은 아니다. [volume header](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L3230-L3241), [sector table](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L3508-L3519), [helper](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5328-L5363)

사용자에게 lock timeout을 기본값으로 돌리게 하는 방법은 댓글의 제한된 대조 실행에서는 중단을 피했지만, 필요한 object lock no-wait 의미를 포기하게 하고 내부 force-zero의 계약도 해결하지 못한다. 실제 운영 긴급도와 release 영향은 아직 판단하지 않는다. 보고된 debug 중단을 현재 코드에서 판별하고, 기존 nonblocking 의도를 보존할 수 있는 범위를 정하는 분석을 시작할 근거는 충분하다.

## Test Build

| 구분 | 확인 범위 |
|---|---|
| 댓글의 debug 빌드 1 | `11.5.0.2623-8787dec`. 보고자는 develop `e1c3db198`에 이 문제와 무관한 조인 커밋 1개를 추가한 빌드라고 설명한다. |
| 댓글의 debug 빌드 2 | CBRD-27486 수정 빌드 `099afcf`. 전체 SHA와 빌드 환경은 댓글에 없다. |
| 이번 소스 분석 | `f6cac312310f39f46711693da157a08f0e725693`을 고정하여 정적 확인하였다. 이 revision으로 재현 실행하지 않았다. |
| 미확인 | OS, compiler, 전체 설정, 클라이언트·autocommit/commit 조건, 원본 재현 스크립트·core, release 빌드 및 다른 출시 버전의 영향은 TBD이다. |

이전 정책 조사에 사용한 `d9ceb53`과 당시 PR HEAD `bd5c43c`는 역사적 분석 기준이다. 댓글의 두 실행 빌드 및 이번 기준 소스와 동일한 빌드로 취급하지 않는다.

## Repro

댓글은 128M DB에서 두 세션이 create/insert/create index/drop을 동시에 수행하고, 세션별·회차별로 다른 테이블명을 사용하여 5회 반복하는 절차를 설명한다. 세션 A만 `set transaction lock timeout 0;`을 수행하고 B는 기본값을 사용한다. 아래는 댓글의 한 회차를 실행 가능한 이름으로 옮긴 SQL이며 이번 작성에서는 실행하지 않았다.

세션 A:

```sql
set transaction lock timeout 0;
create table ta_a_1 (a int, b varchar(300));
insert into ta_a_1 select rownum, repeat('x', 300)
  from db_class a, db_class b, db_class c limit 60000;
create index i_ta_a_1 on ta_a_1 (a);
drop table ta_a_1;
```

세션 B:

```sql
create table ta_b_1 (a int, b varchar(300));
insert into ta_b_1 select rownum, repeat('x', 300)
  from db_class a, db_class b, db_class c limit 60000;
create index i_ta_b_1 on ta_b_1 (a);
drop table ta_b_1;
```

다음 회차에는 테이블명과 인덱스명을 함께 바꾼다. 원본 댓글은 commit 때의 postpone 처리를 abort 지점으로 설명하지만 정확한 commit 실행 방식과 동시 시작 동기화 방법은 제시하지 않는다. 이를 확인한 뒤 현재 revision에서 두 세션 모두 기본값인 대조군 및 insert-only 실행을 함께 재현해야 한다. 위 SQL만으로 원래 실행 환경을 완전히 재구성했다고 주장하지 않는다.

## Expected Result

분석에서 확정한 page latch의 획득·대기·실패 계약과 각 호출부의 오류 처리가 일치해야 한다. 사용자 object lock no-wait 설정이나 내부 force-zero 상태가 정리·commit 경로의 예상 밖 assert로 이어지지 않아야 하며, 의도적으로 busy 페이지를 건너뛰는 호출부의 동작도 보존해야 한다. 허용할 거절·재시도·중단과 장기 대기 정책은 ANALYSIS에서 결정한다.

## Actual Result

다음은 새 실행 결과가 아닌 2026-09-29 댓글의 보고 내용이다.

| 조건 | 보고 결과 |
|---|---|
| A zero-wait, B 기본값, `8787dec` | 10/10 회차에서 서버 abort |
| 같은 조건, `099afcf` | 8/14 회차에서 서버 abort |
| 두 세션 모두 기본값 | 보고된 최소 5/5 회차에서 이상 없음 |
| insert만 반복 | abort 없이 세션 A만 `-76`으로 실패 |

절차 설명의 5회 반복과 집계된 10/10·8/14의 실행 단위·반복 묶음 관계는 댓글만으로 알 수 없다. 이 숫자를 일반 장애 확률로 해석하지 않는다. 보고자는 `vacuum_add_dropped_file()`과 `log_execute_run_postpone()`의 assert를 abort 지점으로 제시했으며, release 재현은 확인하지 않았다고 명시했다. heap, catalog, B-tree, best-space 등의 다른 `-76`은 당시 `lock_timeout 0`의 현재 의미에 따른 실패로 구분했다. [원본 댓글](https://jira.cubrid.org/browse/CBRD-27356?focusedCommentId=4776561&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4776561)

## Specification Changes

요구 결과는 transaction lock 대기 설정과 내부 page latch 정책의 경계를 설명하고, 보고된 중단 및 호출부의 실패 계약 불일치를 해소하는 것이다. blocking/conditional 획득, ordered 재시도, interrupt, 만료 오류와 transaction abort의 의미를 구분한다. 공개 object lock의 zero·양수·infinite 대기 의미는 호환성 검증 대상으로 둔다. 디스크 형식이나 SQL 문법 변경을 요구하는 이슈는 아니다.

대기 시간의 숫자를 먼저 정하지 않는다. 현재 숨은 `page_latch_timeout_in_msecs`의 기본값은 300,000ms이며, 같은 값을 BCB의 direct victim 할당 대기에도 사용한다. 이 버퍼 슬롯 확보 대기는 이미 존재하는 direct victim 전달 경로이며 page latch 획득 자체와 다른 작업이다. 경고 진단, latch 장기 정지, BCB 확보 정지, 현재 양수 정책의 오류 반환을 구분하여 요구를 정해야 한다. 현재 값의 유지·분리·변경, recoverable cutoff의 유지·제거, 공개 parameter 필요성은 모두 ANALYSIS에서 결정한다. [기본 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L5414-L5425), [direct victim 대기 시간](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8211-L8218)

`deadlock_detection_interval_in_secs`의 기본 1초는 lock deadlock 검사 간격이다. 이를 page latch 획득 제한 시간과 동일하게 취급하지 않는다. 어느 값이 적절한지는 해당 값이 제어할 결과와 대기 분포·장애 진단 요구를 확인한 뒤 판단한다. [기본값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L1368-L1377), [검사 실행 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/lock_manager.c#L6090-L6119)

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

분석에서는 `pgbuf_fix_internal()`, `pgbuf_timed_sleep()`, `pgbuf_ordered_fix()`와 thread-local override를 설정·복원하는 호출부를 함께 조사한다. 명시적인 latch 인자나 별도 인터페이스로 의도를 표현하는 방법은 후보이며, wait/try/ordered-retry API의 신설이나 특정 watchdog 분리는 아직 결정된 구현이 아니다. 기존 인터페이스를 유지하며 호출부 오류 처리를 보완하는 범위도 같은 계약과 재현 근거로 평가한다.

주요 확인 대상은 페이지 버퍼, transaction/lock 대기 상태, best-space·B-tree의 nonblocking 호출, 디스크 metadata fix, vacuum·postpone 처리이다. volume header를 보유한 채 sector table을 기다리는 경우의 latch 순서와 연쇄 대기는 별도로 확인한다. 대기 시간이나 오류 코드가 바뀌면 호환 범위와 전환 방안을 명시한다.

## Acceptance Criteria

- [ ] 댓글의 두 debug 빌드와 현재 기준 revision을 구분하고, 재현 환경·commit 방식·반복 단위를 보완하여 현재 debug/release 영향과 미확인 출시 버전을 기록한다.
- [ ] 사용자 zero·양수·infinite 값과 내부 force-zero, conditional/unconditional 요청의 조합별 대기열 진입, 반환값, 오류 상태, ordered 재시도 및 override 복원을 설명한다.
- [ ] DROP TABLE commit/postpone 경로가 경합 거절을 받을 수 있는 조건과 실패 처리의 적정성을 판정하고, 현재 재현되는 중단에 대한 처리 또는 이미 해소되었다는 근거를 제시한다.
- [ ] best-space의 busy 페이지 건너뛰기와 B-tree의 latch 순환 회피 의도, CBRD-27198의 국소 대응 및 공개 object lock 동작을 보존할 검증 근거를 제시한다.
- [ ] latch 획득 대기, 장기 정지 진단 및 BCB direct victim 확보 대기의 역할과 호환성 요구를 구분하고, timeout/API/오류 정책의 유지 또는 변경 결정을 근거와 함께 남긴다.
- [ ] 변경이 필요한 경우 선택한 계약을 통제된 경합·만료·interrupt 조건에서 검증하며 latch 보유 상태, waiter 제거, unfix 및 부분 작업 정리가 정해진 결과와 일치한다.

## Definition of done

분석 결과에는 확인된 결함, 의도된 동작, 재현되지 않은 가설과 남은 검증을 구분하여 기록한다. 필요한 구현과 회귀 검증을 완료하거나, 현재 코드로 이미 해소된 부분과 후속 작업의 처리 결정을 근거로 남긴다. 구현을 변경하는 경우 debug/release 및 관련 회귀 검증 결과를 기록하고, 공개 parameter나 오류 의미를 바꾸면 해당 사용자 문서와 release 설명을 갱신한다. 전체 regression suite의 실행 범위는 선택한 변경과 영향에 따라 정한다.

## Additional Information

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 과제로서 transaction lock 정책과 page latch 계약의 공통 경계를 다룬다. CBRD-27198의 디스크 예약 증상과 국소 대응은 관련 근거이며 별도 이슈의 완료를 다시 요구하지 않는다. CBRD-27486은 9월 debug 사례가 발견된 검증 배경이다. 이 자료만으로 그 수정이 원인이라고 판단하지 않는다.

[과거 lock/latch 비교 조사](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27198/research/lock-vs-latch-timeout-survey_d9ceb53_codex.md)에서 제안한 timeout 분리와 단계별 전환안은 설계 제안으로 취급한다. [과거 unconditional 호출부 조사](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-surveys/unconditional-page-latch-assumptions/d9ceb53.md)도 CUBRID `d9ceb53`의 정적 분석이며 현재 호출부 전체의 실행 도달성 증명은 아니다. 기존 300초의 일괄 유지, 특정 시점의 cutoff 제거, 1초 정책 채택·배제를 이 이슈의 선결된 구현 조건으로 두지 않는다. 대기 histogram, 보유·대기 latch 관계, 경합 거절·재시도 수, volume-header 보유 시간과 오류별 발생 수는 ANALYSIS에서 필요한 측정을 정할 때 사용할 수 있는 후보이다.

## Triage Request

transaction lock 설정과 page latch 정책의 결합 및 보고된 debug 중단을 확인할 과제로 승인하고, 요청 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 분석에서는 현재 소스의 실행 도달성, debug/release 영향, 기존 호출부의 경합 처리 의도와 오류 호환성을 먼저 판별한다. 그 결과를 바탕으로 공통 정책 분리 또는 필요한 호출부 보완의 범위와 검증을 결정한다. 우선순위와 실제 담당 배정은 triage에서 결정한다.
