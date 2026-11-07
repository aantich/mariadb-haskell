# Stage 1 first code review — 7 November 2026

**Historical first-pass record.** The [second review](STAGE1_CODE_REVIEW_2.md) records later findings and validation. These first-pass measurements retain their original fingerprint; the [live report](../validation/RESULTS.md) describes current inputs. All changes remain uncommitted.

The review covered the entire uncommitted implementation: connection/transaction ownership, packet framing, text/binary codecs, SQL rendering, TLS/socket adapters, replication integration, added fixtures, Python validation/publication tools, Cabal/Nix changes and documentation. Generated evidence was checked for parseability, reference provenance, immutable workload inputs and accidental credential inclusion. Historical experiments retain their own source fingerprints and validity labels.

## Defects found and fixed

| Priority | Finding and consequence | Correction and regression coverage |
| --- | --- | --- |
| P1 | An earlier command could finish or abort a successor after publishing Ready. Its finalizer checked only the current phase, so another thread could already own a new command. Exchange-local references were also cleared after Ready became visible. | [Connection lifecycle](../src/Database/MySQL/Connection.hs#L269) publishes Ready last and checks generation in command/stream finalizers. `ownership.completed-command-does-not-finish-successor` holds the successor in its writer and exercises both successful and exceptional unwinding. It failed before the fix. |
| P1 | Stream construction could overwrite a concurrent Closed state with Streaming/Replicating. That violated terminal-state ownership and could expose a stream on an already released transport. | [Stream transition](../src/Database/MySQL/Connection.hs#L319) requires Executing atomically. `ownership.closed-cannot-become-streaming` failed before the fix. Both ordinary and replication streams use this transition. |
| P1 | `executeMany` joined statements directly with `;`. A template ending in `-- comment` or `# comment` could swallow the separator and later statements, silently executing only part of the batch. | [Batch builder](../src/Database/MySQL/Base.hs#L139) ends the line before inserting the separator. `parameters.batch-trailing-line-comment` checks both forms, both affected-row replies and the actual inserted sum. It failed before the fix. |
| P2 | Transport retirement caught every exception from the finalizer, including a new cancellation. The caller could lose ThreadKilled/timeout while cleanup claimed to have completed. | Retirement still suppresses ordinary secondary close failures, but propagates new cancellation after marking the connection terminal. `cleanup.transport-cancellation-propagates` failed before the fix; existing rollback deadline and second-cancellation checks remain. |
| P2 | Replication setup claimed ownership without the command failure boundary. A setup ERR left Replicating and an open transport. Its returned stream also bypassed generation/thread guards, and its logical reader used the default rather than configured message limit. | [Replication adapter](../src/Database/MySQL/BinLog.hs#L76) uses `withCommand`, a guarded replication stream and `readConnPacket`; clean EOF closes the dedicated connection and repeated EOF remains safe. `replication.setup-error-retires` failed before the fix. This repairs lifecycle integration; existing CDC decoding failures remain visible. |
| P2 | Session refresh decoded its row permissively and could force malformed UTF-8 after releasing command ownership. Wrong snapshot shape or trailing bytes could therefore escape connection retirement. | [Snapshot reader](../src/Database/MySQL/Connection.hs#L866) checks six columns, exact consumption and string value types, forcing decoded bytes within the guarded exchange. `session.malformed-snapshot-retires` checks wrong shape, trailing data and invalid UTF-8; it failed before the fix. |
| P2 | Binary TIME converted unsigned microseconds to Int before validation. On 32-bit hosts a large Word32 could become negative, pass the upper-bound check and produce an invalid fractional time. | [TIME decoder](../src/Database/MySQL/Protocol/MySQLValue.hs#L406) validates Word32 before conversion. `values.binary-time-microseconds-bounds` checks the last valid value and three invalid values, including both high-bit boundaries. The portability defect was found by source analysis; this Mac cannot reproduce 32-bit Int execution. |

Development reproductions are retained as raw, explicitly partial evidence: [batch/cancellation/replication](../validation/results/references/review-repro-all.json), [ownership handoff](../validation/results/references/review-repro-handoff.json) and [snapshot boundary](../validation/results/references/review-repro-snapshot.json). They are not complete benchmark references. Full final runs verify the resulting implementation separately.

## Validation and publication fixes

- The real fault proxy updated one statistics record from two threads with non-atomic read/modify/write. A packet increment could overwrite a command count, undermining the command-count assertions. Updates are now atomic. Worker creation/cleanup uses bracket/mask boundaries so cancellation between forks cannot leak a worker; invalid fragment sizes are rejected.
- Performance comparability now includes the installed Connector/C version in both publication and acceptance checks. A changed native control must not be presented as a comparable speed result. New policy tests cover this.
- A newly completed run no longer inherits an old acceptance object. A damaged acceptance reference produces a visible failed attempt while preserving the raw candidate, rather than crashing before updating live status. New tests cover both paths.
- The colored graphic identifies an uncommitted working-tree fingerprint instead of labeling the parent commit as the measured implementation. Confirmation/supplementary links explicitly identify historical evidence when their input hashes differ.
- The focused/supplementary Python tools now use readable layout, named intermediate values and comments explaining measurement boundaries. Positive repetition counts are required; fresh-build and stable-source checks remain mandatory.
- Cabal's description and project/issue URLs now identify this MariaDB fork, with upstream authorship retained. Migration/review documents are included in source-distribution documentation. Nix still targets MariaDB; its removed MySQL-server target is not restored.

## Haskell readability and comments

The code needed better explanation of invariants and less compressed layout. The changes now include:

- Haddock for connection limits, statuses/errors, query/stream lifetimes, batching/materialization, prepared statements, transactions, rendering contexts and raw date values.
- Comments at the actual cancellation, final-status, generation handoff, SQL quote/comment, session snapshot and packet-consumption boundaries. These explain why a rule exists and what breaks if it changes.
- Named, documented QueryPlan fields explain the safety flags; record-based connection construction replaces a long positional list of same-typed references.
- Ordinary layout for the routine-admission list, quoting cases and decimal validation; standard `intersperse`/`isSuffixOf` replace handwritten list helpers. The executable-comment version is accumulated directly from bytes without `read . unpack`.
- Separate transport module qualifiers, unused-binding/import cleanup and explicit numeric types where defaulting hid intent.
- Comments preserving the performance rationale for shared per-result parsers, forcing values at the I/O boundary, all-zero NULL plans, bounded lazy encodings, shared framing states and immutable adaptive receive buffers.

Mutable references are appropriate for this connection's I/O state machine. The important improvement is to make ownership transitions explicit and keep pure parsing/rendering checked and composable. Rewriting the hot row loops solely to look more abstract would need allocation/throughput evidence.

Your public-project comment standard is now a persistent instruction in [AGENTS.md](../AGENTS.md). Comments must describe public contracts and subtle invariants, remain accurate, and avoid narrating obvious expressions.

## Remaining issues and opportunities

1. **Performance acceptance remains open.** Review the entire final confirmation window, including native controls, rather than selecting the fastest run. Repeatable unexplained increases above 5% still require investigation or an explicit tradeoff decision. The last accepted reference has not advanced.
2. **Opaque prepared-statement bookkeeping is a bounded list.** Lookup/removal/registry-size checks are O(n) in the number of open opaque statements. Ordinary prepared statements do not populate this list. Before optimizing it, add a many-open-opaque-statements workload; an IntSet or another keyed structure could reduce that scaling cost. It is not justified by the current empty-registry microbenchmarks alone.
3. **The SQL classifier remains intentionally conservative.** Its allowed routine/type tokens are not a complete MariaDB grammar. Keep admission rules and safety tests together when adding syntax; unknown context-changing constructs must not be admitted simply because they start with INSERT/SELECT.
4. **Connection internals remain an exposed internal interface.** Base exports the abstract connection, but Connection exposes transport/testing internals that can bypass invariants. The migration guide documents that boundary. An explicit stable export surface belongs in a later API cleanup.
5. **Platform and feature gaps remain visible.** This review does not resolve the existing 33 failures: 16 CDC, nine authentication, four protocol/auth capability, two connection setup, one prepared-OUT and one timeout-reuse policy case. Linux, Windows, Nix and 32-bit execution still need their own profiles. The 11 unsupported APIs and two unavailable authentication fixtures remain distinct from passing tests.

## Final review validation

The final source fingerprint and full confirmation results are recorded in [first-review confirmation window](../validation/results/experiments/review1-confirmation-window.json). The window was declared before measurement; all three runs are retained and the third supplies the live report. The earlier one-run review window was superseded after the portable TIME fix and final metadata/import cleanup, with its reason and measurements preserved. No run was selected because it was faster.

All three final runs tested input fingerprint `ce4d625e18e6a8efcf1be5a35f8e129fa6d85e78f9ea31ce021931d0da63f09c`. Each recorded **346 PASS / 33 FAIL / 11 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE**, across **392 records**. All **77 added cases** and all **23 original Stage 1 targets** pass. Every original/accepted pass is preserved; both inherited suites pass (179 unit/property cases, including the existing external-HTTPS ignore, and 32 integration cases).

All **24 runnable frozen profiles** completed seven process repetitions in each run: **21 samples per profile** across the window. All three runs pass the original comparison policy and allocation gates against both references. The **35 Python policy tests** pass. Current-source report freshness, frozen-workload diffs, original baseline checksums and accepted-reference hashes pass. The accepted reference is unchanged.

The table uses the median of all three run medians. Negative change means less time per unit; no fastest-run selection is used.

| Frozen workload | Unit | Baseline ns/unit | Current window ns/unit | Change vs baseline |
| --- | --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | row | 9,670.00 | 8,016.00 | -17.1% |
| `haskell/read.text.wide` | row | 2,876.43 | 2,750.83 | -4.4% |
| `haskell/read.prepared.wide` | row | 2,425.07 | 2,328.17 | -4.0% |
| `haskell/read.vector.narrow` | row | 365.84 | 344.44 | -5.8% |
| `haskell/micro.text-row` | decoded row | 313.24 | 285.56 | -8.8% |
| `haskell/read.text.narrow` | row | 305.48 | 323.36 | +5.9% |
| `haskell/write.text` | row | 38,324.00 | 41,827.00 | +9.1% |

Batch allocation is **-59.0%** versus the original baseline. Wide text/prepared and vector scan allocation remains materially lower. Text narrow reads allocate roughly eight additional bytes per row versus the pre-review third run after adding generation-safe exception handling; this is below the 5% gate, but should remain visible when profiling ownership overhead.

Repeatable timing signals across **every** final run:

| Reference | Workload | Range above reference |
| --- | --- | ---: |
| accepted | `haskell/read.parallel-4` | +19.8% to +30.5% |
| original | `connector-c/read.text.narrow` | +6.1% to +7.9% |
| original | `haskell/read.text.narrow` | +5.1% to +6.1% |
| original | `haskell/write.text` | +9.0% to +9.6% |

These remain unresolved performance findings. The four-reader increase is substantial against the last accepted reference; it is not waived by the older baseline's different result. Native C narrow reads also moved, which shows environment variability but does not establish that every Haskell increase is environmental. The review does not attribute the timing changes to a particular patch without a controlled comparison.

All changes remain unstaged and uncommitted. No push, PR, merge or publication to main was performed.

## Comment/documentation and supplementary verification

`cabal haddock lib:mysql-haskell --haddock-internal -O2` succeeds. Haddock reports **91%** symbol documentation for Base, **100%** for the public TLS module and **88%** for MySQLValue. The [build log](../validation/results/experiments/review-haddock.log) retains the remaining missing-symbol/ambiguous-link warnings. There is still documentation debt around inherited exception types, the abstract connection declaration and internal helpers; this pass does not claim 100% package-wide coverage.

The [current supplementary evidence](../validation/results/references/stage1-review-after-final.json) was captured with the same final input fingerprint and seven repetitions per profile. The following uses the original six-profile supplementary reference, separately from the frozen benchmarks above.

| Supplementary workload | Unit | Baseline ns/unit | Current ns/unit | Change vs baseline |
| --- | --- | ---: | ---: | ---: |
| `connect.tcp` | connection | 177,466.67 | 265,366.67 | +49.5% |
| `parameters.select` | operation | 37,064.00 | 40,260.00 | +8.6% |
| `parameters.mixed` | operation | 75,894.00 | 80,180.00 | +5.6% |
| `transaction.empty` | operation | 63,173.33 | 70,973.33 | +12.3% |
| `batch.1000` | row | 11,008.60 | 9,788.60 | -11.1% |
| `stream.retention` | row | 351.03 | 351.56 | +0.2% |

Connection setup includes the intentional tracker/snapshot exchanges. Its extra latency, and the parameter/transaction-helper costs, remain visible performance tradeoffs rather than being hidden by faster batch/scan results.

| Current retention experiment | Median final live bytes | Maximum checkpoint live bytes |
| --- | ---: | ---: |
| `retention.10000` | 127,664 | 131,688 |
| `retention.1000000` | 127,728 | 149,704 |
| `retention.tiny-slice` | 115,576 | 117,376 |

These are live-heap observations after GC. They do not substitute process high-water figures for retention, or invent a missing pre-change memory baseline.
