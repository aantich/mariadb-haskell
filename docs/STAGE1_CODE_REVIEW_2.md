# Stage 1 — second code review, 7 November 2026

**Historical second-pass review measurements.** These fixes were uncommitted when reviewed and measured. Anton subsequently authorized committing and pushing them on 7 November 2026, with the remaining performance work postponed. The [live results](../validation/RESULTS.md) record the fresh committed-input publication run. This pass concentrates on SQL classification, startup facts, batch boundaries and whether the validation machinery can incorrectly accept a candidate. The [first review](STAGE1_CODE_REVIEW.md) remains a historical record.

## Additional findings and fixes

| Priority | Finding | Fix and evidence |
| --- | --- | --- |
| P1 | Active executable comments hid session-changing SQL from the context-effect classifier. For example, `/*M! SET session_track_system_variables='' */` disabled tracking while the driver continued trusting its cached context. Raw, prepared and text-bound execution were affected. | Active executable comments now make execution opaque. Preparing alone still has no session effect. Three live regression cases reproduced the defect before the fix; all now require explicit refresh after execution. Inactive comments preserve known context. |
| P2 | The comment lexer rejected ordinary numeric comments and valid seven-digit prefixes, and did not handle the nested ordinary comment allowed inside an ignored version comment. It consumed an arbitrary run of digits instead of MariaDB's five/six-digit version prefix. | Placeholder scanning and context classification now share the same comment-prefix rules. Five/six version digits are consumed; a seventh remains SQL; fewer than five are ordinary executable content. Skipped version comments tolerate the server's one level of nested ordinary comments. Live value checks and the prepared-statement oracle cover these rules. |
| P2 | The renderer interpreted reversed-looking executable comments without implementing their conditional semantics. The checked-out server main has that newer grammar, while the installed 12.3.3 behaves differently. | Both `/*!!...*/` and `/*M!!...*/` are explicitly rejected by parameter rendering before any bytes are sent. Raw SQL retains server-controlled pass-through. This is a documented support gap, not a claim that reversed comments are implemented. |
| P2 | A valid parameter-batch template ending in `;` gained a second separator. MariaDB could execute the first insert and then reject the batch. | The compiled plan records whether the last visible SQL token is already a delimiter. Joining ends a trailing line comment and adds a separator only when needed. Tests cover a final delimiter, line comments and a semicolon inside a block comment. Every actual server OK is retained. |
| P2 | Startup snapshots lacked the tracker's 4 KiB fact bound; invalid versions became zero; packet-limit validation happened after command ownership was released; an unexpected MORE_RESULTS flag could publish Ready with replies pending. | Snapshot rows respect the metadata budget. Individual facts are bounded and copied into owned storage. Version/limit validation and terminal-flag checks occur inside the exchange; malformed facts retire the connection. The snapshot and tracker paths share one named fact-size limit. |
| P2 | Acceptance could silently expand the deferred failure set: an existing UNSUPPORTED or ENVIRONMENT_UNAVAILABLE ID could become FAIL/TIMEOUT. New failed benchmarks and removed benchmark inventory could also pass the gate. | Only original failing IDs belong to the deferred set. Unknown statuses, new benchmark failures and missing benchmark IDs are rejected. Original and accepted PASS protection remains in place. New policy tests demonstrate these failures without changing the original recorder. |
| P2 | Deleting the accepted-reference manifest disabled the ratchet. Reference metadata could disagree about the tested commit or point at live current results. A recorded fingerprint could disagree with its actual input snapshot. | Normal full candidates require the accepted manifest. Its hash, path and tested commit are checked; live current results cannot serve as their own reference. Publication verifies the fingerprint as well as individual input files. Initial immutable baseline capture retains its separate workflow. |
| P2 | Failure to launch the build/recorder, malformed recorder JSON, or interruption during build/suite execution could leave an older successful attempt looking current. | Those paths record a failed attempt, retain clearly labeled older complete results and preserve raw candidate files. Interruption exits with status 130. Mocked process tests exercise the actual wrapper entry point. |

