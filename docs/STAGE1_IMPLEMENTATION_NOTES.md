# Stage 1 implementation and review notes

**Historical implementation evidence.** The [first review](STAGE1_CODE_REVIEW.md) and [latest review](STAGE1_CODE_REVIEW_2.md) record later fixes and their own validation windows. Those measurements used uncommitted inputs. Anton authorized publication on 7 November 2026 after both reviews, postponing the outstanding performance work. The [live results](../validation/RESULTS.md) describe the current committed-input publication run; the original and pre-Stage-1 accepted references remain unchanged.

Anton approved Version 2 on the night of 6–7 November 2026 and explicitly requested implementation without stopping, repeated checks/fixes, final tests/benchmarks and updated local results. He requested every change remain uncommitted for morning diff review. No commit or push is part of this run.

## Reference measurements

A fresh full unchanged-driver run completed before library edits, at `validation/results/runs/20261106T225356.992202Z/`. The original frozen baseline remains intact. The last accepted main result is separately preserved in `validation/results/references/pre-stage1.json`, with its hash in `validation/results/accepted.json`.

Supplementary measurements were captured against the unchanged driver after adding the separate diagnostic entry point: `validation/results/references/stage1-before.json`. These measure parameterized and mixed calls, transaction helpers, connection setup, batching and streaming. They do not replace any original benchmark or pretend to be part of its frozen reference.

## Native tracking characterization

MariaDB Connector/C was used directly against 12.3.3 to observe SQL-mode changes, SET NAMES, CALL with intermediate results/restored mode, and an error in a later statement. Observed SQL-mode notifications after CALL report the restored outer mode; the implementation still treats unknown/error state explicitly.

MariaDB aliases `collation_connection` and `character_set_connection` tracking entries. Keeping the existing session selections can therefore yield charset notifications without an exact collation notification. The context carries `Maybe` collation: charset notifications invalidate that fact rather than inventing a collation or issuing discovery SQL. Built-in quoted text rendering uses the verified encoding and the server's actual literal collation. A custom renderer requiring exact collation can demand an explicit refresh. Existing tracker selections, including `*`, are preserved.

Native Connector/C rejects CLIENT_DEPRECATE_EOF as a caller-supplied connection flag in this installed build. That probe therefore used its supported tracking interface; Haskell integration and independent packet fixtures cover negotiated OK result terminators directly. It was not reported as native-client verification of that flag.

## Implementation review corrections

Raw SQL and prepared statements carry an explicit context-effect policy. Ordinary tracked changes retain the fast path; opaque routines, raw multi-statements and changed tracking controls invalidate it only after the response completes. The lexer handles quoted and qualified tracking-variable names. A bounded registry records only opaque prepared statement IDs and releases them on close; it does not cache result metadata or parameter payloads. Preparing a statement does not execute its effects. Stable parameterized batches keep their already-compiled policy through internal helpers.

Tests exposed false routine classifications for table declarations and adjacent VALUES tuples. Tokenization now retains punctuation and recognizes table/type declarations. Those fixes restored existing behavior without weakening the ownership or unknown-context rules.

The proposed Oracle alternative-quote syntax was rejected by the real 12.3.3 server (`1054`, unknown column `q`); the checked-out 13.2 lexer and Oracle compatibility fixtures also contain no matching syntax. The implementation therefore scans MariaDB's actual ordinary quoting under Oracle mode and has a passing live-mode test. It does not invent an Oracle-database syntax extension. This corrects an assumption in the approved plan; it is not an unsupported feature relabeled as passing.

Packet framing now checks continuation budgets directly after each physical header, before fetching its body. One framing state carries sequence and accumulated bytes; this removes a second per-packet stream wrapper. Row decoding keeps strict validation at the guarded IO boundary. The vector API shares the list codec and constructs a bounded vector per row. Batch rendering uses one shared builder rather than one lazy ByteString builder per parameter set. Focused measurements are retained under `validation/results/experiments/`; they are development evidence, not replacements for the final complete run.

One development experiment, `decoder-boundary-force.json`, used a stale executable after a failed preceding build. It is explicitly marked INVALID beside the file and excluded from conclusions. The focused runner was corrected to require a successful fresh build and stable input fingerprints before it can record measurements. The complete validation wrapper already stopped on build failures; no complete published result came from that stale executable.

The final close/COMMIT audit reproduced another race: a concurrent `close` could set status Closed while COMMIT awaited its reply, leaving a generic network exception and no uncertainty diagnostic. Exchange progress now distinguishes before-send, in-flight and complete replies; generation and completion evidence determine uncertainty even after close. Short completion transitions are masked. Two deterministic regressions cover lost acknowledgement on close and preservation of a fully received server ERR after close. The original diagnostic reproduced `Left NetworkException / Closed / Nothing` before the fix.

Short flat parameter templates now use a conservative allocation-light classification path. Quotes, comments (including `--`), multiple statements, opaque calls and unsupported encodings retain the complete lexer. This reduced repeated-parameter time and allocation in a separate seven-repetition experiment, while the original quote/comment cases remain unchanged.

