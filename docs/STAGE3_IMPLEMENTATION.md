# Stage 3 — prepared statements and native MariaDB performance

Stage 3 implements [roadmap](ROADMAP.md) steps 1–2, based on published Stage 2
`e12462a`. Development and review took place on `codex/stage3-native-statements`.
Anton approved publication on 7 November 2026. The [live report](../validation/RESULTS.md)
identifies the committed implementation tested for publication; earlier review
evidence retains its original fingerprints. Steps 3–5 remain future work.

## Review corrections — 7 November 2026

The follow-up review found four issues, all corrected before publication:

- Statement cleanup now restores the caller's masking state inside its timed
  action. Buffered row processing can receive the deadline or a new cancellation;
  retirement and exception selection remain masked. Transaction rollback used
  the same pattern and receives the same correction. New wire fixtures cover
  buffered deadlines, cancellation and preservation of the primary error.
- Statement and connection metadata byte totals change atomically with their
  registry entries. Replacement, close, ID reuse, rejection and terminal failure
  preserve accounting without rescanning unrelated statements on each refresh.
- The immutable native baseline and both checksummed artifacts are required.
  Publication independently recalculates deltas, comparability and alarms;
  deleting/changing a baseline or removing its comparison fails verification.
  Its three files are also included in the executable-input fingerprint.
- Bulk dimension and arity checks use overflow-safe bounded counting. A small
  valid batch works with `maxBound` row/column limits, while excess rows remain
  rejected before sending.

Strengthening the evidence guard also exposed a dependency tuple/list mismatch
that had withheld historical native baseline comparisons. Dependency identities
are now normalized across JSON serialization. Comparability checks retain the
unchanged Haskell workload/fixture hashes and enforce every profile's units and
checksums; changes to Python verification policy do not discard a valid workload
comparison. The original baselines and historical captures remain unchanged.
[Historical comparison audit](../validation/results/experiments/stage3-native-baseline-audit.json).

Current publication measurements appear in the [live report](../validation/RESULTS.md).
The [review confirmation window](../validation/results/experiments/stage3-review-confirmation.json)
and the earlier measurements below are historical and identify their own input
fingerprints.

## Statement ownership and complete results

`prepareStatement` creates an abstract `PreparedStatement` bound to its connection
and registration generation. Managed operations cannot send a handle to a
different connection. Closing a raw ID or retiring its connection invalidates
the handle; reuse of a numeric server ID cannot revive an older handle.
The legacy raw-ID API remains available and retains server diagnostics for
unknown IDs. Known parameter arity is checked locally before sending bytes.

Use `withPreparedStatement` when all work fits inside a callback. It drains
abandoned rows and releases the statement under one cleanup deadline. An ordinary
cleanup failure does not replace the callback's primary exception; a new
asynchronous cancellation keeps its identity. Stalled/malformed cleanup retires
the transport. `closePrepared` itself rejects a pending result; explicit handles
must consume their streams before close/reset.

`queryPrepared` streams the first binary row result. `queryPreparedMulti` and
`queryStmtMulti` collect all prepared results in wire order, including trailing
OKs. `PreparedOutParameters` is identified by MariaDB's `SERVER_PS_OUT_PARAMS`
status flag, separately from ordinary `PreparedRows`. These collecting APIs hold
all returned rows in memory; use the streaming API for large individual results.
The client now negotiates `CLIENT_PS_MULTI_RESULTS` because its complete result
handling is implemented. Single-result APIs still drain unexpected later row
sets and report `ExtraResultSets`.

## Metadata and decoder lifetime

Metadata caching and extended metadata are negotiated independently and can be
disabled through `enableMetadataCaching` and `enableExtendedMetadata`. Ordinary
text headers also carry the metadata-follows marker when caching is negotiated;
the reader handles this consistently during startup, queries, draining and
prepared execution.

