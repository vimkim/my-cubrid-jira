# [OOS] vacuum OOS 회수 경로의 crash-injection 회귀 테스트 추가

## Issue Triage

**이슈 수행 목적** (필수): vacuum 의 OOS 회수와 SA_MODE eager OOS 삭제가 중간 crash 후에도 일관되게 복구됨을, 강제 종료를 주입하는 단위 테스트로 검증한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: 회수 원자성은 sysop (system operation - 독립적으로 commit/abort 되는 내부 atomic 경계) 경계 (`log_sysop_start` ~ `log_sysop_commit`/`log_sysop_abort`) 와 청크별 `RVOOS_DELETE` undo 로 design-level 로는 보장된다 (코드 라인 인용 가능). 그러나 sysop 도중 강제 종료 후 재시작하는 시나리오를 재현하는 테스트가 없다. 기존 OOS 테스트(`test_oos_vacuum_server` 등)는 happy-path 와 회수 결과만 본다.
- **영향**: 기술 부채 + 검증 공백. PR #6986 에서 hornetmj 가 지적(코멘트 3121805315, `vacuum.c:2601`): "oos delete - sysop commit ~~ crash ~~ bulk vacuum heap" 순서의 복구가 미검증이다. 또한 ADR-0002 의 bounded-leak 동작(일시 실패를 block 실패로 전파하지 않고 로깅 후 continue)도 회귀 테스트가 없어, 향후 누가 다시 `goto end` 로 바꿔 vacuum 을 wedge 시켜도 잡지 못한다.

**이슈 수행 방안**:

- sysop 경계 직전/직후 강제 종료 -> 재시작 후 OOS/heap 일관성(고아 OOS 없음, dangling 참조 없음)을 검증하는 테스트를 추가한다.
- `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` (rcvindex 136) 의 redo/undo 가 `RVHF_DELETE` 와 동일하게 forward-delete 를 재현하는지 recovery 테스트.
- ADR-0002 bounded-leak: 일시 조회 실패를 주입했을 때 block 이 wedge 되지 않고 완료되며 leak 이 로깅되는지 검증.
- `TBD - ANALYSIS 단계에서 결정`: crash 주입 메커니즘(기존 CUBRID 테스트 인프라의 어떤 hook 을 쓸지).

---

## AI-Generated Context

> 아래 내용은 AI 가 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하다.

### Summary

- **문제 / 목적**: OOS 회수 경로의 crash-recovery 를 실제로 검증하는 테스트 부재.
- **원인 / 배경**: 기존 테스트는 happy-path 와 회수 결과만 확인.
- **제안 / 변경**: crash-injection + recovery 회귀 테스트 추가.
- **영향 범위**: `unit_tests/oos/`. production 코드 변경 없음.

---

## Description

PR #6986 은 vacuum forward-walk OOS 회수, SA_MODE eager DELETE/UPDATE 회수, 신규 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 레코드를 추가했다. 모두 sysop + 청크별 undo 로 원자성을 설계했으나, 강제 종료 경로는 테스트로 덮이지 않았다. 회수 로직은 recovery 정합성에 직결되므로 crash-injection 커버리지가 필요하다.

## Specification Changes

N/A (테스트 추가, 사용자 가시 동작 변화 없음).

## Implementation

기존 OOS SERVER_MODE 테스트 인프라(`unit_tests/oos/test_oos_vacuum_server.cpp` 등)를 확장한다. sysop commit 전후 강제 종료 -> 재시작 -> redo/undo 재생 후 OOS 파일과 heap 슬롯의 정합성을 단언한다. bounded-leak 검증은 조회 실패를 주입하는 fault hook 으로 구성한다. 세부는 ANALYSIS 단계에서 확정.

## Acceptance Criteria

- [ ] sysop 중 crash 후 재시작 시 고아 OOS / dangling 참조가 없음을 단언하는 테스트
- [ ] `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` redo/undo recovery 테스트
- [ ] bounded-leak 동작(일시 실패 시 block 미-wedge + leak 로깅) 회귀 테스트

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] 기존 OOS 테스트 무회귀
