**[종결] PR #8434로 해결**

ADR-0009의 요구(같은 OOS 파일은 새 섹터를 예약하기 전에 회수 가능한 빈 페이지를 회수·재사용한다)는 [PR #8434](https://github.com/CUBRID/cubrid/pull/8434)(2026-11-18 `feature/oos-merge`, 병합 커밋 `e1ba4675f2`)로 충족했습니다. 이 이슈를 Fixed로 닫습니다.

**1. 반영된 변경**

- `[CBRD-27925] Arm growth-side reclaim with emptied pages, not chunk deletes`: `pending_deletes` 카운터를 파일별 빈 페이지 집합(ADR-0010)으로 바꿨습니다. 삭제, INSERT rollback undo, 빈 페이지에서 실패한 insert가 페이지 래치를 쥔 채 그 페이지를 집합에 넣습니다. 성장은 집합부터 확인합니다. 집합 overflow·메모리 부족·재시작이 있으면 파일을 unknown으로 표시하고, 다음 성장이 파일을 한 바퀴 검사합니다.
- `[CBRD-27925] Hold the OOS growth lock through file_alloc and recheck the emptied-page set`: 성장 잠금을 `file_alloc`까지 유지하고, 한 바퀴 검사 뒤 집합을 다시 확인합니다. 보충 2 댓글(2026-11-09)에서 찾은 빈틈의 보강입니다.
- LSA gate 제거: 같은 PR의 ADR-0008 구현(확정 뒤 postpone, redo-only 회수)으로 chunk 삭제 undo가 없어져 gate를 제거했습니다.

**2. 근거 테스트** (`unit_tests/oos/test_oos_growth_sweep.cpp`)

- ADR-0010 결과 5의 네 경우: `PageLatchedByRollbackStaysCandidate`, `DeleteThatEmptiesNoPageCostsGrowthNothing`, `LapAfterRestartRechecksBusyPage`, `SetOverflowFallsBackToOneLap`.
- 커밋 메시지에 따르면 각 테스트는 옛 동작을 되살리는 변형에서 실패하고, PR 시점에 configured ctest 52건이 통과했습니다.

**3. CBRD-26659 회수 TC 5건** (2026-11-19 로컬 실행)

- Engine `feature/oos-merge` `8c478d8559`(release), TC `tc/pr-8128` `68d473c3b`(ADR-0009 판정). 이 TC들은 비활성 상태라 CI에서 돌지 않으므로 native testkit으로 로컬에서 실행했습니다.
- 결과: 5건 모두 PASS.

| TC | 첫 cycle 페이지 상한 | 이후 cycle peak | 허용치 | 섹터 (첫 peak → 마지막 refill) |
| --- | --- | --- | --- | --- |
| `churn_abort_retry` | 97 (rollback된 INSERT) | 98 | 10 | 2 → 2 |
| `churn_insert_delete` | 97 | 97 | 10 | 2 → 2 |
| `churn_insert_update_delete` | 97 / UPDATE 193 | 98 / UPDATE 194 | 10 / 20 | 4 → 4 |
| `churn_restart` | 97 | 98 | 10 | 2 → 2 |
| `snapshots_reclaim` | 25 | 25 | 3 | 판정 없음 |

- 한계: TC를 고치지 않으면 통과하지 않습니다. 실행 사본에서 엔진 변경에 맞춰 기대값 두 가지만 고쳤습니다. 하나는 `cubrid diagdb`의 파일 종류 이름 `OOS`([CBRD-28023](https://jira.cubrid.org/browse/CBRD-28023))이고, 다른 하나는 PR #8434가 chunk 헤더에 넣은 8바이트에 맞춘 byte 상수입니다. 판정 로직은 바꾸지 않았습니다. TC 저장소 반영과 활성화는 CBRD-26659에서 합니다.

**4. 잔여 두 페이지와 READ 경합 가설**

- Abort 잔여 `1|1312`, `1|1313`의 원인은 2026-11-05 결정대로 이 이슈에서 확정하지 않았습니다. 두 후보 경로 모두 지금 코드에 없습니다. LSA gate는 제거되었고, 래치에 걸린 페이지는 집합에 남아 다음 성장이 다시 봅니다. 원인을 확정해도 수정 방향은 바뀌지 않습니다.
- INSERT rollback과 1차 READ 경합 순서가 실제 SQL로 일어나는지는 재현하지 않았습니다. 대신 설계로 닫고, 단위 테스트(`PageLatchedByRollbackStaysCandidate`, `LapAfterRestartRechecksBusyPage`)로 그 순서를 고정했습니다.
- 본문 Acceptance Criteria 중 native 재현 승인, horizon 공급자 특정, 잔여 두 페이지의 호출 연결은 gate가 제거되어 대상이 없어졌으므로 수행하지 않았습니다. 성장 전 회수·재사용은 위 2, 3으로 확인했습니다.

**5. 이 이슈 밖으로 옮긴 것**

- 빈 페이지를 반환하지 않고 그 자리에서 재사용하고 vacuum fast path를 없애는 변경(ADR-0011, Draft PR #8493)은 새 개선 이슈 [CBRD-XXXXX](https://jira.cubrid.org/browse/CBRD-XXXXX)에서 다룹니다.
- 보충 2 댓글의 모델 한계(rollback이 후보마다 맞춰 래치를 잡고 성장 중 쓰기가 겹치는 경우)는 그대로 남습니다.