Prepare metadata seeds the statement cache. A server-supplied replacement updates
the metadata and compiled binary decoder together, including after DDL/reprepare
and parameter-type changes. Omitted metadata must match the active statement,
result ordinal and column count. A cache miss or malformed marker retires the
connection rather than decoding bytes with a guessed schema. Decoder construction
is outside the per-row path and repeated cached executions reuse it.

`ColumnDef` keeps its positional representation for compatibility.
`ColumnMetadata` adds exact native attributes, including unknown tags; the wire
extension is parsed before the fixed metadata section. Access it through
`preparedMetadata` or complete prepared results. Legacy query APIs return the
core column definitions. Attribute count, per-block metadata and aggregate
retained statement metadata are bounded. Retained names and attribute payloads
own their bytes, preventing a small cached field from pinning shared receive
buffers. An independent buffer-identity regression checks this ownership.
Terminal registry state is atomic with
its entries, preventing a close/publication race from restoring retired data.

`COM_STMT_RESET` retains the server's metadata-omission state. `resetPrepared`
therefore preserves its matching metadata/decoder while clearing parameter and
cursor state. The future connection-reset API has a different invalidation
contract and is not implemented here.

## Binary bulk execution

`executeBulk` sends one native `COM_STMT_BULK_EXECUTE` and returns its aggregate
OK. `executeBulkUnitResults` explicitly requests negotiated per-operation IDs
and affected-row counts, represented as `Word64`. Aggregate feedback is never
expanded into invented per-operation success records.

Each cell is `BulkValue value`, `BulkDefault` or `BulkIgnore`; NULL is
`BulkValue MySQLNull`. One common wire type/signedness per column is required.
NULL/default/ignore cells do not select a conflicting type. Mixed wire types,
arity errors, empty batches, unsupported capabilities and resource overflows
fail before any batch bytes are sent. Text uses the active client encoding;
unencodable and non-finite values are rejected locally. Type signatures are
compared as scalars without allocating an encoded type buffer for every cell.
Transcoded cells are charged against the client/server message budget as they
are produced, before retaining an oversized second batch.
An additional minimum-size check accounts for every row/column indicator before
visiting cells, so an impossible NULL/default-heavy batch is rejected without
traversing its entire contents. A lazy invalid-cell fixture independently checks
that this rejection happens first.

No batch is silently split or replayed. A server error may follow partial work;
use an explicit transaction when the whole batch must roll back. Per-operation
results describe server feedback and do not promise transaction durability.

```haskell
withPreparedStatement conn "INSERT INTO readings(sensor,value) VALUES(?,?)" $ \stmt ->
    withTransaction conn $ executeBulk stmt
        [ [BulkValue (MySQLInt32 1), BulkValue (MySQLDouble 0.125)]
        , [BulkValue (MySQLInt32 2), BulkValue MySQLNull]
        ]
```

The new defaults bound registered statements to 1,024 and bulk rows to 10,000.
Use `defaultConnectionOptions` with record overrides. Fully constructed option
records need the new fields. `maximumMetadataBytes` additionally bounds the sum
of retained statement metadata; an exhausted cache cannot simply evict a schema
that the server may omit next time. Closing unused statements releases its charge.

## Validation and measurements

The original 300 assertions, Stage 1/2 assertions and four frozen workload/
recorder files are preserved. Three former unsupported inventory entries now
execute actual bulk, caching and native-metadata checks. The previous-stage
manifest protects every published Stage 2 pass, including Stage 1 improvements;
the older accepted performance reference remains unchanged.

Additive regressions cover statement generations/lifetimes, all result shapes,
metadata omissions/replacements, malformed markers/attributes, cache budgets,
scalar/NULL parity, DEFAULT/IGNORE, unsigned generated IDs, 16 MiB continuation,
rollback/no replay, encoding, resource limits and peer-observed command counts.
A real server status counter independently verifies metadata was actually omitted.

