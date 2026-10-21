# CBRD-27193 discovery and evidence identity

Discovery: 2026-10-21. Work-tracker 466. This document records the rewrite scope; it is not a JIRA body.

The initial live query `key = CBRD-27193 OR parent = CBRD-27193 ORDER BY key ASC` returned 20 issues. An unfiltered recursive query using every discovered key as a potential parent returned exactly 19 children. Each raw `fields.subtasks` set equals the children returned by JQL. Every child's `parent.key` is CBRD-27193, and every child has an empty subtasks set. No status was excluded. The live snapshots and complete comment-list responses are in the tool-owned cache named in manifest.json; their SHA-256 fingerprints are retained here.

| Key | Relationship | Live type | Live status | Comments |
| --- | --- | --- | --- | --- |
| CBRD-27193 | root | Development Subject | Open | 2 |
| CBRD-27194 | subtask | Sub-task | Confirmed | 0 |
| CBRD-27196 | subtask | Sub-task | Open | 2 |
| CBRD-27211 | subtask | Sub-task | Open | 0 |
| CBRD-27252 | subtask | Sub-task | Open | 0 |
| CBRD-27262 | subtask | Sub-task | Confirmed | 0 |
| CBRD-27263 | subtask | Sub-task | Confirmed | 1 |
| CBRD-27264 | subtask | Sub-task | Open | 0 |
| CBRD-27265 | subtask | Sub-task | Open | 0 |
| CBRD-27266 | subtask | Sub-task | Open | 0 |
| CBRD-27267 | subtask | Sub-task | Open | 0 |
| CBRD-27268 | subtask | Sub-task | Open | 0 |
| CBRD-27269 | subtask | Sub-task | Open | 0 |
| CBRD-27270 | subtask | Sub-task | Open | 0 |
| CBRD-27316 | subtask | Sub-task | Open | 0 |
| CBRD-27356 | subtask | Sub-task | Open | 1 |
| CBRD-27370 | subtask | Sub-task | Confirmed | 0 |
| CBRD-27398 | subtask | Sub-task | Open | 0 |
| CBRD-27423 | subtask | Sub-task | Open | 0 |
| CBRD-27630 | subtask | Sub-task | Confirmed | 0 |

Keys mentioned in the descriptions/comments or ordinary issue links but not actual descendants: CBRD-20074, CBRD-20741, CBRD-20897, CBRD-24029, CBRD-26242, CBRD-26425, CBRD-27084, CBRD-27188, CBRD-27191, CBRD-27198, CBRD-27486, CBRD-27576. These remain supporting context and are not publication targets.

The common current-behavior baseline is CUBRID `f6cac312310f39f46711693da157a08f0e725693`, the local develop HEAD at intake. It is not presented as every supported release or the remote latest tip. Relevant storage files matched HEAD. The archive contains src, unit_tests, cmake, CMakeLists.txt, build.sh and root AGENTS.md at that immutable commit. No engine source was edited or compiled in this task. Historical runtime evidence retains the source/build identity recorded by its original report.

Repository searches covered `/home/vimkim/gh/my-cubrid-jira` and `/home/vimkim/gh/my-cubrid-docs`. Per-issue evidence lists are cached. Shared historical findings are under `code-analysis/pgbuf/` at docs commit `fd2e244e585de7a78dfccbbdfde722eef1b49210`; the recent directory migration is not a revalidation of those findings. Key-specific reports, seminar probes and source snapshots are reviewed by each issue's dedicated writer. The original local issue reports are preserved unchanged.

CBRD-27398 required following its existing local report to the actual Volmap decision records. These are tracked at `https://github.com/vimkim/volmap`, commit `c9ed4ccaae4310fad380384a5808ee1e14e8d14c`, despite their .scratch path names. An archive of tracked docs and decision directories excludes live unrelated dirt. PR 7940 is OPEN/Draft at `6bf4753eaa136fb87a4632deac44dc403ad0538e`; it is separate from the develop baseline and local producer documentation at `48a3e87e3d56d3b0c998d286f17fc6674bb5e547`. None is treated as a merged feature.

The orchestrator owns all shared artifacts, review, Git and publication. Each issue has exactly one fresh-context writer, retained for revisions. Parent drafting follows child reconciliation. The manifest is the publication allowlist; only descriptions may change.

A final unfiltered 20-key attachment inventory found exactly one attachment: CBRD-27194 / 1020015, a 2026-08-06 screenshot of the original sizeof/reinitialization analysis. It was downloaded and visually inspected; it contains code and assertions, not runtime evidence. The assigned writer reviewed its claims and records them in the supplemental audit. Every other scoped issue has zero attachments. No fixVersion is set on these 20 issues; that metadata is not evidence that a release is affected or unaffected.
