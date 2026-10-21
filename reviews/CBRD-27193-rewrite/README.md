# CBRD-27193: reviewed rewrite batch

Prepared 2026-10-21 by Codex, work-tracker 466. Each of the 20 issues has one dedicated fresh-context writer; the orchestrator reviews all reports, owns shared evidence and Git, and publishes only after the single batch approval.

Current-behavior baseline: CUBRID **f6cac312310f39f46711693da157a08f0e725693**. Historical findings keep their original source/build identity. The actual live scope is one Development Subject and 19 direct Sub-task children, with no deeper descendants. Supporting linked issues are outside the publication allowlist.

Artifact checkout: `/home/vimkim/gh/my-cubrid-jira-CBRD-27193-rewrite`, branch `CBRD-27193-rewrite`, from notes main `da39b0f3ee0bc1c55d2063588c3969a808a95687`. Destination: `/home/vimkim/gh/my-cubrid-jira`, main. Integration approval remains outstanding; descriptions have not been published by this task.

## Per-issue review

| Report | Major correction or outcome | Remaining uncertainty | Review |
| --- | --- | --- | --- |
| [CBRD-27193](../../issues/CBRD-27193-page-buffer-program_f6cac31_codex.md) | All 19 child outcomes reconciled; unsupported gates, priorities and adopted-design claims removed. | Actual engine/release exposure, policy choices, duplicate ownership and overlay budget decision. | passed |
| [CBRD-27194](../../issues/CBRD-27194-initialization-finalization_f6cac31_codex.md) | Initialization lifetime and zero-private behavior verified; AOUT recipe corrected. | AOUT supported reachability, runtime cleanup and platform/release exposure. | passed |
| [CBRD-27196](../../issues/CBRD-27196-sx-latch-survey_f6cac31_codex.md) | SX case rebuilt around current B-tree split/merge; stale OID and experimental counter claims corrected. | Contended workload evidence, adoption scope and costs. | passed |
| [CBRD-27211](../../issues/CBRD-27211-direct-victim-wait-policy_f6cac31_codex.md) | Global selector cadence and fallback verified; invented thresholds removed. | Original rationale for 4, current CPU/wait effects and decision criteria. | passed |
| [CBRD-27252](../../issues/CBRD-27252-parallel-v2-strategy_f6cac31_codex.md) | Requested parallel default/v2 strategy separated from learning-plan implementation. | Initial scope, selection/coexistence, compatibility, cost and adoption. | passed |
| [CBRD-27262](../../issues/CBRD-27262-flush-error-recovery_f6cac31_codex.md) | Phase-aware flush recovery; DWB reachability and historical evidence limits corrected. | Real TDE/DWB error reachability; current runtime and release exposure. | passed |
| [CBRD-27263](../../issues/CBRD-27263-deallocation-protection-accounting_f6cac31_codex.md) | Request-owned protection and BCB residency; historical counts and permanent-loss claims corrected. | Actual CAS ownership sequence, current vacuum/runtime effects and release exposure. | passed |
| [CBRD-27264](../../issues/CBRD-27264-direct-victim-emergency-path_f6cac31_codex.md) | Unreachable backup supply verified; duplicate CBRD-24029 owner/result reconciliation preserved. | Low-activity reachability, actual delays, alternative progress and release scope. | passed |
| [CBRD-27265](../../issues/CBRD-27265-debug-build-defects_f6cac31_codex.md) | CUBRID_DEBUG vs !NDEBUG conditions, diagnostic defects and undefined VPID read verified. | Current compile/recovery evidence, exposure and diagnostic reactivation safety. | passed |
| [CBRD-27266](../../issues/CBRD-27266-statistics-semantics_f6cac31_codex.md) | SHOW deprecation and page-unit DWB/statdump semantics verified. | Runtime values/cost, error contract, manual and consumers. | passed |
| [CBRD-27267](../../issues/CBRD-27267-big-private-victim-queue_f6cac31_codex.md) | Producer exists; bootstrap/re-registration and restricted-consume policy rebuilt. | Workload frequency/effect and NULL-queue output contract. | passed |
| [CBRD-27268](../../issues/CBRD-27268-dwb-size-unit-syntax_f6cac31_codex.md) | Requested size-unit capability preserved; parser, range, rounding and output constraints verified. | Final syntax/type/output contract, runtime and consumer compatibility. | passed |
| [CBRD-27269](../../issues/CBRD-27269-dead-code-comments_f6cac31_codex.md) | All nine candidate groups rechecked across full commit; false merge dependency removed. | External consumers and validation after concrete changes. | passed |
| [CBRD-27270](../../issues/CBRD-27270-recovery-temp-volume-survey_f6cac31_codex.md) | Recovery lifecycle/mount claims corrected; real metadata and marker paths preserved. | Encrypted temporary payload access, runtime consequences and safety conclusion. | passed |
| [CBRD-27316](../../issues/CBRD-27316-parallel-fix-private-lru-survey_f6cac31_codex.md) | Empty live body rebuilt as bounded concurrent fix/private-LRU victim-pattern survey. | Original motivation/execution path, workload, costs and improvement need. | passed |
| [CBRD-27356](../../issues/CBRD-27356-page-latch-timeout-policy_f6cac31_codex.md) | Current override/error contract and attributed debug-abort evidence rebuilt. | Current debug/release reproduction; environment, policy and affected versions. | passed |
| [CBRD-27370](../../issues/CBRD-27370-nested-read-write-accounting_f6cac31_codex.md) | BCB/holder accounting and historical raw logs verified; API policy left open. | Promotion contract, SQL/concurrent reachability and current runtime. | passed |
| [CBRD-27398](../../issues/CBRD-27398-page-buffer-overlay_f6cac31_codex.md) | Actual subsequent overlay decisions recovered; Draft and baseline separated. | 100ms/1500ms traversal decision, platform and release/performance evidence. | passed |
| [CBRD-27423](../../issues/CBRD-27423-performance-analysis-framework_f6cac31_codex.md) | Real-engine comparison requirement preserved; proposals/measurements/gates separated. | First workload/environment, assets, metrics and implementation boundary. | passed |
| [CBRD-27630](../../issues/CBRD-27630-simple-fix-loading-cleanup_f6cac31_codex.md) | Cleanup ownership verified; pinned Lean/source identity and model limits preserved. | Same-VPID concurrent cold miss, natural failure/scheduling and release scope. | passed |

