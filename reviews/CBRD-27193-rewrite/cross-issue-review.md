# Cross-issue reconciliation

This is the orchestrator's review record, outside the descriptions. Current-behavior baseline: CUBRID f6cac312310f39f46711693da157a08f0e725693. Historical experiments retain their own builds.

## Ownership and terminology

- CBRD-27211 selects the high/low-priority **waiting thread** that receives a direct victim. Its global selector invocation counter is not per-thread polling, elapsed time, a fixed actual allocation ratio, or a maximum-wait guarantee.
- CBRD-27264 concerns the unreachable maintenance/emergency **supply** path. Its existing Duplicate link to supporting CBRD-24029 requires one repair/result ownership decision. CBRD-24029 is not a descendant or publication target.
- CBRD-27267 concerns initial registration/re-registration and consumption of **private LRU indices**. A producer exists after ordinary-private consumption; restricted callers can re-register a seeded big queue. It is not an always-empty dead queue.
- CBRD-27316 surveys parallel fix/private-LRU victim patterns more broadly; it must not absorb the three narrower ownership boundaries above.
- CBRD-27263 concerns request-page deallocation-protection ownership. CBRD-27370 concerns BCB/holder outstanding fix accounting. CBRD-27630 concerns loading-record cleanup ownership. Similar counter/fix terminology does not make these the same defect.
- Page latch and transaction lock are distinct. Dirty, LSA, flush staging, file writes, eviction and transaction commit are distinct events.

## Evidence corrections that apply across reports

- CBRD-27262 first-entry preparation failures precede LSA save/reset, but DWB-disabled retries can re-enter after that transition. Ordinary nonwaiting slot unavailability is NO_ERROR/NULL. DWB read has no normal nonzero return; a defensive error branch is not a demonstrated operating failure.
- CBRD-27263's historical pre-CAS logs do not prove an exact count of successful live-owner decrements. VPID aggregates do not preserve BCB residency identity. Counter reset/replacement limits remain separate from request-owned accounting.
- CBRD-27370's historical debug/release logs establish their specific direct-API behavior; they do not establish current SQL reachability. The negative unfix candidate is local and is not stored before the error branch exits. General READ-to-WRITE permission remains an API decision.
- CBRD-27356 retains the attributed September 29 debug-abort report, current thread-local overrides, local force-wait exceptions and latch-refusal taxonomy. It must preserve intentional nonblocking callers while analyzing unexpected refusal in commit/postpone cleanup.
- CBRD-27194 preserves the initialization defects and partial-failure lifetime audit while correcting the claimed AOUT startup reproduction: parameter tuning forces AOUT off. Zero-private allocation also occurs in normal SA initialization.
- CBRD-27196 uses current B-tree split/merge paths. Historical nonunique linear-overflow examples changed with the OID directory. Historical summary 89587 versus raw 887 and source-versus-executable identities cannot support a 4.4-promotions-per-insert performance argument. Existing snapshot/TDE/DWB flush does not require SX for correctness.
- CBRD-27266 preserves the merged SHOW deprecation contract: 9 columns return NULL. Num_data_page_iowrites aggregates page-unit writes at distinct DWB/origin sites; it is not syscall count, unique logical flush count, or an invariant 2x ratio. Inactive/NULL/missing values are not observed zero work. CBRD-27423 and all policy investigations use this distinction.
- CBRD-27398 preserves actual recorded Volmap decisions and subsequent amendments, not only the old issue draft. Current develop, Draft PR 7940, historical producer docs and consumer decisions have separate revisions. Accepted 100 ms traversal and Draft 1500 ms remain an explicit unresolved contract difference.

- CBRD-27265 distinguishes the optional CUBRID_DEBUG path from ordinary Debug/!NDEBUG behavior and the TDE-log gate. Enabling dormant diagnostics needs more than compile repair. In addition to the report's guard/watermark overlap, the writer handed off a separate source finding: `restart_lsa` is declared without initialization in `pgbuf_unfix`, then passed to `pgbuf_set_lsa` at the warning branch (current page_buffer.c:3009,3061). The orchestrator independently checked these lines. This is a follow-up boundary concern, not a runtime result or a silently added third defect in the two-defect assignment.
- CBRD-27268 confirms that current DWB size parsing rejects suffixes such as 2M/512K/600K. Current-behavior reproductions must use byte integers; the requested new syntax belongs to the desired outcome. DWB rounding changes a local applied value, so paramdump alone cannot verify applied size.
- CBRD-27269 retains all nine verified candidate groups, distinguishes conditional final own-private retry and Linux-only warning settings, and treats behavior preservation as a validation obligation rather than a pre-tested guarantee. Shared flush-file proximity does not prove a required 27262-first merge order.
- CBRD-27270 corrects zero-initialization/phase and mounting assumptions: log_global's constructor starts in recovery analysis, page-buffer bootstrap/reuse precedes the old narrative, temporary-voltype volumes are skipped at bootstrap, and permanent-type/temp-purpose metadata paths are reachable. Explicit temporary-LSA stamping protects some paths; encrypted payload harm remains unverified.
- CBRD-27630's pinned historical source hashes and bundled function crop match ea57708 source objects. This does not mechanically validate the model-to-C++ correspondence, which remains manual.

- CBRD-27316 had no original description or comments. Its bounded investigation is explicitly proposed from the title and parent context, without claiming an observed regression, a new parallel API, or an agreed workload.
- The sole scoped attachment, CBRD-27194 attachment 1020015, repeats historical sizeof/reinitialization analysis. It has no runtime log. Its claims were reviewed separately; static initialization and finalizer behavior prevent treating it as proof of a guaranteed crash.

## Decisions and dependencies

M0-M8 learning proposals are not an approved product-v2 design. Default/v2 selection/comparison/rollback capability remains CBRD-27252's requested strategy outcome. SX adoption, queue restore/remove choices, timeout values/APIs, benchmark tools/thresholds and CI scheduling remain ANALYSIS unless an actual decision is cited.

The parent's comments request considering TPC-H 27188/27191, unit-test support and bottleneck workloads. They are not performance results, an adopted framework, or a promise that every child must wait for CBRD-27423. Shared metrics/workloads are information-sharing; any real prerequisite must name the missing capability and dependent result. No blanket child-to-framework, SX-to-v2, timeout-to-accounting, or flush-to-cleanup merge-order edge is accepted.

Investigation outcomes may recommend adoption, keeping current behavior, no demonstrated defect, deferral with specific missing evidence, or scoped follow-up implementation. They must preserve the unmet capability and make remaining work visible. Parent completion accounts for all 19 children and their explicit dispositions, without treating every survey as a mandatory code change.

## Review completion

The manifest records each dedicated writer and the orchestrator's per-report review. Every published body is reviewed in full. Original-claim group dispositions are retained separately in claim-audit. Artifact and converted-payload checks are recorded in the final verification report. Metadata recommendations remain outside description updates.