The unchanged full suite is run through `python3 validation/check.py
--working-tree`, which also runs the native-feature measurements automatically.
Separate native workloads compare aggregate/unit binary bulk,
sequential prepared inserts and text batching with equal transaction/data/
verification work. Cached/uncached narrow and wide prepared queries use the same
source, server and compiler. Each measured process has two warm-ups; seven
repetitions are interleaved in a deterministic shuffled order, with all samples,
allocations, CPU/GC counters, units and independent checksums retained:

```sh
python3 validation/stage3_benchmarks.py --output validation/results/runs/NEW_NATIVE_RUN
```

These are new same-build comparisons, not replacement values for the original
baseline. The frozen native benchmark inventory slots remain historical
placeholders; the additive suite measures the newly implemented functionality.
Native evidence is embedded in the live report, and incomplete, stale or
inconsistent evidence blocks publication. The first native capture is immutable
separately from the original unchanged-driver baseline; future native comparisons
verify its checksum, workloads and environment. Timing increases above 20%
fail the wrapper; timing/allocation increases above 5% stay open investigations.
Final results and measured limits are recorded below.

## Validation before the review corrections — historical

The [pre-review confirmation window](../validation/results/experiments/stage3-before-review-fixes.json) identifies input fingerprint `ed28bc6258c15fd0b4a5905ca91bdad76db758dfb435681cc6c27b7dc000901c`. Each of its three complete runs records **456 PASS / 17 FAIL / 8 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE** across **483 records**. All **50 Stage 3 cases**, both inherited suites and every previously published Stage 2 PASS remain passing. All 455 passes from the earlier Stage 3 development window also remain passing.

All **88 Python policy tests** pass on macOS and Linux. The [final Linux profile](../validation/results/references/stage3-linux-bounded-final.json) independently records the same correctness counts with MariaDB 12.3.3, Linux aarch64, GHC 9.4.7 and Cabal 3.14.1.1. Driver and Haskell harness hashes match the final Mac source. All eight native benchmark paths also pass one-iteration Linux smoke checks; Linux timings are not compared with Mac baselines. [Linux log](../validation/results/experiments/stage3-linux-bounded-final.log).

Haddock succeeds, with **86/86 Base symbols documented**. [Final documentation log](../validation/results/experiments/stage3-haddock-final.log). Existing internal/inherited missing-symbol and link warnings remain visible. The earlier dependency-wide documentation build was interrupted and retained separately; the final library-targeted build succeeds.

Each final full run includes **24 frozen runnable profiles plus eight native profiles**, with seven process repetitions each: **21 samples per profile** across the window. The third run was the declared current result for that window; no faster earlier result was substituted. All samples and failures are retained.

**Correctness, provenance and allocation gates passed. Performance acceptance remained open.** The three wrappers exited **0, 1, 0**: the middle run had 18 original >20% timing alarms during a broad slowdown that also affected unchanged C controls. The first and third runs had no original timing alarms. No run had a >5% allocation investigation. Native-baseline comparisons were withheld by the tuple/list defect described above; their empty alarm lists did not establish acceptance. The [post-review audit](../validation/results/experiments/stage3-native-baseline-audit.json) recalculates five native timing signals in the middle run, including text batching at +26.6%, and none in the first/third runs. All measured values and recorded outcomes are preserved. Eleven stricter ordinary-profile/reference timing signals repeated across the window; they remain open.

### Native feature comparisons

These compare alternatives in the **same pre-review build**, using the median of the three run medians. Each baseline is the corresponding current-build alternative; original-fork comparisons appear separately below. Bulk units are inserted rows; prepared-read units are complete one-row queries. Change is `(current / baseline - 1) × 100`; negative time/allocation is better.

| Comparison (current / baseline) | Baseline ns/unit | Current window ns/unit | Time change vs baseline | Allocation change vs baseline |
| --- | ---: | ---: | ---: | ---: |
| Native bulk / sequential prepared | 40,737.60 | 1,951.80 | -95.2% | -91.1% |
| Native bulk / text batch | 11,545.80 | 1,951.80 | -83.1% | -78.0% |
| Per-unit feedback / aggregate bulk | 1,951.80 | 2,188.80 | +12.1% | +49.1% |
| Cached / uncached narrow query | 38,602.00 | 36,792.00 | -4.7% | -15.7% |
| Cached / uncached wide query | 72,892.00 | 55,120.00 | -24.4% | -73.5% |