## Classification and metadata

Live JIRA types remain unchanged. The following are technical classifications for triage; they are not proposed field mutations. No title, key, hierarchy, status, assignee, priority or issue-type update is included.

| Issue | Live type/status | Technical classification | Problem categories | Components |
| --- | --- | --- | --- | --- |
| CBRD-27193 | Development Subject / Open | Development Subject (umbrella development scope; retain live type) | Correctness, Reliability / recovery, Operability / observability, Performance, Maintainability, Test quality | Page buffer, Storage and recovery integration |
| CBRD-27194 | Sub-task / Confirmed | Sub-task (Correct Error technical category) | Reliability / recovery, Maintainability, Compatibility | Page buffer initialization/finalization, Transaction-table cleanup |
| CBRD-27196 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Performance / resource efficiency | Page buffer, B-tree |
| CBRD-27211 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Performance / resource efficiency | Page buffer direct-victim waiting-thread selection |
| CBRD-27252 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Compatibility / migration, Maintainability, Test quality | Page buffer, Build/test integration |
| CBRD-27262 | Sub-task / Confirmed | Sub-task (Correct Error technical category) | Reliability / recovery, Correctness / data integrity | Page buffer, TDE/DWB interfaces |
| CBRD-27263 | Sub-task / Confirmed | Sub-task (Correct Error technical category) | Correctness / data integrity, Reliability / recovery, Test quality | Page buffer, Heap, Vacuum |
| CBRD-27264 | Sub-task / Open | Sub-task (Correct Error technical category) | Reliability / recovery, Investigation / feasibility | Buffer Pool, SM |
| CBRD-27265 | Sub-task / Open | Sub-task (Correct Error technical category) | Build / CI / developer tooling, Operability / observability, Test quality | Storage / Page buffer diagnostics |
| CBRD-27266 | Sub-task / Open | Sub-task (Improve Function/Performance technical category) | Operability / observability, Documentation / specification consistency | Page buffer, Perfmon/statdump, DWB, SHOW |
| CBRD-27267 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Performance / resource efficiency, Operability / observability | Page buffer private-LRU index queues |
| CBRD-27268 | Sub-task / Open | Sub-task (Improve Function/Performance technical category) | Usability, Operability / observability, Compatibility, Documentation / specification consistency | System parameters, DWB, Server initialization |
| CBRD-27269 | Sub-task / Open | Sub-task (Refactoring technical category) | Maintainability / technical debt, Documentation / specification consistency | Page buffer |
| CBRD-27270 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Reliability / recovery, Documentation / specification consistency | Page buffer, Disk manager, Boot/log recovery, TDE/DWB |
| CBRD-27316 | Sub-task / Open | Sub-task (Investigation / feasibility technical category) | Investigation / feasibility, Performance / resource efficiency | Storage / Page buffer |
| CBRD-27356 | Sub-task / Open | Sub-task (Correct Error technical category) | Reliability / recovery, Compatibility, Maintainability, Investigation / feasibility | Page buffer, Transaction/lock, Vacuum/postpone validation |
| CBRD-27370 | Sub-task / Confirmed | Sub-task (Correct Error technical category) | Correctness / data integrity, Regression, Reliability, API contract | Page buffer |
| CBRD-27398 | Sub-task / Open | Sub-task (Development Subject technical category) | Operability / observability, Compatibility | Page buffer, System parameters, Server lifecycle |
| CBRD-27423 | Sub-task / Open | Sub-task (Development Subject technical category) | Performance, Test quality, Operability / observability, Investigation / feasibility | Page buffer, Test/benchmark tooling |
| CBRD-27630 | Sub-task / Confirmed | Sub-task (Correct Error technical category) | Reliability / recovery, Correctness / data integrity | Page buffer, Loading-record management |

