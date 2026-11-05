# OOS postpone commit 미팅 결정 댓글 검토

2026-11-05 사용자가 미팅에서 팀장님에게 postpone commit 방식으로 진행하는 승인을 받았다고 공유했다. 아래는 그 결정을 JIRA에 남길 댓글이다. 사용자는 후속 답변으로 댓글 7건 게시와 본문 반영, 기록 문서의 main 통합·push를 승인했다. **본문·댓글 7건 모두 게시·검증 완료.** [게시 결과와 이슈별 댓글 링크](PUBLICATION.md)에 원문 및 검증 기록을 정리했다.

UPDATE 알림은 A'로 선택됐다. 관련 OOS 회수는 결정 단위의 확정 뒤 postpone 실행과 redo-only 삭제로 진행한다. 이 기록은 엔진 구현·회귀 검증·PR 병합 완료를 뜻하지 않는다. 기준 ADR은 `cubrid-oos-context`의 `docs/adr-0008-reclaim-after-finality`, `d5e81a7`이며 아직 `proposed` 상태다.

## 게시 대상

| 이슈 | 기록할 내용 |
| --- | --- |
| [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237) | rollback된 UPDATE의 chain 오삭제와 A' 알림 |
| [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781) | 확정 뒤 redo-only 회수와 재시도 |
| [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230) | 기존 commit hook 설계 개정 및 병합 후 일정 보존 |
| [CBRD-27881](https://jira.cubrid.org/browse/CBRD-27881) | 담당자 결정과 #8347 보류 해제 이력 |
| [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925) | LSA gate·빈 페이지 회수 작업의 정합성 |
| [CBRD-27841](https://jira.cubrid.org/browse/CBRD-27841) | 실제 복구 인덱스와 형식 처리 정합성 |
| [CBRD-27953](https://jira.cubrid.org/browse/CBRD-27953) | 제거할 forward-walk 경로와 누수 조사 연결 |

댓글은 이 문서의 각 절에 대응하는 동일 이름의 `.md` 파일을 사용한다. `manifest.json`은 파일의 SHA-256을 고정한다. `cubrid-jira comment --dry-run`으로 일곱 요청의 이슈 키와 변환 본문을 확인했고, 개인 열람용 주소가 댓글에 없음을 검사했다. 추가 승인에 따라 본문도 `descriptions.json`의 issue별 원문으로 개정한다. 이슈 summary·workflow·담당자는 변경하지 않는다.

## work-tracker 반영

| 항목 | 현재 상태와 다음 단계 |
| --- | --- |
| 705 | done. A' 선택과 기존 #8347 보류 해제 확인으로 방식 결정 완료 |
| 742 | pending. 승인된 방식의 엔진 구현·검증. 구현용 worktree 준비 |
| 747 | pending. ADR accepted 기록·사양 정합화·저장소 통합이 남음 |
| 528 | pending 유지. CBRD-27230 전체 재사용 구현은 develop 병합 이후 |
| 761 | pending 유지. 기존 FAIL과 재현 승인 조건 보존, 새 회수 설계와 정합화 |
| 677 | pending 유지. #8347 보류 해제·인덱스와 형식 정합성 기록, 11/10 일정 보존 |
| 514 | waiting 유지. PR7990 T1/T4 방식 결정 기록, 구현 완료·리뷰 회신과 구분 |

## 구현 세션과 남은 작업

구현용 checkout은 `/home/vimkim/gh/cb/CBRD-27781-postpone-commit`, branch는 `CBRD-27781-postpone-commit`이다. 2026-11-05에 fetch한 `origin/feature/oos-merge`의 `d52b1889e907abcf84190ec504dde3bc93de260d`에서 만들었다. 엔진의 로컬 통합 대상은 `feature/oos-merge`이며 아직 merge하지 않았다. 엔진 파일 수정·빌드·DB 실행은 하지 않았다.

1. Work747에서 ADR의 승인 사실과 A' 선택을 기록하고 B3 권고·미정 문구, 정규 사양과 확인 요청서의 충돌을 정리한다. 저장소 통합은 별도 승인 후 진행한다.
2. Work742에서 postpone 시 MVCCID 전달, 복구 중 알림 재발행·재실행 및 snapshot horizon을 구체화한다. 형식과 recovery index 변경은 CBRD-27841 및 최종 병합 시점에 맞춘다.
3. 기존 회귀 재현을 새 기준에 옮기고 rollback·savepoint·오래된 snapshot·동시 슬롯 재사용·오류·재시작·실제 빈 페이지 반환을 검증한다. CBRD-27925의 별도 DB 재현 승인 조건은 유지한다.
4. 엔진 반영 뒤 성능을 측정한다. 발표의 10만 UPDATE 비교는 아직 비용 추론이며 측정 결과가 아니다. CBRD-27230 재사용 전체를 이번 수정의 병합 전 필수 범위로 확대하지 않는다.

## PPT 원격 보관 제안

현재 `/home/vimkim/temp/oos-adr-0008-ppt`는 main `f130664490f4e51e8c83cee958807c5ec24b2699`이며 원격이 없다. 이 저장소의 미추적 `.gitignore`는 기존 변경으로 보존했다.

GitHub 검색에서 [cubrid-ai-ppt](https://github.com/vimkim/cubrid-ai-ppt)는 Claude Code 사용 경험 발표이고, [my-cubrid-page-buffer-seminar](https://github.com/vimkim/my-cubrid-page-buffer-seminar)는 별도 세미나 저장소임을 확인했다. `vimkim/cubrid-ppt-collections`는 검색되지 않았다. 추천은 새 `cubrid-ppt-collections`의 `oos-adr-0008/`에 이번 발표의 `deck.html`, `project/`, 빌드·검사 도구, `vendor/`, `verification/`, `evidence/`와 문서를 함께 보관하는 것이다. 새 저장소 생성·공개 범위·push는 아직 실행하지 않았고, 사용자 결정 후 진행한다. 저장 이력도 보존할 수 있게 이관 방식을 정한다.

## 댓글 전문

### CBRD-27237

미팅 결과, 팀장님 승인을 받아 UPDATE의 OOS 회수 알림은 **commit 후 postpone 실행 방식(A')**으로 진행하기로 했습니다.

- UPDATE가 버린 chain을 postpone으로 기록하고, commit 확정 후 `RVOOS_NOTIFY_VACUUM` 알림을 남깁니다. 문장 취소·savepoint rollback·트랜잭션 rollback으로 취소된 UPDATE의 알림은 실행하지 않습니다.
- vacuum은 기존 snapshot이 더 이상 그 chain을 필요로 하지 않을 때 회수합니다. UPDATE undo image에서 chain을 찾아 지우는 forward-walk 경로는 제거합니다.
- commit 레코드 이전의 단순 commit hook 알림을 이 방식으로 대체합니다. postpone 실행 시의 MVCCID 전달과 장애 후 재실행 경로를 구현·검증합니다.

[CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 확정 뒤 redo-only 회수 설계와 함께 반영합니다. 전용 worktree에서 구현한 뒤 rollback·savepoint·오래된 snapshot·crash recovery와 정상 commit 후 회수를 검증하겠습니다. 이번 댓글은 방식 결정 기록이며, 구현·검증 완료를 의미하지 않습니다.

### CBRD-27781

미팅 결과, 팀장님 승인을 받아 **삭제를 결정한 트랜잭션 또는 sysop의 commit 이후 postpone으로 OOS chain을 회수하는 방식**으로 진행하기로 했습니다.

- 삭제 결정과 함께 회수 의도를 postpone으로 기록합니다. 해당 단위가 abort되면 회수하지 않고, commit 뒤 회수기가 chunk를 redo-only로 삭제합니다.
- 회수는 tail부터 수행하고 head를 마지막에 지웁니다. 각 링크의 identity stamp를 검사하고, 오류·crash 뒤 재실행해도 다른 레코드를 지우거나 남은 chunk를 방치하지 않도록 합니다.
- REMOVE는 heap 레코드 제거와 회수 의도를 같은 sysop에 기록합니다. SA/non-MVCC eager 정리도 commit 이후 회수하도록 맞춥니다.

[CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 UPDATE 알림도 postpone 방식(A')으로 구현합니다. heap forward slot의 물리 undo 보호([CBRD-27858](https://jira.cubrid.org/browse/CBRD-27858))는 별도 수정으로 유지합니다.

전용 worktree에서 구현하고 동시 INSERT·오류·재시작 회귀 검증을 진행하겠습니다. 설계 승인을 기록한 것이며, 현재 결함의 수정 완료나 테스트 통과를 의미하지 않습니다.

### CBRD-27230

미팅에서 팀장님 승인을 받아 OOS UPDATE의 회수 알림은 **commit 후 postpone 실행 방식(A')**으로 진행하기로 했습니다.

본문의 `logtb_complete_mvcc` 직전 commit hook 발행 설계는 이 결정에 맞춰 개정합니다. UPDATE가 버린 chain을 postpone으로 기록하고, commit 확정 후 `RVOOS_NOTIFY_VACUUM` 알림을 남깁니다. vacuum은 오래된 snapshot이 끝난 뒤 회수하며, undo image 기반 forward-walk 삭제는 제거합니다. postpone 실행 시 MVCCID 전달과 복구 중 재실행을 구현·검증해야 합니다.

[CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)·[CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 수명·회수 수정과 정합성을 맞추겠습니다. 이 댓글은 본 이슈의 미할당 컬럼 chain 재사용이나 복제 marker 구현이 완료됐다는 뜻은 아닙니다. **본 이슈의 재사용 구현은 PR #7990의 develop 병합 이후 진행한다는 기존 일정도 유지합니다.**

### CBRD-27881

담당자 결정 사항을 공유합니다. 미팅에서 팀장님 승인을 받아 [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 수정은 **commit 후 postpone 알림(A')**으로, [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 OOS chunk 회수는 **확정 뒤 postpone 실행·redo-only 삭제**로 진행하기로 했습니다. 이슈 본문의 미정인 수정 방식은 이 결정으로 정리합니다.

#8347([CBRD-27841](https://jira.cubrid.org/browse/CBRD-27841))의 보류는 2026-11-03에 이미 해제한 결정대로 유지합니다. 알림을 구현할 때 실제 생산자·소비자와 필요한 복구 인덱스를 함께 정의합니다.

구현은 별도 worktree에서 진행하고 회귀 검증을 거칩니다. 이번 결정 기록으로 관련 결함이나 이 리팩토링 이슈 전체를 완료 처리하지는 않습니다.

### CBRD-27925

관련 회수 설계의 미팅 결정을 공유합니다. 팀장님 승인을 받아 [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 OOS chain 회수는 **삭제를 결정한 단위의 commit 뒤 postpone으로 실행하고, chunk는 redo-only로 삭제하는 방식**으로 진행하기로 했습니다. [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 UPDATE 알림도 postpone 방식(A')으로 구현합니다.

ADR-0008의 LSA reclaim gate 제거는 chunk 삭제를 undo하지 않는 새 경로가 갖춰진 뒤 적용할 사항입니다. 현행 코드에서 gate만 먼저 제거하지 않습니다. 모든 관련 경로의 undo 목적지를 확인하고, 기존 빈 페이지 반환·성장 전 재사용·재시도 요구와 함께 정합성을 검증하겠습니다.

기존 churn·snapshot FAIL, abort 잔여 두 페이지 및 READ 래치 경합 조사 근거는 보존합니다. 이번 설계 승인으로 해당 원인이 확인되거나 본 이슈가 해결된 것으로 처리하지 않습니다. 이 이슈에 기록된 실제 DB 재현의 별도 승인 조건도 유지합니다.

### CBRD-27841

관련 설계 결정 공유입니다. 미팅에서 팀장님 승인을 받아 [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 UPDATE 회수 알림은 **commit 후 postpone 실행 방식(A')**으로 진행하기로 했습니다. [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 확정 뒤 회수에도 postpone 및 redo-only 삭제용 복구 항목이 필요합니다.

#8347 보류를 해제한 2026-11-03 결정은 유지합니다. 현재의 미사용 예약 항목 정리와 실제 알림 구현은 구분하며, 후속 구현에서 필요한 복구 인덱스를 실제 생산자·소비자와 함께 정의하겠습니다. 이미 제거된 항목이 있는지는 구현 기준 revision에서 확인합니다.

복구 인덱스 번호·처리 함수 배열·MVCC 및 TDE 분류와 저장 형식 처리는 ADR-0008 및 최종 병합 시점의 정책에 맞춰 검증합니다. 이번 댓글로 #8347 병합이나 저장 형식 번호 변경을 실행하지는 않습니다.

### CBRD-27953

관련 설계의 미팅 결정을 공유합니다. 팀장님 승인을 받아 [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 UPDATE 회수 알림은 **commit 후 postpone 실행 방식(A')**으로 진행하기로 했습니다. UPDATE가 버린 chain을 알림으로 전달하고, undo image 기반 `vacuum_forward_walk_reclaim_oos` 경로는 제거하는 방향입니다.

본 이슈의 오류 무시 경로도 forward walk 안에 있으므로, 구현 과정에서 경로 제거 범위와 남는 호출자를 함께 확인하겠습니다. 새 알림 소비·회수 경로 역시 조회 실패를 정상 완료로 처리해 영구 누수를 남기지 않도록 재시도와 진단을 검증해야 합니다.

현재 코드는 아직 바뀌지 않았습니다. 해당 경로의 실제 제거와 대체 경로 검증을 확인한 뒤 본 이슈의 처리 범위를 정리하며, 설계 결정만으로 해결 완료나 중복 이슈로 종료하지 않습니다.
