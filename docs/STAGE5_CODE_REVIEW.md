# Stage 5 CDC follow-up review — 8 November 2026

Anton requested checking the published CDC stage and fixing every finding,
working directly on `main`. The starting revision was `f981a1c`. After reviewing
the fixes, Anton authorized commit and push; implementation commit `ba99d8c`
contains the changes. The original assertions, workloads and immutable
performance references are preserved. The committed publication below supersedes
the historical working-tree captures in this report.

## Findings and fixes

| Priority | Finding | Reproduction and correction |
|---|---|---|
| P1 | Temporal values could change during CDC decoding. | Fractional precisions 1, 3 and 5 were scaled ten times too far: `.1` became 1,000,000 microseconds. Whole negative TIME2 values lost a second: `-01:02:03` became `-01:02:02`. Adjacent odd/even precisions now use MariaDB's shared byte scale, with the negative integer borrow applied only for a nonzero fraction. Invalid signs, ranges and precision padding fail before unsigned conversion. |
| P1 | Valid GTID history could stop replication after an origin change. | A real rotation with two originating servers in one domain failed with `duplicate GTID domain`. Binlog history is now a `GtidList`, retaining every domain/server entry and the event flags. Resume state remains the separate, unique-domain `GtidSet`. History alone never advances a checkpoint. |
| P1 | GTID extensions could be ignored across unsafe boundaries. | Two-phase ALTER groups were accepted as ordinary groups. Truncated engine/thread extensions and undersized GTIDs were also accepted. Known neutral extensions and padding are now validated; XA, two-phase ALTER and unknown extension semantics fail explicitly before delivery/checkpoint creation. A real two-phase ALTER fixture verifies terminal retirement. |
| P2 | Sparse events could exceed a fictitious value budget. | 1,000 sparse changes in a 4,096-column table were rejected even though each image contained only one value. Budget accounting now derives the actual value count from the first decoded image, with no second bitmap scan. Omitted columns cost no decoded values; NULL values and both update images still count. Independent row-count/value-limit regressions remain enforced. |
| P2 | A large configured event budget could overflow. | `maxExpandedEventBytes = maxBound` overflowed signed arithmetic when adding wire overhead, rejecting ordinary bootstrap packets. The wire ceiling uses Word64 arithmetic and is clamped to the connection's limit. |
| P2 | The CDC wire ceiling was checked after continuation assembly. | An oversized first fragment caused another continuation read despite a much smaller CDC budget. The logical packet assembler now applies that ceiling immediately; the regression observes the read count and one transport release. Physical packet bodies remain bounded before reading by `ConnectionOptions`. |
| P2 | Query classification could allocate another full query body. | Recognizing three short transaction keywords flattened and uppercased potentially 64 MiB of SQL. Classification now inspects at most nine bytes after leading spaces, while retaining the complete query payload. Long statements beginning with a control keyword remain ordinary queries. |

Source review used the checked-out MariaDB server's `sql/compat56.cc`,
`sql/log_event.cc`, `sql/log_event_server.cc` and `sql/rpl_gtid.cc`. Real-server
regressions use installed MariaDB 12.3.3; this does not claim a 13.2 server run.

## Independent reproductions

The new tests first ran against the unchanged published driver: **34 FAIL /
18 PASS** across 52 checks. This includes real-server temporal, origin-change
and two-phase ALTER failures. The retained
[reproduction patch](../validation/results/experiments/stage5-review-reproduction.patch)
applies to `f981a1c`; an independent
[reconstruction audit](../validation/results/experiments/stage5-review-reconstruction.json)
verifies every one of its 165 executable input hashes. The
[raw failing results](../validation/results/references/stage5-review-red-1.json)
and [process log](../validation/results/experiments/stage5-review-red-1.log)
preserve the failures.

Six additional checks strengthen the corrected history/fraction contracts and
large-query classification. All **58 review regressions** and **83 original
Stage 5 checks** now pass.
The existing GTID literal helper was corrected to include MariaDB's 19-byte
minimum body instead of a 13-byte unpadded prefix; its assertions are unchanged.
The eight CDC benchmark workloads have independent fixtures and are unchanged.

## Public API and bounds

`CDCGtidList` now carries `GtidList`, with `gtidListEntries` and `gtidListFlags`.
Callers inspecting that payload must migrate from `gtidSetEntries`. Do not turn
history into resume state by choosing an arbitrary server or largest sequence;
use `resumeFromCheckpoint` and a proven transaction checkpoint.

Two-phase ALTER is explicitly unsupported by the transaction-aware API,
alongside XA-aware checkpointing and the storage-engine-binlog GTID semisync
extension. This review adds safe rejection rather than claiming those features.

The fixed parser cap is 65,536 row changes per event, with an update containing
before/after images. The separate 1,048,576-value cap charges both images and
NULL values. Retained metadata and decompression limits are unchanged. The
pre-body wire bound comes from `ConnectionOptions`; the CDC ceiling additionally
bounds logical continuation assembly and expanded event bodies.

## Validation

All **143 policy tests pass**. Haddock documents **91/91 Base** and **41/41 BinLog**
exports. The matching final Linux profile passes with **694 PASS / 1 known FAIL /
4 UNSUPPORTED / 2 unavailable**, including all 141 CDC checks and both inherited
suites. Linux's 165 executable file hashes match the Mac fixes exactly. The
last-published correctness ratchet now protects all 636 Stage 5 passes.

