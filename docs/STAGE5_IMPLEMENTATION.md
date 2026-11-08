# Stage 5: MariaDB change data capture

Implementation authorized by Anton on 8 November 2026, following the CDC proposal.
Work started from published Stage 4 `733183a` on `codex/stage5-cdc` and was left
uncommitted for review. Anton subsequently authorized merging, committing and
pushing the complete stage to main. Full macOS and Linux validation is complete;
the committed publication record below supersedes the historical working-tree
status while preserving every review capture.

## Contracts and implementation sequence

1. Validate exact event framing and CRC32 before decoding. Represent all event
   bytes without partial enumeration; distinguish decoded, ignorable and unsafe
   unsupported events. Track bounded, owned table metadata by table ID and
   invalidate it at statement/format/rotation boundaries. Preserve sparse row
   bitmaps so omitted columns cannot be mistaken for SQL NULL.
2. Add a transaction-aware stream with explicit MariaDB GTID start positions,
   complete-transaction checkpoint tokens and caller-controlled semisynchronous
   acknowledgements. Reading does not acknowledge application durability.
   Checkpoints are in-memory values; applications must persist them atomically
   with their destination writes. Resume is explicit and may replay delivery;
   this API does not promise exactly-once processing or replay ordinary SQL.
3. Keep event-at-a-time backpressure and bounded table-map/event/checkpoint
   storage. Validate limits before expansion. Cache metadata rather than
   repeatedly scanning maps or copying it per row. Separate replication
   ownership from ordinary command sequencing and retire on stream errors.
4. Add literal and real-server regressions for malformed/corrupt events,
   interleaved maps, schema changes, sparse images, transaction boundaries,
   rotation, resume, acknowledgement ordering and cancellation. Add CDC
   throughput/allocation benchmarks with a separate immutable first capture.
   Keep all 39 existing profiles and immutable/accepted references unchanged.

## Acceptance

Fix all 16 original CDC failures, replace both CDC missing-API entries with
real executable checks, and preserve all 535 published Stage 4 passes. The
contradictory frozen timeout assertion remains visible with safe retirement as
the default. Full Mac validation and a matching Linux correctness profile are
required before completion. Performance findings remain explicit; no accepted
performance reference advances automatically.

## Evidence

Preflight: local managed MariaDB 12.3.3, ROW logging, CRC32, server ID 610123.
Protocol reference: checked-out MariaDB Server `sql/log_event.h`,
`sql/log_event.cc`, `sql/log_event_server.cc` and `sql/sql_repl.cc`.
The [live results](../validation/RESULTS.md) and
[confirmation manifest](../validation/results/stage5-confirmation.json) retain
the measured outcomes, exact source hashes and earlier attempts. Final executable
input fingerprint:
`c8266d02f0496188400dea1f6929346217f44b321a7c5927f6ee149cfe9ca5e6`
(164 files). Linux verifies the same executable inputs; its timing is not compared
with macOS.

## API and migration

`openCDC connection replicaId options` dedicates a fresh connection until close,
EOF or failure. Read and acknowledge on its creating thread. Queries and other
threads cannot consume its wire. Setup resets all replication user variables in
one SET; disabled acknowledgements require no discovery query. These changes
avoid four separate setup SET round trips without relying on renderer context.

Use `FromGtid` with a validated MariaDB `GtidSet`, or `FromBinLog` with a known
transaction-boundary `BinLogTracker`. `parseGtidSet`/`renderGtidSet` handle
`domain-server-sequence` state, including full unsigned 64-bit sequences.
`resumeFromCheckpoint` selects the proven mechanism. File-started streams expose
`Nothing` for `checkpointGtids`: observing subsequent GTIDs cannot reconstruct
an unknown initial state. Persist the exported filename/position or GTID string;
stream-local acknowledgement tokens intentionally cannot be recreated or reused
on another connection. `BinLogTracker.btNextPos` is now Word64; the traditional
32-bit dump command rejects an overflowing position rather than truncating it.

`cdcEvents` exposes GTID starts, statements/annotations, row before/after images,
commit/rollback, rotation, format descriptions, GTID lists and ignorable events.
Row image lists contain present columns only, in ordinal order. Keep the present
bitmaps to distinguish omitted columns from SQL NULL. Table-map optional metadata
is retained as owned TLVs, including unknown kinds. `TableMapEvent` consequently
has a new `tmOptionalMetadata` field; positional constructor users must migrate.
Numeric binlog values retain the inherited raw signed representations; optional
signedness/charset metadata remains available for consumer interpretation.

Only a complete transaction or standalone group supplies `cdcEventCheckpoint`.
Apply events within a destination transaction/staging protocol and persist that
checkpoint atomically with the completed destination changes. Then call
`cdcAcknowledge` when manual semisync mode is enabled. Reading, parsing a row,
observing `cdcLatestCheckpoint`, or seeing a server BINLOG_CHECKPOINT event does
not establish application durability. The observer is usable only while the
stream is active. Acknowledgement is monotone and rejects foreign tokens;
repeating the same acknowledgement is idempotent. At-least-once delivery and
idempotent/transactional destination handling remain application responsibilities.