The pre-fix [driver reproduction](../validation/results/references/review2-repro.json) records seven failing new cases on stable inputs. The [batch reproduction](../validation/results/references/review2-parameter-check.json) records the doubled-delimiter SQL error. These are partial development runs, separate from final measurement.

## Independent checks and test corrections

The prepared-statement oracle uses MariaDB's own parameter count and actual binary execution as the reference for text rendering. It checks **13 templates under four SQL modes**, including literals, identifiers, line/block comments, short and long numeric comment prefixes, ignored-version bodies and nested skipped comments. It normalizes integer wire widths while keeping text, bytes and NULL distinct. It explicitly refreshes after opaque execution; the driver does not insert hidden probes.

An early version of that test omitted the explicit refresh after deliberately opaque execution and correctly encountered SessionContextUnavailable. The fixture was corrected; its count/value assertions remain intact.

The first trailing-delimiter test also assumed exactly one OK per parameter set. Independent [Connector/C source](../validation/results/experiments/review2-native-batch-probe.py.txt) and [observations](../validation/results/experiments/review2-native-batch-shape.txt) establish the actual server behavior:

| Template ending | Native affected-row replies for two inserts |
| --- | --- |
| `;` | `[1, 1]` |
| `; -- final comment` | `[1, 1, 0]` |
| `; # final comment` | `[1, 1, 0]` |
| `/* semicolon ; */` | `[1, 1]` |

The assertions now require those exact native replies and independently verify that both inserted values are present. The driver does not drop the final comment-only OK to manufacture a desired result count.

Repeated tracker configuration was checked separately against MariaDB: the selection length grew from 101 to 141 bytes on first extension, then remained 141 through repeated refreshes. MariaDB deduplicates this setting; no extra client-side normalization query or speculative optimization was added.

## Haskell and comment quality

Both QueryPlan construction paths now use named record fields, including the batch-delimiter fact. Snapshot version, size and ownership rules are documented where they are enforced. The test helper drains an accidental successful query before reporting an expected-rejection failure, so bracket cleanup cannot mask the original assertion with UnconsumedResultSet.

Haddock now reports **100% symbol documentation for Base (70/70), MySQLValue (26/26) and TLS (6/6)**. The abstract connection and inherited public exception types have explicit contracts; low-level permissive/exact parsing and fixed column metadata also have clearer explanations. This does not claim that all inherited protocol constants and every internal helper in the package are documented. [Haddock log](../validation/results/experiments/review2-haddock.log).

## Final verification

The [second-review confirmation window](../validation/results/stage1-confirmation.json) was declared before measurement. It retains all three full runs, uses the third as current, and separately preserves the [first-review window](../validation/results/experiments/review1-confirmation-window.json). Original and last-accepted references are unchanged. Every first-review PASS must also remain passing.

All three runs used input fingerprint `835058eb17a5c841fc1e038764a295c70aac439e8ae5bd09ed11dbd79c50cce8` against MariaDB 12.3.3 on this Mac. Each completed with **357 PASS / 33 FAIL / 11 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE**, across **403 records**. All **88 added Stage 1 cases pass**, including the 52 prepared/text lexer comparisons inside their parity case. All **346 first-review PASS records**, every original PASS and every last-accepted PASS remain passing. The 23 original targeted failures remain fixed.

All **24 runnable frozen benchmark profiles** complete with seven measured repetitions in each run, retaining 21 process samples per profile across the window. The live document publishes the third run. The **51 Python runner/publication/acceptance tests** pass. Freshness, generated-report consistency, frozen-baseline checksums, unchanged-workload diffs and whitespace checks pass. No commit or push was made.

### Complete-window performance

These tables use the median of all three run medians. Baseline always means the original immutable unchanged-driver measurement. Negative change means less time or allocation; every run remains in the window evidence.

| Workload | Baseline ns/unit | Current window ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | 9,670.00 | 8,021.00 | -17.1% |
| `haskell/read.text.wide` | 2,876.43 | 2,694.27 | -6.3% |
| `haskell/read.prepared.wide` | 2,425.07 | 2,339.27 | -3.5% |
| `haskell/read.vector.narrow` | 365.84 | 345.58 | -5.5% |
| `haskell/micro.text-row` | 313.24 | 286.58 | -8.5% |
| `haskell/read.text.narrow` | 305.48 | 325.78 | +6.6% |
| `haskell/write.text` | 38,324.00 | 41,509.00 | +8.3% |

