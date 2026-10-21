# Publication results: CBRD-27193 and descendants

**20/20 descriptions published and verified on 2026-10-21.** The user approved integration, push and these exact description updates. The reviewed report commit `eb49303a8fc63cf57f680acf922211da945b6800` was successfully pushed to origin/main before the first live update. All 19 children were verified before publishing the parent.

For every issue, the orchestrator verified the live target and unchanged intake description, inspected a fresh dry-run from the surviving main-checkout report, confirmed the payload contained only `fields.description`, published through `cubrid-jira update --yes`, and fetched the live issue again. Every resulting description exactly matches its converted payload. No issue title or other protected metadata was changed.

| Live JIRA issue | Published report | Result |
| --- | --- | --- |
| [CBRD-27194](https://jira.cubrid.org/browse/CBRD-27194) | [Markdown](../../issues/CBRD-27194-initialization-finalization_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27196](https://jira.cubrid.org/browse/CBRD-27196) | [Markdown](../../issues/CBRD-27196-sx-latch-survey_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27211](https://jira.cubrid.org/browse/CBRD-27211) | [Markdown](../../issues/CBRD-27211-direct-victim-wait-policy_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27252](https://jira.cubrid.org/browse/CBRD-27252) | [Markdown](../../issues/CBRD-27252-parallel-v2-strategy_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27262](https://jira.cubrid.org/browse/CBRD-27262) | [Markdown](../../issues/CBRD-27262-flush-error-recovery_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27263](https://jira.cubrid.org/browse/CBRD-27263) | [Markdown](../../issues/CBRD-27263-deallocation-protection-accounting_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264) | [Markdown](../../issues/CBRD-27264-direct-victim-emergency-path_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27265](https://jira.cubrid.org/browse/CBRD-27265) | [Markdown](../../issues/CBRD-27265-debug-build-defects_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27266](https://jira.cubrid.org/browse/CBRD-27266) | [Markdown](../../issues/CBRD-27266-statistics-semantics_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267) | [Markdown](../../issues/CBRD-27267-big-private-victim-queue_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27268](https://jira.cubrid.org/browse/CBRD-27268) | [Markdown](../../issues/CBRD-27268-dwb-size-unit-syntax_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27269](https://jira.cubrid.org/browse/CBRD-27269) | [Markdown](../../issues/CBRD-27269-dead-code-comments_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27270](https://jira.cubrid.org/browse/CBRD-27270) | [Markdown](../../issues/CBRD-27270-recovery-temp-volume-survey_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27316](https://jira.cubrid.org/browse/CBRD-27316) | [Markdown](../../issues/CBRD-27316-parallel-fix-private-lru-survey_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27356](https://jira.cubrid.org/browse/CBRD-27356) | [Markdown](../../issues/CBRD-27356-page-latch-timeout-policy_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27370](https://jira.cubrid.org/browse/CBRD-27370) | [Markdown](../../issues/CBRD-27370-nested-read-write-accounting_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27398](https://jira.cubrid.org/browse/CBRD-27398) | [Markdown](../../issues/CBRD-27398-page-buffer-overlay_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423) | [Markdown](../../issues/CBRD-27423-performance-analysis-framework_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27630](https://jira.cubrid.org/browse/CBRD-27630) | [Markdown](../../issues/CBRD-27630-simple-fix-loading-cleanup_f6cac31_codex.md) | Published; exact live body and metadata verified |
| [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193) | [Markdown](../../issues/CBRD-27193-page-buffer-program_f6cac31_codex.md) | Published; exact live body and metadata verified |

The final unfiltered 20-issue read-back independently confirmed all 20 descriptions and protected fields, exactly 19 direct children and no deeper descendants. The protected set includes keys/IDs, titles, status, type, assignment, priority, parent/subtasks, components, labels, versions, resolution, reporter, project and ordinary issue links. Automatic `updated` timestamps are outside that comparison.

[Machine-readable publication evidence](publication-results.json) records per-issue stages, exact CLI results, source and converted/live description hashes, original-description hashes, and equal before/after/final metadata fingerprints. Raw before/after snapshots remain in the tool-owned cache identified by the manifest.

The first live update succeeded, but the orchestrator initially asserted a nonexistent `dry_run=false` field in the success response. The CLI returns `issue` and `updated_fields`; the check was corrected and the live result verified without a repeated PUT. All later success responses use that verified schema. This was a verification-script error, not a failed JIRA update.

The report bodies and reviewed source baseline are unchanged by publication accounting. Topic cleanup and work-tracker completion follow the successful accounting push and are recorded in the final handoff and work-tracker 466.