`AcknowledgeOnRead` exists only for the inherited `dumpBinLog` adapter, where it
means receipt rather than durable processing. New `openCDC` rejects that mode.
The legacy row-only adapter also cannot turn individual row trackers into safe
transaction checkpoints; use the transaction-aware API for recovery.

`CDCError` distinguishes local configuration/checkpoint misuse, semantic decode
errors, resource limits and unsupported stream features. Wire decoding retains
`DecodePacketException`; connection ownership/transport errors retain their
existing types. Local misuse sends no ACK and preserves a healthy stream.
A malformed/unsupported event or cancellation during reading/writing retires a
live connection. A standalone decoder remains terminal after its first failure.
EOF closes the connection; acknowledge inside consumption, before requesting EOF.

## Bounds and performance design

- Defaults: 4096 table IDs, 16 MiB conservative aggregate metadata accounting,
  64 MiB expanded/reassembled event bodies and 1024 bootstrap events. Metadata
  charges include wire bytes, per-column and optional-TLV overhead. Replacement
  releases the old charge; eviction cannot silently discard required maps.
- Row parsers cap each event at 65,536 images and 1,048,576 decoded values
  (before and after values both count for updates), with at most 4096 columns.
  Empty/zero-progress malformed images cannot loop forever.
- Maps expire at statement ends, queries/DDL, rotation and format changes.
  Selection of sparse-image metadata is compiled once per event/image and reused
  for its rows. Table lookup is logarithmic; there is no per-row map scan.
- CRC32 uses a shared unboxed lookup table and folds lazy chunks without
  concatenating the event. FDE checksums are verified even in NONE-mode files;
  their descriptor switches decoding for subsequent events, including old files
  and changes across rotation.
- Compressed query/row payloads use bounded incremental zlib decoding. MariaDB
  type-172 fragments enforce order, counts, declared size and one-event bounds.
  Raw wire assembly also respects the connection limit and the CDC event budget.
- There is no worker queue, transaction buffering or read ahead. Table metadata
  owns retained slices; byte-valued row fields can share event storage. Consumers
  retaining small fields should copy them rather than retain a large event.

Traditional file binlogs and MariaDB GTID resume are implemented. The negotiated
replica capability is 4, deliberately excluding the 13.2 storage-engine-binlog
GTID semisync extension. XA event groups fail explicitly rather than issuing an
unsafe ordinary-transaction checkpoint; an XA-aware destination protocol is
separate future work. Unknown non-ignorable events fail; ignorable events retain
raw bytes. Native 13.2 fragmentation has literal coverage; real-server profiles
use installed MariaDB 12.3.3 and do not claim a 13.2 server execution.

## First CDC benchmark capture

Eight additive workloads cover single/interleaved table decoding, sparse update
images, compressed rows, framing/CRC, live rows, live transaction checkpoints and
million-row retention. Each capture has seven independent processes, each with
two warmups. Checksums verify consumed values, not merely event counts.
Retention samples live heap after major GC at 1,000, 10,000, 100,000 and 1,000,000
rows in every warmup and measured operation; its timing includes those GCs.

The [first capture](../validation/baselines/macos-arm64-cdc/results.json) is
immutable. Its fingerprint is
`4341156c0b007835c97ec56975aca3733dfd4ea045622c29b110f2caa62d9aaa`.
There is no invented unchanged-driver CDC throughput comparison. All prior 39
profiles and performance references remain unchanged. The retained
[source patch](../validation/results/experiments/stage5-first-capture-source.patch)
reconstructs every one of its 161 executable inputs from `733183a`; an independent
[reconstruction audit](../validation/results/experiments/stage5-first-capture-reconstruction.json)
verifies every hash. Subsequent typed-error, bounds, API-comment and decoder
changes remain separate from that first-capture source and are measured in the
full confirmation runs.

## Review corrections and correctness evidence

Final full macOS captures and the exact-source Linux profile record **636 PASS /
1 FAIL / 4 UNSUPPORTED / 2 unavailable**, including all **83 Stage 5 checks** and
both inherited suites. The sole failure is the documented original timeout
conflict. All 535 published Stage 4 passes survive. All 18 CDC targets pass,
including the two former missing-API entries. The four remaining API inventory
gaps are cursor fetch, long-data upload, connection compression and progress
callbacks; the unavailable environments are PAM and GSSAPI.

All **143 Python policy tests pass**. Haddock documents **91/91 Base** and
**40/40 BinLog** exports. The matching Linux run uses GHC 9.4.7 and MariaDB 12.3.3
on aarch64, and also smoke-tests all native, reuse and CDC profiles. Its successful
[status](../validation/results/experiments/stage5-linux-final-status.json),
[input snapshot](../validation/results/experiments/stage5-linux-final-inputs.json)
and [raw results](../validation/results/references/stage5-linux-final.json) are
retained. A development Linux attempt failed before tests because an experimental
cached container layer reused a CA issuance index. Recreating the owned temporary
TLS fixture fixed that harness setup; its failed log remains available. The
production workflow starts with fresh fixture storage.

