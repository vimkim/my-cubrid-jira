# CBRD-27925 close and CBRD-28281 split: publication

Work1049. Each write was made at the issue owner's request after the owner reviewed the draft.

## 2026-11-19 (KST)

| Time | Target | Result |
| --- | --- | --- |
| 22:18 | [CBRD-28281](https://jira.cubrid.org/browse/CBRD-28281) created | Sub-task under CBRD-26978, Minor, unassigned, Relates CBRD-27925. Body from `issues/oos-reuse-emptied-pages-in-place.md` (renamed to `issues/CBRD-28281-oos-reuse-emptied-pages-in-place.md` in `b81b3d7` without content changes). |
| 22:19 | CBRD-27925 description | Replaced from `issues/CBRD-27925-deferred-empty-page-reclaim.md` at `b81b3d7` (Conclusion 2026-11-19 section). The live description equals the dry-run payload. |
| 22:19 | [CBRD-27925 comment 4778825](https://jira.cubrid.org/browse/CBRD-27925?focusedCommentId=4778825#comment-4778825) | Body `CBRD-27925-comment-close.md`. The live comment equals the dry-run payload. |
| 22:19 | CBRD-27925 workflow | Analysis → Develop (261) → Handover (311) → Resolved, resolution Fixed (361). The issue was read again after each step. Assignee vimkim unchanged. |

The notes repository `main` was pushed at `b81b3d7`.

## 2026-11-23 (KST)

PR #7990 squash-merged the OOS feature branch into develop (`68a9c7766f`, 2026-11-20 00:09), two hours after CBRD-28281 was created. PR #8493's base moved to `develop` on 2026-11-20 (Work508). These updates follow from that change.

| Target | Result |
| --- | --- |
| CBRD-28281 description | Replaced from `issues/CBRD-28281-oos-reuse-emptied-pages-in-place.md` at `40c63de`. The before/after-develop-merge timing choice was removed, the current-behavior heading now names develop `68a9c7766f`, and the PR state was restated. The raw live description equals the dry-run payload byte for byte (7,671 characters, SHA-256 `913c2b70fdcc5636…`). Status Open, unassigned, Minor, Sub-task are unchanged. |
| [PR #8493](https://github.com/CUBRID/cubrid/pull/8493) title | `[CBRD-27925] …` → `[CBRD-28281] Reuse emptied OOS pages in place instead of deallocating` |
| PR #8493 body | Replaced from `my-cubrid-docs` `cbrd-28281/pr-body-8493.md` (context `cbrd-28281/pr-context-8493.md`). The live body equals the file. The PR is still a Draft, base `develop`, head `f1c78ce70b`. No source push. |

## Not done

- CBRD-28281 `To Triage` (701) is on hold at the owner's request (2026-11-23), pending further study. Running this transition keeps the status Open and sets the assignee to `cubrid todo`, then to hornetmj, as seen on CBRD-28259 and CBRD-28312.
- The PR #8493 rebase onto develop waits for the CBRD-28281 decision (Work878).
- The local run of the five CBRD-26659 reclaim TCs (2026-11-19, `~/tk/27925-3`) and its verification worktrees were deleted. The result table in comment 4778825 and the Work1049 notes are the only remaining record. Enabling those TCs still needs the diagdb kind `OOS` and the +8 bytes per chunk constants.