Per-unit IDs/counts cost additional time and allocation because the server returns actual feedback rows. Aggregate mode remains available when those details are unnecessary.

The [first native-feature baseline](../validation/baselines/macos-arm64-native-statements/SUMMARY.md) remains immutable and separate from the original frozen baseline and accepted reference. Its first working-tree source can be reconstructed with the [verified source patch](../validation/results/experiments/stage3-native-baseline-source.patch) against `e12462a`; every input hash matches its recorded capture. The [earlier window](../validation/results/experiments/stage3-before-minimum-size-guard.json) retains its own measurements before the additional early-size guard. It does not replace final-source evidence.

### Original frozen workload comparison

These are median-of-run-median values against the **original unchanged-driver baseline**. Host variation makes small timing deltas provisional; the archived third run retains its individual values. No accepted performance reference has advanced.

| Workload | Baseline ns/unit | Current window ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/read.text.narrow` | 305.48 | 334.08 | +9.4% |
| `haskell/latency.prepared` | 41,826.00 | 45,728.00 | +9.3% |
| `haskell/write.text` | 38,324.00 | 42,679.00 | +11.4% |
| `haskell/write.execute-many` | 9,670.00 | 9,797.00 | +1.3% |
| `haskell/read.text.wide` | 2,876.43 | 2,893.30 | +0.6% |
| `haskell/read.prepared.wide` | 2,425.07 | 2,499.10 | +3.1% |
| `haskell/read.vector.narrow` | 365.84 | 357.64 | -2.2% |
| `haskell/micro.text-row` | 313.24 | 305.27 | -2.5% |
| `connector-c/read.text.narrow` | 197.44 | 214.04 | +8.4% |
| `connector-c/read.text.wide` | 1,261.03 | 1,372.77 | +8.9% |
| `connector-c/write.execute-many` | 7,635.00 | 8,258.00 | +8.2% |

Allocation remains below the original baseline in the representative paths:

| Workload | Baseline bytes/unit | Current window bytes/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/read.text.narrow` | 2,831.95 | 2,248.70 | -20.6% |
| `haskell/write.text` | 43,608.14 | 32,752.02 | -24.9% |
| `haskell/write.execute-many` | 20,261.29 | 8,558.15 | -57.8% |
| `haskell/read.text.wide` | 30,532.35 | 26,013.57 | -14.8% |

### Matched Stage 2 diagnostic

A freshly compiled pristine Stage 2 `d5c71bd` was measured alongside the final Stage 3 binary, using identical frozen workloads, compiler and resolved dependencies on this Mac. Seven nearby process pairs per profile used shuffled version order. Exact Stage 2 source hashes match its published run. Two controls deliberately use the **same C executable** under both version labels to expose measurement noise. These diagnostics do not replace the full live report or waive its stricter timing investigations. [All paired samples](../validation/results/experiments/stage3-interleaved-control.json).

| Workload | Stage 2 ns/unit | Stage 3 ns/unit | Change vs Stage 2 |
| --- | ---: | ---: | ---: |
| `micro.text-row` | 293.75 | 291.56 | -0.7% |
| `micro.binary-row` | 243.24 | 242.15 | -0.4% |
| `latency.text` | 43,048.00 | 44,328.00 | +3.0% |
| `latency.prepared` | 38,948.00 | 37,120.00 | -4.7% |
| `read.text.narrow` | 354.06 | 338.42 | -4.4% |
| `read.text.wide` | 2,814.87 | 2,725.77 | -3.2% |
| `write.text` | 42,357.00 | 41,969.00 | -0.9% |
| `write.execute-many` | 8,242.00 | 8,689.00 | +5.4% |
| `control.read.text.narrow` | 208.96 | 207.40 | -0.7% |
| `control.write.execute-many` | 7,342.00 | 7,748.00 | +5.5% |

