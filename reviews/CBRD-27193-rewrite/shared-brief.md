# CBRD-27193 report rewrite: shared evidence and boundaries

Created 2026-10-21. Orchestrator: Codex. Work-tracker: 466.

This brief governs preparation of the reports, not the JIRA descriptions. The current writing skill and user instructions remain authoritative.

## Scope and source identity

The live recursive discovery found 20 issues: CBRD-27193 and 19 direct subtasks. An unfiltered `parent in (...)` query for every discovered key returned the same 19 children; every issue's `subtasks` field agrees, and all children have no children. Include every status. Keys only mentioned in prose or issue links are supporting context, not children. See manifest.json for exact live title/type/status, writer and output path.

Artifact checkout: `/home/vimkim/gh/my-cubrid-jira-CBRD-27193-rewrite`, branch `CBRD-27193-rewrite`, based on local main `da39b0f`. Destination: `/home/vimkim/gh/my-cubrid-jira`, main. Only the orchestrator performs Git, shared-file edits, or publication. No source, skill, or JIRA metadata changes.

Common current-behavior baseline: CUBRID **f6cac312310f39f46711693da157a08f0e725693**, local develop HEAD at discovery (2026-10-21). It is a pinned analysis baseline, not a claim about all releases or the remote's latest tip. Relevant storage files matched HEAD. Source checkout has unrelated CCI/JDBC and untracked dirt; preserve it. Use `git show <full-sha>:<path>` or the exact archive below, not a moving working file. A missing runtime reproduction is an ANALYSIS question, not proof that the issue does not exist.

Read-only source archive: `/home/vimkim/.local/share/cubrid-jira/rewrite-CBRD-27193-20261021/source-f6cac312`. It was extracted with `git archive` from that commit. Cite source with immutable GitHub links: `https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/<path>#Lx-Ly`. Verify the quoted lines.

Evidence cache: `/home/vimkim/.local/share/cubrid-jira/rewrite-CBRD-27193-20261021`. For each key read `<key>.json` (live fields/raw description), `<key>.md` (rendered live snapshot), `<key>-comments.json` (all live comments), `<key>-evidence.txt` (search pointers), and `<key>-original-claims.json` (original paragraph/table/code units, including local variants and comments). The cache is local evidence, not a publishable external link. Persistent evidence must cite its original committed source. Historical documents in my-cubrid-docs recently moved to code-analysis; retain source revisions and runtime-build identities. Use docs commit `fd2e244` or resolve its full SHA for current relocated paths; old commit links remain valid when verified.

## Objective and terminology

The parent coordinates evidence-backed page-buffer correctness, operation, maintainability and performance work. It does not preselect a full rewrite, require every survey to produce code, or invent priority/owner commitments. Preserve the parent's two actual comments: consider TPC-H cases CBRD-27188/27191, and consider a buffer-manager unit-test framework plus workloads that expose bottlenecks. These are attributed requests, not benchmark results or an agreed implementation.

Use page buffer / 페이지 버퍼 consistently. Define BCB (buffer-slot control state), VPID (volume/page identifier), fix/unfix (residency/usage accounting), page latch (short-term in-memory access coordination), and transaction lock separately where needed. Dirty/LSA/flush are not commit or durable-disk equivalence. Distinguish `pgbuf_fix` from `pgbuf_simple_fix` and ordinary nested fix from ordered-fix protection. Use direct victim for the existing handoff mechanism; do not conflate queue availability, waiting policy and an unreachable emergency consumer.

## Child boundaries

- 27194: initialization/finalization lifetime and partial-failure hygiene.
- 27196: SX page-latch need/feasibility, actual CUBRID B-tree use cases. No assumed adoption or speedup.
- 27211: direct-victim wait/check cadence (`my_count % 4`) and evidence for policy changes.
- 27252: requested default/v2 parallel-version strategy and comparison/rollback needs. Historical M0-M8 proposal is a proposal unless agreement can be verified.
- 27262: flush preparation failure state/waiter recovery, especially TDE/DWB early returns. Distinguish reachable production errors from injected or hypothetical ones.
- 27263: request-page deallocation-protection accounting across fast, ordinary, and reordered fix paths. Historical instrumentation is not current corruption proof.
- 27264: unreachable direct-victim emergency path; restore versus remove remains ANALYSIS.
- 27265: the two debug-build defects and their scoped diagnostics/test consequences.
- 27266: counter meaning and logical/physical I/O observability; check merged PR #7592/current NULL columns before repeating old SHOW claims.
- 27267: big-private-victim queue producer/consumer policy; restore versus remove remains ANALYSIS.
- 27268: explicitly requested size-unit syntax for double_write_buffer_size. Verify current parameter/parser behavior; do not change the capability to a generic survey.
- 27269: supported dead code and stale comment cleanup with preserved intended behavior. Do not absorb unresolved policy decisions from 27264/27267.
- 27270: recovery-time temporary-volume classification, reachability and consequences; investigation can conclude no functional defect.
- 27316: parallel fix/private LRU victim-pattern survey. Live body is empty; derive a bounded investigation from the title, primary code and related documented context. State unknown motivation without inventing a benchmark or design.
- 27356: interaction between transaction lock timeout and page-latch policy. Include the attributed 2026-09-29 debug-abort report with its builds/counts; policy selection remains ANALYSIS. A broader re-triage work item exists but this task publishes descriptions only.
- 27370: ordinary nested READ-to-WRITE fix BCB/holder accounting and the API policy uncertainty. Keep historical probe builds distinct from current source and production SQL reachability.
- 27398: requested read-only optional page-buffer overlay interface for Volmap. Live body is empty but a detailed local report and recorded Wayfinder decisions exist. Verify those decisions before preserving agreed scope; do not replace them with blanket TBD or claim a draft PR is merged.
- 27423: performance analysis and focused test/workload framework. Consider requested TPC-H workloads and common comparison needs; no assumed tool choice, measured speedup or global prerequisite edge.
- 27630: simple-fix failure cleanup and loading-record ownership race. Separate formal/model counterexample from demonstrated engine scheduling/error reachability.

