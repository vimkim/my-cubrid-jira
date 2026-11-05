# OOS postpone 미팅 결정의 JIRA 반영 결과

2026-11-05 사용자 승인에 따라 관련 JIRA 7건에 댓글을 추가하고 본문을 개정했다. 댓글 원문은 `7ea7a53`, 본문 원문은 `2d19683881c18de7d37c448010a33dde0f4123bd`로 먼저 GitHub main에 게시했다. 그 뒤 JIRA를 변경하고 원시 본문을 대조했다.

## 반영한 이슈

| 이슈 및 게시 댓글 | 본문 원문 | 확인 |
| --- | --- | --- |
| [CBRD-27237, 댓글 4777965](https://jira.cubrid.org/browse/CBRD-27237?focusedCommentId=4777965#comment-4777965) | [원문](../../issues/CBRD-27237-oos-rollback-value-preservation_dcbf09e_codex.md) | 본문·댓글 정확히 일치 |
| [CBRD-27781, 댓글 4777966](https://jira.cubrid.org/browse/CBRD-27781?focusedCommentId=4777966#comment-4777966) | [원문](../../issues/CBRD-27781-oos-delete-undo-space-conflict_dcbf09e_codex.md) | 본문·댓글 정확히 일치 |
| [CBRD-27230, 댓글 4777967](https://jira.cubrid.org/browse/CBRD-27230?focusedCommentId=4777967#comment-4777967) | [원문](../../issues/CBRD-27230-oos-update-dedup_725a32c_claude.md) | 본문·댓글 정확히 일치 |
| [CBRD-27881, 댓글 4777968](https://jira.cubrid.org/browse/CBRD-27881?focusedCommentId=4777968#comment-4777968) | [원문](../../issues/CBRD-27881-oos-refactor-todo.md) | 본문·댓글 정확히 일치 |
| [CBRD-27925, 댓글 4777969](https://jira.cubrid.org/browse/CBRD-27925?focusedCommentId=4777969#comment-4777969) | [원문](../../issues/CBRD-27925-deferred-empty-page-reclaim.md) | 본문·댓글 정확히 일치 |
| [CBRD-27841, 댓글 4777970](https://jira.cubrid.org/browse/CBRD-27841?focusedCommentId=4777970#comment-4777970) | [원문](../../issues/CBRD-27841-oos-recovery-index-cleanup_eac70c7_codex.md) | 본문·댓글 정확히 일치 |
| [CBRD-27953, 댓글 4777971](https://jira.cubrid.org/browse/CBRD-27953?focusedCommentId=4777971#comment-4777971) | [원문](../../issues/CBRD-27953-oos-forward-walk-vfid-lookup-error.md) | 본문·댓글 정확히 일치 |

원시 JIRA description을 Markdown 변환 요청과 바이트 기준으로 대조했다. 각 댓글은 전체 comment-list에서 반환된 본문과 변환 요청이 정확히 일치하고, 같은 본문의 댓글이 한 건만 존재함을 확인했다. 제목·workflow·담당자·우선순위·이슈 유형·라벨·컴포넌트는 본문 변경 전후 값이 같았다. payload SHA-256과 comment ID는 [publication.json](publication.json)에 보존한다.

## 반영 범위

- CBRD-27237은 commit 후 postpone 알림(A')과 rollback·snapshot·복구 검증 의무를 기록했다.
- CBRD-27781은 확정 뒤 postpone·redo-only 회수, tail-first·head-last와 링크 identity·재시도를 기록했다. 기존 재현 결과는 보존했다.
- CBRD-27230의 commit 전 hook 설계를 대체하고, 미할당 컬럼 재사용 전체는 develop 병합 이후라는 일정을 유지했다. 기존 20B stub 표기는 현재 사양의 24B로 정합화했다.
- CBRD-27881은 미정이던 DF-03 선택과 기존 #8347 보류 해제 결정을 반영했다.
- CBRD-27925는 새 회수 설계와 LSA gate 제거의 적용 조건을 구분하고, 기존 FAIL과 별도 DB 재현 승인 조건을 보존했다.
- CBRD-27841은 기존 revision 2 후보의 검증 기록을 보존하면서 병합 전 revision 1·개발 DB 재생성 결정과 구분했다.
- CBRD-27953은 forward-walk 제거와 대체 알림·회수 경로의 오류·재시도 검증에 연결했다.

## 남은 작업

Work742의 엔진 구현·검증과 Work747의 ADR accepted 기록·정규 사양 정합화는 아직 남아 있다. 구현용 `/home/vimkim/gh/cb/CBRD-27781-postpone-commit`은 보존했으며, 엔진 구현·빌드·DB 실행·엔진 branch 통합은 이번 JIRA 게시 작업에 포함하지 않았다.
