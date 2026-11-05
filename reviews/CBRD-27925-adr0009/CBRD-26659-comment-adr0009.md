[CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)의 결정(2026-11-05, OOS 명세 ADR-0009)에 따라 빈 페이지 반환 TC의 판정 기준을 바꿨습니다.

독립 조사에서 명세의 "빈 페이지는 결국 반환된다"와 "회수 가능한 빈 페이지가 있으면 새 섹터를 예약하지 않는다"가 실제로 모순됨을 발견했습니다. 반환된 페이지는 같은 OOS 파일의 섹터 안에 남아, 그 파일의 다음 할당만 쓸 수 있습니다. 그래서 쓰기가 없는 동안의 반환은 요구하지 않고, 다음 할당 전에 재사용되는지만 판정합니다.

- 대상: `churn_abort_retry`, `churn_insert_delete`, `churn_insert_update_delete`, `churn_restart`, `snapshots_reclaim`. 공통 helper `oos_churn.sh`, `snapshot_controller.sh` 를 고쳤습니다.
- 변경 전: 삭제·vacuum 뒤 쓰기 없이 20초 기다려 OOS 사용자 페이지 수가 줄었는지 판정.
- 변경 후: 대기 뒤 페이지 수는 관측으로만 기록. 같은 INSERT를 다시 할 때 첫 cycle(abort retry는 rollback된 INSERT)의 페이지 상한을 넘지 않는지 판정. 마지막 refill의 섹터 비교는 그대로 유지.
- 상태: `tc/pr-8128` 에 로컬 commit만 했고 push·실행은 하지 않았습니다. 다섯 케이스는 native 실행이 통과할 때까지 `disabled/` 에 둡니다. `snapshot_visibility` 의 판정은 바뀌지 않습니다.