Review found and fixed numeric GTID overflow, stale optional-metadata ownership,
SET/ENUM storage endian handling, zero-progress rows, incomplete checkpoints,
foreign/backwards ACKs, cancellation during ACK, failure skipping in offline
streams and checksum-mode changes across files. A temporarily overstrict NULL
bitmap check rejected MariaDB's valid 0xff padding; real and literal regressions
now preserve it. Development failures remain in their run directories. The
Stage 1 setup-error fixture follows the new single SET sequence with the same
ERR-code, retirement and release assertions; no assertion was weakened.

Later review added all compressed row variants, v2 post-header extensions,
unknown types, XA rejection, fragment/checkpoint positioning, typed local misuse
and row/value allocation-budget regressions. The decoder no longer rescans the
cached metadata list to compare its length on every row event: table-map parsing
already proves that cardinality, while the row's advertised column count is
still checked. Sparse metadata selection remains once per event/image, and the
malformed-input assertions remain unchanged.

## Final review measurements — 8 November 2026

Three complete Mac captures of the final executable inputs include all **47 runnable profiles**, each with **seven process repetitions and two warmups per process**. The final two full review captures ran sequentially in the user-confirmed idle window (13:46–13:50 UTC). The second was declared current before it ran, and supplied the pre-publication live report; both complete captures are retained. Earlier structural-source captures and the two standalone CDC confirmations also remain available in the confirmation manifest. Frozen native-feature inventory placeholders remain visible; the separate native workloads exercise their implemented APIs.

The table compares the immutable first CDC capture with the final idle capture. Times are **nanoseconds per stated unit**, lower is better; change is `(current / baseline - 1) * 100`. These are measurements of this Mac/MariaDB 12.3.3 configuration.

| Profile / unit | Baseline ns | Current ns | Change vs baseline |
|---|---:|---:|---:|
| Single-table decode / row | 454.90 | 459.20 | +0.95% |
| Interleaved decode / row | 537.80 | 503.40 | -6.40% |
| Sparse update / row | 805.00 | 786.30 | -2.32% |
| Compressed decode / row | 1,897.00 | 1,760.00 | -7.22% |
| Framing and CRC32 / event | 1,242.50 | 1,120.50 | -9.82% |
| Live delivery / row | 4,192.00 | 4,100.00 | -2.19% |
| Live checkpoint / group | 13,890.00 | 12,410.00 | -10.66% |
| Retention including GC / row | 639.99 | 646.25 | +0.98% |

Both idle captures have no >5% CDC timing or allocation signal. Current CDC allocation changes range from effectively unchanged to +1.94% relative to its first capture, reflecting the later checks and error model. Measured post-major-GC live heap at one million rows is **83,992–86,240 bytes**; within each measured pass it shows **no growth between 1,000 and 1,000,000 rows**. All four checkpoints in both warmups and the measured region remain mandatory. This bounds retained streaming state in the workload; it does not claim that applications retaining delivered events use constant memory.

The earlier structural-source sparse-update captures exceeded the 5% timing threshold. Removing the redundant cached metadata-length scan eliminates that repeated work; all malformed-wire checks remain. Sparse-update timing is near its first-capture value in the final-source confirmations. Host conditions differ across windows, so the observed timing change is not an isolated causal estimate of that optimization. Earlier retention outliers remain in the record rather than being discarded.

The declared final full run exits 0, has no >20% original-baseline timing alarms and no allocation investigations. Native, reuse and CDC profiles have no >5% timing signals. **Seven stricter ordinary workload/reference timing signals remain open**, including unchanged Connector/C controls and Haskell parallel reads. Those previously deferred investigations are not marked resolved; no accepted performance reference advances.

These review measurements preceded publication: their recorded parent commit
does not contain the implementation, so their working-tree fingerprints supply
their identities. The committed publication below uses a fresh full execution.

## Committed publication — 8 November 2026

Anton authorized merging all current work into main, committing and pushing to
GitHub. Implementation `9d0eedc6ee47ac7316658c00d7825ba8f1faafa7` was merged into
main by fast-forward. The fresh full committed-input run completed with exit 0:
**636 PASS / 1 FAIL / 4 UNSUPPORTED / 2 unavailable**, all 83 Stage 5 cases and
both inherited suites passing. It preserves every one of the 535 published
Stage 4 passes. All 143 policy tests pass, and the strict publication freshness
guard confirms clean committed executable inputs.

All 47 runnable benchmark profiles have seven repetitions and two warmups per
process. This publication capture has no >20% original-baseline timing alarms,
allocation investigations or >5% native/reuse/CDC timing signals. Eight stricter
ordinary workload/reference timing signals remain open, including unchanged
Connector/C controls; no accepted performance reference advances.

The executable fingerprint remains
`c8266d02f0496188400dea1f6929346217f44b321a7c5927f6ee149cfe9ca5e6`.
Every executable input matches the successful Linux review run. The
[publication manifest](../validation/results/stage5-publication.json) retains
the fresh raw results, source identity and comparison findings. The live report
now identifies this committed implementation; the preceding review captures and
their original parent commits remain historical evidence. A results-only commit
publishes these measurements without claiming another execution.