## Mechanical adaptations to original tests

- `test/MultipleResults.hs`: widen the OK result-shape helper from `Either Int` to `Either Word64`; all SQL and expected values remain unchanged.
- `validation/hs/Validation/Protocol.hs`: construct the synthetic pending-response connection through the new smart constructor and mark its response state as Streaming. Preserve the original unread-reset assertion and packets.

Frozen workloads, shared benchmark helpers, C control and recorder remain unchanged. Additional regression cases live in separate modules; they are ordinary failing tests until their implementations pass.

## Review-build provenance

`--working-tree` is explicit. The live report records the parent revision, dirty input list and SHA-256 hashes of the actual tested contents. A review freshness check accepts those contents only when they match the completed recorded review run. Normal CI/publication checks continue requiring committed inputs. The accepted main reference is not advanced by development failures or by an unreviewed working tree.

## Deliberate remaining boundaries

The original timeout-reuse case continues failing: uncertain I/O retires the connection. Authentication plugins, native extension/bulk/cache features, prepared OUT, connection setup gaps and CDC defects remain outside Stage 1. No failure is relabeled as a pass or hidden behind an expected-failure wrapper.

The 33 original failures remain visible: 16 CDC, nine authentication, four protocol capability/authentication, two connection setup, one prepared-OUT SQL and one timeout-reuse policy case. The original 11 unsupported public APIs and two unavailable authentication fixtures are unchanged.

## Verification before code review

All three final full runs tested input fingerprint `377dfc0bae2c80460c71b60209b9626d37e15767767e65674a453d88ec6c4914` on MariaDB 12.3.3, GHC 9.10.3 and this Mac. Each has **339 PASS / 33 FAIL / 11 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE**, across 385 records. Among the original 300 executable checks: **267 PASS / 33 FAIL**, converting all **23/23** targeted failures. All **70** added Stage 1 cases pass. Both inherited suites pass (179 unit/property cases including the existing external-HTTPS ignore, plus 32 integration cases). Every original and last-accepted PASS is preserved.

All 24 runnable frozen benchmark profiles complete with seven repetitions in each of three consecutive runs: **21 process samples per profile** across the confirmation window. All three pass the unchanged original regression policy. All **30 Python reporting/acceptance tests** pass. Final baseline checksums, unchanged-workload diffs, input freshness and generated-report consistency checks pass. No commit, push, PR or remote CI run was made. Linux/Windows/Nix builds were not executed locally.

The final [pre-review confirmation window](../validation/results/experiments/pre-review-confirmation-window.json) includes every run, hashes of portable raw result archives, profile comparability and all stricter gate outcomes. The live report uses the third complete run. Tables below use the median of the three run medians, including every run; they do not choose the fastest result. Earlier windows and unsuccessful optimization experiments remain archived.

## Performance before code review

Negative change means less time or allocation per unit. Original baseline and current use the same frozen workload, server/settings, machine, compiler and resolved dependency versions. These measurements describe this profile; they are not cross-platform claims.

| Workload | Unit | Baseline ns/unit | Current window ns/unit | Change vs baseline |
| --- | --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | row | 9,670.00 | 7,461.00 | -22.8% |
| `haskell/read.text.wide` | row | 2,876.43 | 2,675.97 | -7.0% |
| `haskell/read.prepared.wide` | row | 2,425.07 | 2,273.43 | -6.3% |
| `haskell/read.vector.narrow` | row | 365.84 | 338.42 | -7.5% |
| `haskell/read.prepared.narrow` | row | 314.58 | 292.50 | -7.0% |
| `haskell/micro.text-row` | row | 313.24 | 281.17 | -10.2% |
| `haskell/micro.binary-row` | row | 246.13 | 236.06 | -4.1% |
| `haskell/latency.text` | query | 39,354.00 | 40,418.00 | +2.7% |
| `haskell/latency.prepared` | query | 41,826.00 | 37,778.00 | -9.7% |
| `haskell/write.text` | row | 38,324.00 | 41,425.00 | +8.1% |

| Workload | Baseline bytes/unit | Current window bytes/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | 20,261.29 | 8,206.91 | -59.5% |
| `haskell/read.text.wide` | 30,532.35 | 25,986.22 | -14.9% |
| `haskell/read.prepared.wide` | 24,469.57 | 22,669.72 | -7.4% |
| `haskell/read.vector.narrow` | 3,136.04 | 2,344.49 | -25.2% |
| `haskell/read.prepared.narrow` | 1,886.90 | 1,923.57 | +1.9% |
| `haskell/micro.text-row` | 2,952.02 | 2,448.02 | -17.1% |
| `haskell/micro.binary-row` | 2,048.02 | 2,080.02 | +1.6% |
| `haskell/latency.text` | 39,896.08 | 34,471.36 | -13.6% |
| `haskell/latency.prepared` | 39,647.79 | 29,509.07 | -25.6% |
| `haskell/write.text` | 43,608.14 | 32,689.00 | -25.0% |

