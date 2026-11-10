CBRD-27881 리팩토링 조사 항목 R-34를 이 이슈로 넘긴다(2026-11-10 담당자 결정).

R-34는 OOS bestspace의 3단계 sync와 그에 딸린 코드가 운영 경로에서 쓰이지 않는다는 항목이다. 원인은 이 이슈 본문이 설명하는 sync 발동 조건 결함(DF-01)과 같다. 담당자는 sync를 고치지 않고, 이 이슈의 재설계에서 legacy 구조와 함께 지우기로 정했다. 지금 sync를 고치면 그 수정은 재설계 때 버려지기 때문이다.

재설계 때 함께 지울 대상이다(`feature/oos-merge` `50619ce53`, `src/storage/oos_file.cpp` 기준).

- sync 추정 필드: `estimates.num_pages`, `num_other_high_best` 등 sync와 그 발동 조건만 쓰는 헤더 필드
- `second_best` ring과 helper(`oos_stats_put_second_best`, `oos_stats_get_second_best`)
- `idx_badspace` 인자
- sync 상수: `OOS_BESTSPACE_SYNC_THRESHOLD`, `oos_Find_best_page_limit`
- unit test 전용 `bridge_oos_stats_sync_bestspace` 와 이를 전제로 한 테스트

sync를 지우면 OOS 설계 명세 §2(Best Page Policy)의 "재시작 뒤 sync로 빈 공간을 재발견한다" 문장도 새 설계에 맞게 고친다.

근거: CBRD-27881 리팩토링 후보 보고서의 R-34와 결정 필요 항목 문서.
