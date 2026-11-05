# OOS candidate overlap and branch attribution review

The owner requests independent subagent checks of CBRD-27944 and CBRD-27945 against existing issues and develop. The outcome is a recommendation about keeping, consolidating or deleting the issues, two verified JIRA comments, and a list of decisions that remain with the owner.

## Workflow

Investigation playbook steps.

- [x] Route through the **how** skill. For motivation questions, also route through the **why** skill. Skip why because this request asks source attribution and tracking scope, not historical design motivation.
- [x] Throughput checkpoint stays one line: `throughput checkpoint: n/a, read-only investigation`.
- [x] Produce the `how`-shaped output (Overview / Key Concepts / How It Works / Where Things Live / Gotchas), or a recommendation with a tradeoffs table if the request is a decision between alternatives. The report uses the recommendation table.
- [ ] Apply the **unslop** skill to the reply.

Swarm steps.

- [x] Frame.
- [x] Fan out.
- [x] Aggregate.
- [ ] Report.

The scope is a source-and-issue investigation plus explicitly authorized comments. No engine code change, database reproduction, issue deletion or workflow transition is included. Actual DB reproduction remains behind team-lead approval.

throughput checkpoint: n/a, read-only investigation. Independent slices cover issue overlap, the rollback/hint path, and recursive metadata allocation. Each worker owns its scratch output. Root alone writes the persistent result and publishes comments after synthesis.

## Fixed source identities

- Original analyzed OOS source is `f67f2f692a7ad9f9efada2178759ca713e596b9d`.
- Fetched `origin/feature/oos-merge` is `d52b1889e907abcf84190ec504dde3bc93de260d`.
- Fetched `origin/develop` is `be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d`.

Read these objects through Git. Preserve the dirty local develop worktree. A missing OOS file alone cannot settle the generic file-manager question. Separate a shared allocation mechanism from an OOS-specific requirement and triggering path.

## Completion criteria

Each issue has a grounded overlap verdict, an exact-revision branch comparison, source or issue evidence, and a recommendation. Root checks disagreements rather than counting votes. Comment bodies use portable links and distinguish a source-supported candidate from a native reproduction. Each posted comment is read back and compared with its reviewed payload. Deletion, duplicate resolution and source fixes remain recommendations for the owner.