CPU and GC values are also retained in the window JSON (normalized with the same units) and raw RTS samples. For the main decoder/scan/batch changes:

| Workload | Baseline CPU ns/unit | Current window CPU ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/write.execute-many` | 12,731.00 | 9,569.00 | -24.8% |
| `haskell/read.text.wide` | 3,143.00 | 2,883.73 | -8.2% |
| `haskell/read.prepared.wide` | 2,644.33 | 2,450.50 | -7.3% |
| `haskell/micro.text-row` | 342.99 | 304.32 | -11.3% |

The allocation fixes are structural: one builder per parameter batch; shared per-result codecs and a non-null binary plan; one framing layer with 257 shared empty sequence states; and receive allocations that grow from 4 KiB to the existing 16 KiB ceiling on full reads. No mutable receive storage is reused beneath returned rows. Focused evidence and the per-thread allocation diagnostic are archived under `validation/results/experiments/`.

## Open timing investigations

> [!WARNING]
> Correctness and allocation acceptance pass. Full performance acceptance is **not claimed**: repeatable timing signals above 5% still require resolution or Anton’s explicit tradeoff decision. The accepted main reference has not been advanced.

- `haskell/write.prepared` vs **accepted**: +5.3% to +6.6% in every final run.
- `connector-c/read.text.narrow` vs **original**: +6.6% to +8.0% in every final run.
- `haskell/write.text` vs **original**: +7.4% to +9.7% in every final run.

Prepared inserts are +6.4% slower than the accepted timing reference in the final window (allocation remains below baseline); this also remains open for review. Text inserts remain slower than the original timing reference despite materially lower allocation; this is retained as a driver-path investigation, not dismissed as noise. Four-reader timing varied between windows; it is not a repeatable >5% signal in the final three-run window. Earlier four-reader timing was faster than the frozen baseline but slower than the last accepted run. The unchanged driver itself previously measured 100.09 ns/row in the accepted reference, 117.96 in the frozen baseline and 121.62 in the fresh pre-implementation control. That variability makes attribution uncertain; it does not automatically waive the ratchet.

Matching C controls and every per-run signal remain in the JSON. Their movement diagnoses host/server variability; no C result was blindly subtracted from Haskell timing. There are no allocation alerts above 5% against either reference in any final run, and no original-threshold regression alarms.

## Supplementary setup, commands and retention

These separately labeled workloads were captured before source edits and repeated afterward. They do not replace the frozen reference. Each has seven process repetitions. Startup includes the new configuration/snapshot exchanges; ordinary parameter/transaction calls have no hidden discovery SQL.

| Supplementary workload | Unit | Baseline ns/unit | Current ns/unit | Change vs baseline |
| --- | --- | ---: | ---: | ---: |
| `connect.tcp` | connection | 177,466.67 | 254,666.67 | +43.5% |
| `parameters.select` | operation | 37,064.00 | 39,272.00 | +6.0% |
| `parameters.mixed` | operation | 75,894.00 | 78,094.00 | +2.9% |
| `transaction.empty` | operation | 63,173.33 | 69,480.00 | +10.0% |
| `batch.1000` | row | 11,008.60 | 8,712.80 | -20.9% |
| `stream.retention` | row | 351.03 | 352.40 | +0.4% |

Connection setup is deliberately more expensive (two setup exchanges). Repeated parameter and empty-transaction supplementary timings also remain higher and should be considered alongside the frozen timing investigations, rather than hidden by scan/batch improvements. The proxy verifies actual command counts: one command per ordinary parameter call; two for a mixed raw/parameter pair; two for an empty known-state transaction; one for a stable parameter batch; zero target commands on unknown-context rejection; and two for explicit refresh. The ROW_COUNT test independently confirms the absence of hidden probes.

New retention experiments have no invented pre-change baseline. They sample **current** live heap after major GC; they do not use process `max_live_bytes` as proof of bounded retention. GC checkpoints are part of these memory experiments only.

| Retention experiment | Median final live bytes | Maximum checkpoint live bytes |
| --- | ---: | ---: |
| `retention.10000` | 128,552 | 130,392 |
| `retention.1000000` | 128,624 | 154,544 |
| `retention.tiny-slice` | 116,480 | 118,280 |

The 100-fold row-count increase does not produce proportional retained heap. Holding one exact byte after a 16 MiB result releases the large payload. This is evidence for these streaming/slice paths, not a proof for every application consumer. Native tracking characterization was independently repeated and archived with its credential-free source and output.

## Morning review

Start with [migration contracts](STAGE1_MIGRATION.md), then `Connection.hs`/`Base.hs` ownership, framing and transaction cleanup; `Query.hs`/`MySQLValue.hs` value and rendering changes; additive fault/live tests; and the live report plus confirmation window. Package/module renaming, new auth plugins, native bulk/metadata reuse, pooling and CDC repairs remain outside this stage. All edits are unstaged/uncommitted on `codex/stage1-core-correctness`, parent `90f4f54`. Review and any timing tradeoff decision precede publication to main.