Prepared latency and microbenchmarks show no broad new slowdown in this matched diagnostic. Text batching is 5.4% slower by ratio of medians while the identical C batching control differs by 5.5%; the evidence does not isolate a driver regression there. Narrow-read conclusions also vary with aggregation (paired ratios are retained in JSON). Small differences remain investigation signals, not precise causal effects.

The unchanged supplementary workloads were also interleaved between these same binaries. Their matched differences are small, unlike the large swings in standalone historical comparisons. [Setup/helper paired samples](../validation/results/experiments/stage3-setup-control.json).

| Workload | Stage 2 ns/unit | Stage 3 ns/unit | Change vs Stage 2 |
| --- | ---: | ---: | ---: |
| `connect.tcp` | 280,566.67 | 275,966.67 | -1.6% |
| `parameters.select` | 42,210.00 | 42,312.00 | +0.2% |
| `parameters.mixed` | 81,184.00 | 81,254.00 | +0.1% |
| `transaction.empty` | 72,296.67 | 72,793.33 | +0.7% |
| `batch.1000` | 10,138.00 | 10,189.20 | +0.5% |
| `stream.retention` | 358.65 | 362.10 | +1.0% |

### Standalone setup and retention

The [final supplementary capture](../validation/results/references/stage3-supplementary-complete.json) has seven repetitions on the final source. Its absolute timings are provisional under the observed host variability; all results remain visible against the preserved unchanged-driver supplementary reference. The matched diagnostic above is a separate experiment and does not substitute values into this table.

| Workload | Baseline ns/unit | Current ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `connect.tcp` | 177,466.67 | 572,466.67 | +222.6% |
| `parameters.select` | 37,064.00 | 42,534.00 | +14.8% |
| `parameters.mixed` | 75,894.00 | 95,074.00 | +25.3% |
| `transaction.empty` | 63,173.33 | 81,126.67 | +28.4% |
| `batch.1000` | 11,008.60 | 45,378.20 | +312.2% |
| `stream.retention` | 351.03 | 542.48 | +54.5% |

Retention experiments are untimed memory observations with no invented pre-change baseline. Live heap remains bounded in these tested paths:

| Experiment | Median final live bytes | Maximum checkpoint live bytes |
| --- | ---: | ---: |
| `retention.10000` | 127,944 | 131,936 |
| `retention.1000000` | 128,008 | 152,120 |
| `retention.tiny-slice` | 115,752 | 117,600 |

A 100-fold row-count increase does not produce proportional retained heap. Holding one exact byte after a 16 MiB result releases the large payload in the tested path.

## Review-fix validation and measurements

The corrected input fingerprint is `9987450d8d8b8e21ac33e3382edc17dd4186aded7abfb10e23ffe5c9e8f5a6d5`.
All three declared full Mac runs record **462 PASS / 17 FAIL / 8 UNSUPPORTED /
2 ENVIRONMENT_UNAVAILABLE** across **489 records**. All **56 Stage 3 cases**, both
inherited suites, all 456 pre-review development passes and every published
Stage 2 pass remain passing. The 17 known failures remain the 16 CDC defects and
the conflicting original timeout expectation; no frozen assertion was weakened.

[Linux evidence](../validation/results/references/stage3-review-fixes-linux.json)
records the same counts with matching driver, registered harness and library
configuration hashes. All eight native benchmark paths pass Linux smoke checks.
All **101 Python policy tests** pass on Mac and Linux. Library Haddock succeeds,
with **86/86 Base symbols documented**; inherited/internal warnings remain visible.
[Linux log](../validation/results/experiments/stage3-review-fixes-linux.log) ·
[Policy log](../validation/results/experiments/stage3-review-fix-policy.log) ·
[Haddock log](../validation/results/experiments/stage3-review-fixes-haddock.log).

The Linux image export initially exhausted Docker storage. Six exact obsolete,
unshared cache records from this MariaDB task were removed; unrelated Docker
images, containers and volumes were preserved. The successful run executed in
BuildKit and exported only evidence. This environment failure was distinct from
a driver failure.