## Review evidence

- [Discovery and source identity](discovery.md): recursive hierarchy checks, supporting issues and evidence revisions.
- [Shared writer brief](shared-brief.md): source baseline, terminology, parent objective and child boundaries.
- [Cross-issue review](cross-issue-review.md): corrected claims, ownership and dependency decisions.
- [All opening triage blocks](triage-summary.md): the reviewed four-field summaries together.
- [Verification and publication plan](verification.md): artifact checks, payload identity, limitations and approved-operation boundary.
- [Manifest](manifest.json): exact writers, paths, live metadata, review and per-issue publication status.
- [Original outlines](original-outlines.json): original titles and heading context, separate from rewritten descriptions.
- [Snapshot fingerprints](snapshot-fingerprints.json): identity of cached live descriptions/comments and claim inventories.

## Original-claim accounting

Each JSON below contains the original paragraph/table/code units, the writer's grouped disposition, evidence and the orchestrator's reviewed report hash. A mixed unit is corrected if any material subclaim changes. Formatting/reference-only units are identified separately. Original titles and headings are retained in the outline record; technical assertions are considered with their associated body groups. The original local reports remain unchanged at their historical paths.

| Issue audit | Units | Disposition groups |
| --- | --- | --- |
| [CBRD-27193](claim-audit/CBRD-27193.json) | 119 | 38 |
| [CBRD-27194](claim-audit/CBRD-27194.json) | 74 | 32 |
| [CBRD-27196](claim-audit/CBRD-27196.json) | 133 | 30 |
| [CBRD-27211](claim-audit/CBRD-27211.json) | 68 | 18 |
| [CBRD-27252](claim-audit/CBRD-27252.json) | 90 | 37 |
| [CBRD-27262](claim-audit/CBRD-27262.json) | 97 | 15 |
| [CBRD-27263](claim-audit/CBRD-27263.json) | 116 | 37 |
| [CBRD-27264](claim-audit/CBRD-27264.json) | 67 | 15 |
| [CBRD-27265](claim-audit/CBRD-27265.json) | 67 | 28 |
| [CBRD-27266](claim-audit/CBRD-27266.json) | 92 | 26 |
| [CBRD-27267](claim-audit/CBRD-27267.json) | 93 | 39 |
| [CBRD-27268](claim-audit/CBRD-27268.json) | 96 | 23 |
| [CBRD-27269](claim-audit/CBRD-27269.json) | 75 | 38 |
| [CBRD-27270](claim-audit/CBRD-27270.json) | 111 | 26 |
| [CBRD-27316](claim-audit/CBRD-27316.json) | 2 | 2 |
| [CBRD-27356](claim-audit/CBRD-27356.json) | 92 | 17 |
| [CBRD-27370](claim-audit/CBRD-27370.json) | 84 | 15 |
| [CBRD-27398](claim-audit/CBRD-27398.json) | 36 | 9 |
| [CBRD-27423](claim-audit/CBRD-27423.json) | 93 | 17 |
| [CBRD-27630](claim-audit/CBRD-27630.json) | 96 | 21 |

Total original units: **1701**. Dispositions: corrected 1016, non-substantive 246, removed 111, retained 328. Supplemental title/scope groups are retained separately. CBRD-27194 also has five screenshot claims in four attachment groups; these are counted separately from the original body units.