| Workload | Baseline bytes/unit | Current window bytes/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | 20,261.29 | 8,321.37 | -58.9% |
| `haskell/read.text.wide` | 30,532.35 | 25,994.24 | -14.9% |
| `haskell/read.prepared.wide` | 24,469.57 | 22,677.79 | -7.3% |
| `haskell/read.vector.narrow` | 3,136.04 | 2,352.50 | -25.0% |
| `haskell/micro.text-row` | 2,952.02 | 2,448.02 | -17.1% |
| `haskell/read.text.narrow` | 2,831.95 | 2,232.95 | -21.2% |
| `haskell/write.text` | 43,608.14 | 32,706.33 | -25.0% |

There are **no allocation alerts above 5%** against either reference in any of the three runs, and no unchanged original-policy regression alarms. Full performance acceptance remains **open**. The stricter 5% timing investigation signals repeated in every run are:

- `haskell/read.parallel-4` versus **accepted**: +8.9% to +18.5%.
- `haskell/read.text.narrow` versus **original**: +5.6% to +9.1%.
- `haskell/write.text` versus **original**: +8.0% to +8.8%.

Text latency and TLS narrow reads also exceed 5% in two runs. Native controls move between runs too; that helps diagnose variation but does not waive the driver signals or justify subtracting C timings. Every individual signal is retained in the window. The accepted reference has not been advanced.

### Supplementary setup and retention

The [final supplementary evidence](../validation/results/references/stage1-review2-after-final.json) uses the same final fingerprint and seven process repetitions per profile. Its separately recorded [unchanged-driver reference](../validation/results/references/stage1-before.json) remains distinct from the frozen benchmark baseline.

| Supplementary workload | Unit | Baseline ns/unit | Current ns/unit | Change vs baseline |
| --- | --- | ---: | ---: | ---: |
| `connect.tcp` | connection | 177,466.67 | 280,900.00 | +58.3% |
| `parameters.select` | operation | 37,064.00 | 41,300.00 | +11.4% |
| `parameters.mixed` | operation | 75,894.00 | 78,098.00 | +2.9% |
| `transaction.empty` | operation | 63,173.33 | 71,130.00 | +12.6% |
| `batch.1000` | row | 11,008.60 | 9,520.60 | -13.5% |
| `stream.retention` | row | 351.03 | 352.24 | +0.3% |

Startup still pays for the two deliberate setup exchanges. The larger setup, parameter-helper and empty-transaction costs remain explicit optimization work; they are not accepted automatically. Command-count tests continue to require no hidden discovery queries on ordinary calls.

These memory experiments measure current live heap after GC, separately from throughput timing and process high-water marks. They have no invented pre-change baseline.

| Retention experiment | Median final live bytes | Maximum checkpoint live bytes |
| --- | ---: | ---: |
| `retention.10000` | 129,528 | 131,752 |
| `retention.1000000` | 127,744 | 151,328 |
| `retention.tiny-slice` | 115,616 | 117,992 |

Increasing streamed rows from 10,000 to 1,000,000 does not produce proportional retained heap. Holding one exact byte from a 16 MiB result releases the large payload in the tested path. This supports those ownership contracts without claiming bounded retention for every consumer.


## Remaining boundaries

- Performance acceptance remains open after assessment of the complete window. Four-reader, narrow-read, text-write and supplementary setup/helper costs require further investigation.
- Reversed executable-comment rendering needs its own version-profile design and live verification before support is added. Raw pass-through is distinct from parameter-renderer support.
- The bounded opaque-statement registry still has linear lookup/removal, and the exposed internal connection interface still permits deliberate bypass of public invariants. Neither is refactored without a measured workload or API migration.
- The existing 33 deferred failures and 13 inventory entries remain visible. This Mac run does not validate Linux, Windows, Nix or 32-bit execution.
