# [Recovery] commit postpone 실행 중 서버가 죽으면 debug 빌드가 재시작 복구 analysis에서 assert로 멈춘다

**한 줄 요약**: OOS 작업(CBRD-27781) 중 SIGKILL 뒤 DB를 열지 못하는 현상을 추적한 결과, 2022년 CBRD-24378 변경 이후 복구 analysis가 commit-with-postpone 레코드의 위치를 32바이트 뒤로 기록하는 develop 회귀로 확인되어, 그 위치를 바로잡는 이슈다.

## Issue Triage

**이슈 수행 목적**: commit 뒤 postpone을 실행하던 트랜잭션이 서버 중단으로 끊겨도 재시작 복구가 그 트랜잭션의 시작 위치를 정확히 기록하고, debug 빌드에서도 DB를 다시 열 수 있게 한다.

**이슈 수행 이유**: 복구 analysis의 `log_rv_analysis_commit_with_postpone`은 `LOG_COMMIT_WITH_POSTPONE` 레코드의 헤더를 건너뛴 뒤의 위치를 `tdes->tail_lsa`와 `tdes->rcv.tran_start_postpone_lsa`에 넣는다. 런타임은 같은 값에 레코드 시작 위치를 넣는다(`log_append.cpp` `prior_lsa_next_record_internal`). 두 값이 헤더 크기만큼 어긋나서, postpone 실행 sysop의 `lastparent_lsa`가 commit 레코드 시작을 가리키는 경우 `log_rv_analysis_sysop_end`의 assert(`log_recovery.c:1750`)가 실패한다.

**영향**: debug 빌드로 테스트하는 개발자와 QA는 이 형태의 crash 뒤 같은 DB를 열 수 없다. CBRD-27781 작업에서 SIGKILL 시점 5~30초 6회 중 6회 재현했다. release 빌드는 assert가 없어 analysis가 계속 진행하지만, 어긋난 `tail_lsa`가 복구의 뒤 단계에 주는 영향은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

트랜잭션이 commit하면서 postpone 작업(예: 파일 삭제 `RVFL_DESTROY`)을 남기면, 로그에 `LOG_COMMIT_WITH_POSTPONE`이 먼저 기록되고 그 뒤에 postpone이 하나씩 실행된다. postpone 실행 중 서버가 죽으면, 재시작 복구의 analysis 단계가 로그를 읽어 이 트랜잭션을 "commit 뒤 postpone 실행 중" 상태로 되살린다. 이때 트랜잭션의 postpone 시작 위치(`tran_start_postpone_lsa`)를 기록해 두고, 이후 만나는 sysop 종료 레코드가 그 위치보다 뒤에서 시작했는지 확인한다.

문제는 analysis가 기록하는 시작 위치가 런타임이 기록하는 위치와 다르다는 점이다.

| 시점 | 기록하는 값 | 근거 |
|---|---|---|
| 런타임 | `LOG_COMMIT_WITH_POSTPONE` 레코드 시작 LSA | `src/transaction/log_append.cpp` `prior_lsa_next_record_internal`: `tdes->rcv.tran_start_postpone_lsa = start_lsa` |
| 복구 analysis | 레코드 헤더(`LOG_RECORD_HEADER`)를 건너뛴 뒤의 LSA | `src/transaction/log_recovery.c` `log_rv_analysis_commit_with_postpone`: `LOG_READ_ADD_ALIGN` 뒤에 `LSA_COPY (&tdes->tail_lsa, log_lsa)`와 `tdes->rcv.tran_start_postpone_lsa = tdes->tail_lsa` |

commit 직후 첫 postpone이 논리 postpone이고, 그 실행 sysop 안에서 다시 postpone이 생기면(`RVFL_DESTROY` 실행 중 `RVDK_UNRESERVE_SECTORS`), 바깥 sysop 종료 레코드의 `lastparent_lsa`는 commit 레코드의 시작 LSA다. analysis가 기록한 값은 그보다 헤더 크기만큼 크므로 다음 assert가 실패한다.