### Metadata accounting diagnostic

The baseline here is the pre-review Stage 3 binary, with input fingerprint
`ed28bc6258c15fd0b4a5905ca91bdad76db758dfb435681cc6c27b7dc000901c`.
Current is the corrected binary above. The identical read-only `SELECT 7`
workload disables metadata omission and prepares statements outside timing.
Seven shuffled adjacent process pairs retain two samples per statement count
per process, each with 100 warm-up and 2,000 measured queries. These diagnostic
values are separate from the frozen benchmark report.
[All samples and binary/source identities](../validation/results/experiments/stage3-review-cache-scaling.json)
· [Exact workload](../validation/results/experiments/stage3-review-cache-scaling.hs.txt).

| Open statements | Baseline ns/query | Current ns/query | Change vs baseline |
| ---: | ---: | ---: | ---: |
| 1 | 50,737.5 | 47,893.5 | -5.6% |
| 128 | 52,577.0 | 48,766.5 | -7.2% |
| 1024 | 80,060.0 | 49,438.0 | -38.2% |

Incremental accounting removes the observed linear scan through unrelated
statements. The 1,024-statement case is 38.2% faster in this paired diagnostic;
small differences at lower counts remain subject to host variation.

### Full benchmark confirmation

Each run includes 24 frozen runnable profiles and eight native profiles, each
with seven process repetitions. All samples are retained in the
[review confirmation manifest](../validation/results/experiments/stage3-review-confirmation.json);
the predeclared third run was the current review result. A fresh committed run
supplies the publication report.
Wrapper exit codes are **1, 0, 1**, caused by timing alarms. The first run has one
original >20% parallel-read alarm; the second has none. The third has 20 original
alarms and eight native >5% timing signals, four above 20%. Four unchanged C
controls also slow by 29–67% in that run. **Performance acceptance remains open**;
no allocation investigation appears in any run, and all three native baseline
comparisons are now explicitly verified as comparable. Thirteen stricter
ordinary-profile/reference timing signals recur across the window. No performance
reference advanced and no faster earlier run replaced the third.

The table uses the median of the three run medians. Baseline and Current are
alternatives measured on the same corrected build; these are separate from the
original unchanged-driver and immutable first-native baseline comparisons.
Bulk units are rows; prepared-read units are complete one-row queries.

| Current feature / Baseline alternative | Baseline ns/unit | Current ns/unit | Time change vs baseline | Allocation change vs baseline |
| --- | ---: | ---: | ---: | ---: |
| Native bulk / sequential prepared | 40,414.20 | 1,898.60 | -95.3% | -91.1% |
| Native bulk / text batch | 11,193.60 | 1,898.60 | -83.0% | -78.2% |
| Per-unit feedback / aggregate bulk | 1,898.60 | 2,117.80 | +11.5% | +49.1% |
| Cached / uncached narrow query | 38,706.00 | 36,822.00 | -4.9% | -15.6% |
| Cached / uncached wide query | 71,864.00 | 53,888.00 | -25.0% | -73.5% |

## Deferred work

The remaining CDC defects, GTID/acknowledgement work, reset/session APIs and
workload-specific features retain their place in the roadmap. The contradictory
original timeout expectation remains a visible failure; safe retirement remains
the default and no frozen assertion is weakened. Previously deferred performance
investigations remain open. This stage does not claim every MariaDB feature or
platform has been certified.

Protocol/source references: local MariaDB checkout `b439f350ce3`,
`sql/sql_prepare.cc`, `sql/protocol.cc`, `sql/sql_class.cc` and
`include/mysql_com.h`; [native protocol extensions](https://mariadb.com/docs/server/reference/clientserver-protocol/mariadb-protocol-differences-with-mysql)
and [bulk command](https://mariadb.com/docs/server/reference/clientserver-protocol/3-binary-protocol-prepared-statements/com_stmt_bulk_execute).