The first Linux fixes profile also passed. A subsequent buffered verification
was interrupted after a prolonged silence; a streamed retry exposed a Docker-VM
disk-full failure before tests. Only four exact, reclaimable cache IDs from this
project's earlier disposable validation runs were removed (about 1.87 GB); no
images, containers or volumes were removed. The final streamed retry passed.
The [cleanup record](../validation/results/experiments/stage5-review-owned-cache-cleanup.json)
and retained failure logs preserve this environment failure separately from
driver correctness. A generic cache prune was not used.

The sole retained failure is the frozen timeout-reuse expectation conflicting
with safe retirement. [Live results](../validation/RESULTS.md) identify the
complete current Mac capture, timings and any open investigations. The review
captures below retain their original working-tree fingerprints.

## Final pre-publication Mac confirmation and performance

The final full Mac capture records **694 PASS / 1 known FAIL / 4 UNSUPPORTED / 2 unavailable**, with all 141 CDC checks, both inherited suites and all 636 published passes protected. All **47 runnable benchmark profiles** have **seven process repetitions and two warmups per process**. The two preceding complete CDC captures use the same final source. All three CDC captures have no >5% timing or allocation investigation.

Final executable fingerprint: `fcf5026a5b1e70ef66e2f60e0e2e20b611dcf34eb838672f9c59514e3211cba6` (165 inputs). The final Linux run matches every input hash. The [review confirmation manifest](../validation/results/stage5-review-confirmation.json) retains current evidence, earlier failures, source reconstruction and environment records.

The table compares the immutable first CDC capture with the declared final full capture. Times are **nanoseconds per stated unit**; lower is better. Change is `(current / baseline - 1) * 100`.

| Profile / unit | Baseline ns | Current ns | Change vs baseline |
|---|---:|---:|---:|
| Single-table decode / row | 454.90 | 447.00 | -1.74% |
| Interleaved decode / row | 537.80 | 490.20 | -8.85% |
| Sparse update / row | 805.00 | 789.20 | -1.96% |
| Compressed decode / row | 1,897.00 | 1,789.00 | -5.69% |
| Framing and CRC32 / event | 1,242.50 | 1,122.75 | -9.64% |
| Live delivery / row | 4,192.00 | 3,898.00 | -7.01% |
| Live checkpoint / group | 13,890.00 | 11,500.00 | -17.21% |
| Retention including GC / row | 639.99 | 604.29 | -5.58% |

Current CDC allocation changes range from unchanged to **+2.77%** relative to the first capture; none exceeds the investigation threshold. Sparse-update allocation is effectively unchanged. The million-row measured live heap is **83,992–86,240 bytes**, with no growth between 1,000 and 1,000,000 rows within each measured pass. All required warmup/measured heap checkpoints pass.

The first full fixes capture used a separate bitmap population count for resource budgets. It passed correctness but raised CDC timing signals (single-table +5.14%, sparse updates +6.96%) and a >20% ordinary parallel-read alarm. It remains retained with exit 1. The final budget path reuses the first decoded image, computes its allowance only when another change follows, and avoids both a second bitmap scan and redundant first-row end checks. Limits and workloads are unchanged. Large SQL classification also avoids copying/uppercasing the entire query.

The final full run exits 0, has no >20% original-baseline timing alarms and no allocation investigations. Native/reuse/CDC profiles have no >5% timing signals. **Two deferred ordinary workload/reference signals remain open**: text writes versus the original baseline (+5.92%) and four-reader scans versus the accepted reference (+13.02%). Earlier ordinary timing outliers remain evidence; this CDC optimization does not establish that their causes were fixed. No accepted performance reference advances.

These measurements preceded implementation commit `ba99d8c` and retain their
working-tree identity. The default for future driver development is **main**
unless Anton explicitly requests a new branch. Later API work requires separate
approval.

## Committed review-fix publication — 8 November 2026

The fresh full run on implementation commit `ba99d8c` completed with exit 0:
**694 PASS / 1 known FAIL / 4 UNSUPPORTED / 2 unavailable**. All 141 Stage 5
checks, including 58 review regressions, both inherited suites and every one of
the 636 previously published passes succeed. All 47 runnable benchmark profiles
have seven process repetitions and two warmups per process. The executable
fingerprint is unchanged from the final review capture; all 165 file hashes
still match the successful Linux profile.

This publication has no >20% original-baseline timing alarms, allocation
investigations or >5% native/reuse/CDC timing signals. Five deferred ordinary
timing/reference signals remain: Haskell text latency (+5.36%), Haskell text
writes (+7.75%) and Connector/C narrow text reads (+6.53%) versus the original
baseline; Haskell four-reader scans (+19.12%) versus the accepted reference; and
Haskell sixteen-reader scans (+5.34%) versus the previous publication. Earlier
measurements remain retained; no performance reference advances.

The [publication manifest](../validation/results/stage5-review-publication.json)
links the committed inputs, raw results, process log, acceptance checks and
matching Linux evidence. The [live results](../validation/RESULTS.md) contain the
current comparison tables. A subsequent results/documentation-only commit
publishes these measurements without claiming another source execution.