```
log_recovery.c:1750: log_rv_analysis_sysop_end: Assertion
`LSA_LE (&tdes->rcv.tran_start_postpone_lsa, &sysop_end->lastparent_lsa)' failed.
```

### 회귀 시점

`29624f2b7`(CBRD-24378, PR #3664, 2022-08, "Fix the restoredb not to go beyond the given time (-d)")이 media recovery의 `stop_at` 판정을 넣으면서, `tail_lsa` 복사를 레코드 본문을 읽은 뒤로 옮겼다. 그 전에는 헤더를 건너뛰기 전에 복사했다. 같은 커밋이 `record_header_lsa`에 레코드 시작 위치를 따로 저장하므로 원래 값은 함수 안에 남아 있다. 이 커밋은 v11.3 이후 태그에 포함된다. `log_rv_analysis_commit_with_postpone_obsolete`는 이 순서 변경을 받지 않았다.

develop `261eb38fa`(2026-11-09)에도 같은 코드가 있다(소스 판독).

### 관측 (CBRD-27781 작업 중)

- 빌드: debug_gcc. 엔진은 `feature/oos-merge` 기반 CBRD-27781 branch(`6a8d16da7`)와 그 위 CBRD-27925 branch(`076c3e4c6`). develop 빌드에서는 실행하지 않았다.
- 절차: OOS 단위 테스트 DB를 만든 뒤 `test_oos_identity_stamp`를 5~30초 뒤 SIGKILL하고, 같은 DB를 여는 `test_oos_growth_sweep`를 실행했다. 다음 프로세스가 restart analysis에서 위 assert로 abort했다. 6회 중 6회(`6a8d16da7`), 5회 중 5회(`076c3e4c6`).
- gdb로 본 trid 11의 레코드:

| LSA | 레코드 |
| --- | --- |
| 175\|5200 | `LOG_COMMIT_WITH_POSTPONE` |
| 175\|5336 | `LOG_SYSOP_END` (commit) |
| 175\|5584 | `LOG_POSTPONE` `RVDK_UNRESERVE_SECTORS` |
| 175\|5640 | `LOG_SYSOP_START_POSTPONE` |
| 175\|5752 | `LOG_RUN_POSTPONE` |
| 175\|5824 | `LOG_SYSOP_END` `LOGICAL_RUN_POSTPONE`, lastparent 175\|5200, run_postpone 174\|13320 (`RVFL_DESTROY`) |

analysis 시점 값은 `tran_start_postpone_lsa` = 175\|5232, `lastparent_lsa` = 175\|5200이었다. 차이 32바이트는 `LOG_RECORD_HEADER` 크기와 같다.

## Expected Result

analysis가 기록한 `tran_start_postpone_lsa`와 `tail_lsa`가 런타임 값과 같고, 위 형태의 crash 뒤 debug 빌드에서도 재시작 복구가 끝난다.

## ANALYSIS 확인 사항

- develop 빌드에서 OOS 없이 재현하는 절차. 예를 들어 파일을 지우는 DROP TABLE을 commit하고 postpone 실행 중 서버를 죽이는 방법을 확인한다.
- 어긋난 `tail_lsa`가 release 빌드의 복구 뒤 단계(postpone 마무리, 그 뒤 추가되는 로그 레코드의 `prev_tranlsa`)에 영향을 주는지 확인한다.
- `tail_lsa`와 `tran_start_postpone_lsa`를 `record_header_lsa`로 되돌리는 것이 media recovery의 `stop_at` 동작(CBRD-24378의 목적)을 바꾸지 않는지 확인한다.

## Definition of done

- 위 절차 또는 develop 재현 절차에서 재시작 복구가 assert 없이 끝난다.
- 같은 절차를 release 빌드로 실행해 복구 뒤 DB가 정상 동작함을 확인한다.
- CBRD-24378의 restoredb `-d` 시나리오가 회귀하지 않는다.