No inferred hard dependency merely because one issue's tools could help another. Identify information-sharing and real prerequisites separately. Parent completion must account for all children and explicit dispositions of investigations, not require every speculative implementation.

## Writer contract

Exactly one fresh-context dedicated writer per issue; see manifest. Read directly: user AGENTS guidance, artifact CLAUDE.md, `/home/vimkim/my-cubrid/CUBRID.md`, current `cubrid-jira-issue-write/SKILL.md`, both referenced classification/publication files, and relevant source AGENTS guidance. Read evidence, not other rewritten reports as authority. Verify material primary claims yourself. Do not delegate, run Git operations, publish, or modify shared files. Write only your assigned report at the manifest's exact path.

Use current skill's Korean 한다체 and English ## headings, four opening fields including **영향**, explicit divider and AI-Generated Context. Explain what is wrong/missing, concrete consequences, and why work is justified; request confirmation and author-side ANALYSIS ownership. Keep observations, attributed historical reports, source deductions, hypotheses and unknowns distinct. Preserve documented choices with sources; leave unselected design in ANALYSIS. Acceptance criteria are observable outcomes. Use portable project commands, BMP text, no emoji, and zero `\bjust\s+\w` matches. Include immutable evidence links with correct baseline. Do not carry stale risk rankings, invented urgency, unverified customer exposure or zero-impact guarantees forward.

Self-review the complete saved report. Return report path; recommended type/category/components (do not mutate live Sub-task); primary evidence; material corrections; unresolved questions; cross-issue concerns. Include a grouped accounting of original substantive claims by inventory IDs: retained with evidence, corrected with reason, or removed with reason. Group duplicate/history/template units explicitly; identify non-substantive formatting/reference-only units. The orchestrator owns the durable audit outside published bodies. Do not insert the audit into the report.

Parent writer: read and assess first, then wait for reviewed child outcomes. Only write the final parent after the orchestrator supplies reconciled child reports and decisions.

## Session instruction reminder

The user's global AGENTS instructions apply: ask only when ambiguity changes outcome/scope/risk; resolve routine reversible details with stated assumptions; use work-tracker for parallel/long work (orchestrator item466). This is a remote Linux server with slow X11: never launch GUI programs, disable browser auto-opening, use headless tools/URLs/terminal. Inspect and preserve unrelated Git state; meaningful artifacts must be locally committed before review. The orchestrator alone handles the prescribed topic-worktree, approved rebase/merge/push/publication/cleanup workflow. CUBRID.md personal policies override conflicting repository guidance. Ordinary next-step questions refer to this session goal. The full batch needs one approval after all reports are reviewed, not per-writer approvals.

## Reconciled findings from first batch

The following are reviewed corrections, not new implementation commitments. CBRD-27262 must distinguish first preparation failure from DWB-disabled retry after LSA reset; ordinary DWB slot shortage is success/null. CBRD-27263 must judge request-owned registration within a BCB residency; pre-CAS logging and VPID net totals do not prove exact live-marker theft or permanent loss. CBRD-27370 retains actual BCB/holder mismatch and raw historical probes while general promotion policy and SQL reachability remain unknown. CBRD-27356 uses current thread-local overrides and explicit latch-refusal taxonomy; developer-reported debug aborts retain their historical builds/counts. CBRD-27194 must distinguish forced-off AOUT from actual reachable partial-init cleanup and zero-private arrays. CBRD-27398 latest tracked Volmap decisions supersede the initial 64MiB/loopback-only/scope plan; its source does not belong to the current develop baseline.

Statistics review also confirms Num_data_page_iowrites is a page-unit aggregation, not an OS-call count or logical flush count; DWB staging does not itself prove durable completion, and a fixed2x comparison is unjustified. The performance framework must use defined metrics and preserve missing/disabled/NULL states.
