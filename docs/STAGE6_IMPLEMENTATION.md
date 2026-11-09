# Stage 6: streamed parameters, cursors, progress and compression

Anton approved phase 1 on 8 November 2026. Work starts on main at `1516216`;
the implementation is now committed on main. PAM/GSSAPI, CDC's documented
advanced lifecycles and a different timeout-recovery contract are separate work.

**Current outcome, 9 November:** all follow-up findings are fixed. Complete Mac
and Linux correctness records 793 PASS / 1 known FAIL / 0 UNSUPPORTED /
2 unavailable; all 95 Stage 6 cases pass. Two full seven-repetition captures
measure all 60 profiles. The committed publication below now supplies the live
report. Read the
[final checkpoint](#final-review-fix-validation--9-november-2026) for timing
investigations and the corrected memory evidence. Earlier checkpoints below
retain their original source identity and measurements.

## Implementation and acceptance plan

1. Add connection-owned, bounded streamed binary/text parameters. Upload and
   execute share one exclusive command lease. Validate arity before consuming
   inputs, omit uploaded values from EXECUTE, preserve ordinary binding and
   never retry a partially uploaded/executed statement. Failures after upload
   begins retire the transport; server limits still apply to accumulated values.
2. Add read-only server cursors with bounded fetch batches and metadata-cache
   integration. Keep one owner until exhaustion/explicit close; protect stale
   handles, reset and transaction cleanup. Decode incrementally within each
   batch and close abandoned cursors without fetching all remaining rows.
3. Negotiate optional progress reports and parse their real MariaDB envelope
   centrally, including the string-count byte and length-encoded description.
   Callbacks run on the command owner, cannot reenter the connection, and their
   failure/cancellation retires an incomplete exchange. Default-disabled
   connections retain the ordinary read path.
4. Add optional zlib transport framing after authentication, over TCP/TLS/socket.
   Compression and ordinary packet sequences remain independent. Bound both
   frame lengths before reading/decompression; reject truncation, trailing data,
   false expansion lengths and sequence errors. Preserve raw frames when
   compression does not save bytes and cap outgoing frame working memory.
5. Replace the four unsupported inventory rows with real feature checks; add
   independent literal-wire, live-server, ownership and cancellation tests.
   Protect all 694 published passes and preserve the conflicting frozen timeout
   failure and the two unavailable authentication fixtures explicitly.
6. Add separate seven-repetition benchmarks with two warmups, checksums and
   allocation evidence: streamed versus buffered parameters, cursor batch sizes
   versus existing streaming, progress disabled/enabled and compressed versus
   plain narrow/wide transfers. Preserve existing workloads/references and avoid
   claiming cursors/compression always improve performance.
7. Review/fix, run Python policy tests, Haddock, complete Mac correctness and
   benchmarks, and matching Linux correctness. Refresh the live results and
   retain unsuccessful attempts and exact executable fingerprints.

## Protocol evidence

Implementation checks the local MariaDB server `sql/sql_prepare.cc`,
`sql/sql_cursor.cc`, `sql/protocol.cc`, `sql/sql_connect.cc` and
`sql-common/client.c`. Notably, compression starts after plugin authentication;
long-data commands have no reply; cursors may require a final empty fetch; and
progress reports use a special ERR marker without being command failures.

## Public APIs and lifetime

Use `PreparedValue` for ordinary values, `PreparedBytes` for a one-shot byte
stream and `PreparedText` for a one-shot text stream. Each execution has exactly
one entry per placeholder. An empty stream binds an empty non-NULL value; use
`PreparedValue MySQLNull` for SQL NULL. Text uploads retain text type/collation;
binary uploads retain BLOB semantics. Sources are caller-owned: the driver
neither closes them nor rewinds/replays them.

```haskell
withPreparedStatement conn "INSERT INTO documents(body) VALUES(?)" $ \statement ->
    executePreparedStream statement [PreparedBytes source]
```

`queryPreparedStream` returns one incremental row stream;
`queryPreparedStreamMulti` materializes complete results including OUT values.
`openCursorStream` and `withCursorStream` use the same one-shot parameters with
read-only cursor fetching, including on compressed connections.
Text sources are encoded in bounded pieces using the current client charset.
Upload commands contain at most 64 KiB of payload (less under a smaller message
limit). Small source chunks are coalesced, retaining at most one wire chunk and
1024 source segments; large chunks are sliced without copying.
`maximumLongDataBytes` defaults to 64 MiB across all uploaded parameters
in one execution, additionally bounded by the observed server packet limit.
Chunking does not remove MariaDB's accumulated-value limit. The upload's
no-reply protocol means errors can be deferred until EXECUTE.

`withCursor statement values action` brackets a read-only server cursor.
`openCursor` also returns its column definitions for explicit lifetime control.
`fetchCursor cursor count` returns a stream for one batch; consume that stream
before requesting another. `cursorExhausted` observes local exhaustion without
SQL. An exact-sized last batch can require a final empty fetch. The default
`maximumCursorFetchRows` is 65,536; fetch size zero is invalid.

The creating thread owns the connection for the entire cursor lifetime. Other
commands and statement/session reset are rejected while it remains open.
`closeCursor` drains only the pending batch and sends statement RESET, releasing
the remaining server cursor without fetching every remaining row. Cleanup has
one deadline, propagates cancellation, and retires uncertain transport state.
After terminal connection failure/close, cursor close is a local no-op.
Metadata remains cached as required by MariaDB's RESET/omission behavior.

Server cursors can materialize results in temporary tables and add round trips.
Ordinary `queryPrepared` already streams: cursors provide explicit server fetch
control, rather than a universal memory or speed improvement.
The read-only cursor flag is not a SQL authorization check. Use this API for
SELECT statements; MariaDB can execute other SQL before reporting that it did
not open a cursor. Complete non-row replies and additional results are drained
before a synchronized local error, while malformed reset replies retire the
connection.

## Optional connection features

Both options default to false. Existing callers should construct options by
updating `defaultConnectionOptions`, which also supplies the new resource bounds.

```haskell
conn <- connectWithOptions defaultConnectionOptions
    { enableCompression = True, enableProgressReporting = True } info
setProgressCallback conn (Just print)
```

Progress negotiation and callback registration are separate. Reports are
consumed when no callback is installed. `Progress` contains one-based stage and
stage-count fields, a 0–100000 within-stage value (100000 = 100%), and an owned
description in server-encoded bytes. Reports are informative, not a success or
completion guarantee. Callbacks run synchronously on the command's thread.
Reentering command, stream or cursor operations is rejected. A callback failure
or cancellation retires an incomplete exchange. There is no background queue.
Callback replacement requires an idle connection and sends no SQL.

Compression negotiates zlib with the server and starts **after** plugin
authentication. It works above TCP, TLS and Unix sockets. Inbound compressed and
expanded lengths are checked before reading/inflating a frame. Expansion must
match its advertised length exactly, with no trailing stream. Both are bounded
by the client message budget plus the ordinary header, capped at 16 MiB-1.
Outbound frames have at most 64 KiB of ordinary wire bytes; compression is tried
at `compressionThresholdBytes` (default 1 KiB), and a raw frame is used unless
compression saves bytes. Frame lengths and sequencing remain validated.

MariaDB's `net_flush` can synchronize ordinary packet numbers to its compressed
frame number. As in Connector/C, compressed mode validates the compressed
sequence instead of requiring uninterrupted ordinary packet numbers across
flushes; logical continuation order is still checked. A connection without
negotiated compression retains the original ordinary sequence policy.

TLS remains the confidentiality/authentication mechanism. Compression is a
workload choice: it reduces transfer bytes for compressible data, but costs CPU
and allocations and can hurt local latency. It does not compress stored tables.

## Validation and measurement design

The four original inventory entries now invoke real public-API feature checks.
The new literal-wire, live-server and fault cases cover upload omission and
chunk order, empty/NULL/text/large values, source errors and cancellation,
statement ownership and reuse, cursors with legacy/cached metadata and exact
batch boundaries, close/reset/transaction cleanup, callback failures/reentry,
malformed progress envelopes, compressed byte splits/lengths/trailers/sequences,
pre-body expansion bounds and real 16 MiB continuation transfers. A transparent
loopback byte counter independently checks actual server-to-client wire savings.

Thirteen additive profiles retain two warmups and seven independent repetitions:
streamed/buffered uploads, ordinary streaming versus cursor batches of
32/512/4096, narrow/wide plain versus compressed reads, and progress negotiation
disabled/enabled. Upload payload generation and server byte verification are
timed equally; a fresh IO allocation prevents pure payload construction from
being hoisted out of measured runs. Cursor opening/materialization is timed;
connection and statement preparation are excluded for all alternatives. The
progress profile measures the negotiated read path without emitted reports;
real callback delivery is covered by ALTER TABLE correctness tests.

A separate 64 MiB upload profile checks live heap after major GC at 64 KiB,
1 MiB, 16 MiB and 64 MiB during each warmup and measured upload. Its retained
heap must stay within the same fixed 2 MiB streaming allowance used by CDC;
this is live memory, separately from allocation and process high-water memory.

The original 47 profiles and every immutable/accepted reference remain intact.
The first new feature capture is a separate baseline, not an advancement of an
existing performance reference. The full wrapper and freshness guard require
complete current Stage 6 evidence. PAM/GSSAPI remain explicit unavailable
fixtures, and the historical timeout conflict remains visible.

## Validation checkpoint — 8 November 2026

Initial implementation and validation completed on **main**, with all changes left
uncommitted. The final executable input fingerprint is
`413b8f4e267ca8b749b9da72c0fda6e3523bb4e638c4b45d04d7ddbda359a050`
(172 files, parent `1516216`). The
[confirmation manifest](../validation/results/stage6-confirmation.json) records
artifact hashes and remaining work. The [source reconstruction](../validation/results/experiments/stage6-final-source-reconstruction.json)
verifies every input by applying the retained patch to the parent commit.

**Follow-up review, 9 November:** the [review report](STAGE6_CODE_REVIEW.md)
reproduces repeated-cancellation cleanup loss, incompatible compressed semisync
ACK sequencing and a heap workload that cannot detect whole-source buffering.
These were fixed before the final captures below. Existing passing case records
remain intact; they did not cover the newly reproduced failures. The final
checkpoint records the added regressions and corrected measurements.

| Check | Result |
| --- | --- |
| Complete Mac correctness, both inherited suites included | 786 PASS / 1 known FAIL / 0 UNSUPPORTED / 2 unavailable |
| Exact-source Linux correctness, GHC 9.4.7 / MariaDB 12.3.3 | Same counts; verification profile exits 0 |
| New Stage 6 regressions | 88/88 PASS on both platforms |
| Previously published passes | All 694 preserved on both platforms |
| Validation-policy tests | 153 PASS |
| Public Haddock coverage | Base 106/106; BinLog 41/41 |
| New benchmark paths | All 13 smoke checks pass on both platforms |
| Mac upload live heap through 64 MiB | 183,280–216,080 bytes at all warmup/measured checkpoints |

The [Mac results](../validation/results/references/stage6-correctness-2.json)
and [Linux results](../validation/results/references/stage6-linux-final.json)
retain complete case records. The Mac correctness-only wrapper exits 1 because
the unchanged original timeout test expects connection reuse; the published
retirement test requires the opposite. Its assertion remains intact. PAM and
GSSAPI still need their separate implementations/fixtures. All four previously
unsupported API inventory entries now pass real feature checks.

Review corrected four protocol/lifetime issues: text uploads must retain the
VARCHAR type and client collation; refused non-row cursor requests must drain
additional replies; cursor RESET must reject unexpected extra results; and
bracket acquisition must remain cancellable even with a fully buffered source.
Tests cover each, including cleanup deadlines and callback/cursor reentry.
Compressed exchanges also account for MariaDB's flush-time ordinary packet
number synchronization while retaining strict compressed-frame sequencing.

Upload coalescing reduced one 1 MiB development smoke's streamed allocation
from 5,235,256 to 2,585,344 bytes (about 51%). Buffered allocation in the latter
smoke was 1,402,536 bytes: streaming still allocates more in this workload.
Its benefit is bounded live buffering, not a guarantee of fewer total
allocations. The 64 MiB smoke checks every stored byte and all twelve live-heap
checkpoints. These are smoke observations; final timing/allocation comparisons
still require the independent seven-repetition captures.

An independent transparent byte counter observes a 1,000,071-byte plain response
versus 1,109 compressed bytes for one million repeated characters. This checks
actual transfer bytes, not query speed or realistic compression ratios for
arbitrary data. The [portable byte-counter log](../validation/results/experiments/stage6-wire-byte-savings.log)
records both counts; complete result records retain the assertion outcomes.

The [development-attempt register](../validation/results/experiments/stage6-development-attempts.json)
retains earlier failures, changed-source attempts and successful intermediate
checks. A Linux attempt exhausted Docker's disk during Cabal installation,
before correctness ran. The retry succeeded after replacing the accumulated
test-layer chain with one fresh verification layer and removing only verified,
reclaimable cache entries from our own driver validation. The
[cleanup audit](../validation/results/experiments/stage6-owned-cache-cleanup.json)
records exact IDs; images, containers and volumes were preserved.

### Final capture procedure

Anton requested continuing correctness/documentation/Linux checks and will
confirm idle time later. This was the 8 November checkpoint. On 9 November he
requested all fixes and full measurements, which are now complete under recorded
host conditions. No explicit idle-window claim is made. The full live report
now represents the corrected working tree.

All three [follow-up review findings](STAGE6_CODE_REVIEW.md) were resolved, with
regressions/negative controls and fresh correctness before these commands.

1. With the Mac idle and our Linux/Haddock jobs finished, run
   `python3 validation/stage6_benchmarks.py --output validation/results/runs/stage6-first-wire --freeze`.
   This creates a new independent reference with thirteen profiles and seven
   repetitions; never replace an existing reference. Record the new snapshot:
   the three baseline artifacts become additional validation inputs.
2. Run `python3 validation/check.py --working-tree --output validation/results/runs/stage6-full-1`.
   It must include all 60 runnable profiles, seven repetitions, checksums,
   allocations and required heap checkpoints, plus full correctness. Retain
   unsuccessful captures and investigate signals without moving references.
3. Run `python3 validation/publish_results.py --check --working-tree`, inspect
   generated Markdown/SVG/JSON, and update the confirmation/checkpoint with the
   actual measurements. The full wrapper supplies the live report; do not
   manually substitute smoke timings or partial results.
4. Leave the final implementation, evidence and report **uncommitted** for
   Anton's review. Continue on main unless he explicitly requests a branch.

## Final review-fix validation — 9 November 2026

Current fingerprint:
`dbc3c49dc9042610a46bb0c70651e7541a8d3d26fbe6641a0c367c3b192aff0e`
(176 inputs; parent `1516216`, uncommitted main). The
[source proof](../validation/results/experiments/stage6-fixes-source-reconstruction.json)
reconstructs all 173 inputs preceding the new reference; the
[baseline transition](../validation/results/experiments/stage6-fixes-baseline-input-transition.json)
proves only the three new baseline artifacts were added. Linux and both full
Mac runs hash the exact same 176 files.

| Check | Current result |
| --- | --- |
| Complete Mac correctness, both inherited suites | 793 PASS / 1 known FAIL / 0 UNSUPPORTED / 2 unavailable |
| Exact-source Linux correctness | Same counts; profile exit 0 |
| Stage 6 cases, including seven review regressions | 95/95 PASS on both platforms |
| Existing passes preserved | All 694 published and all 786 initial Stage 6 passes |
| Python policy tests | 155 PASS |
| Public Haddock | Base 106/106; BinLog 41/41 |
| Full Mac captures | Two; each has all 60 profiles, seven repetitions, exit 0 |
| Current live report | Capture 2; working-tree freshness guard passes |
| Fresh-source upload heap, current 64 MiB profile | 182,952–281,576 bytes across 84 checkpoints |
| Whole-source buffering negative control | Rejected by the actual heap guard on Mac and Linux |

The [confirmation manifest](../validation/results/stage6-confirmation.json)
links all raw results, gates, source hashes and unsuccessful attempts. The
[first full capture](../validation/results/references/stage6-full-1-live.json)
and [selected second capture](../validation/results/references/stage6-full-2-live.json)
retain every additive sample. The [Linux record](../validation/results/references/stage6-fixes-linux.json)
also smoke-tests all 36 additive benchmark paths without comparing Linux and
Mac timings. The first failed review-fix development test selected `openCDC` for
automatic ACKs, which that API deliberately rejects. Its
[exact intermediate test and provenance](../validation/results/experiments/stage6-fixes-focused-1-provenance.json)
remain retained; the corrected test exercises the supported legacy API.

The first independent [wire-feature reference](../validation/baselines/macos-arm64-wire-features/results.json)
has thirteen profiles with seven repetitions. All original, accepted, native,
reuse and CDC references remain unchanged. Each first/reference comparison
matches a workload against itself; comparisons between alternative methods in
the live table describe different techniques in the same current build.

Timing acceptance remains open. Capture 1 has four ordinary timing/reference
signals and a +5.7% TCP-reset signal. Capture 2 has six ordinary timing/reference,
two reuse and three wire-feature signals, all between 5% and 20%. TCP reset is
+11.7% in capture 2. The wire signals concern streamed upload (+5.5%), narrow
compressed reads (+6.9%) and progress-disabled queries (+6.6%) against the new
first reference, despite identical source. An unchanged C narrow-read control
is +5.8% against the original reference. Both captures remain retained; no
cause is inferred solely from timing variation and no reference is advanced.
Native/CDC timing and every allocation investigation list are empty. Neither
complete run has a >20% same-workload alarm.

Local method comparisons also expose costs: streamed upload is +3.8% in time
and +97.1% in allocation versus buffering, while keeping live buffering bounded.
Cursor batches 32/512/4096 cost +434.8%/+128.9%/+114.0% versus ordinary streaming;
server materialization and extra fetch round trips are included. Narrow/wide
zlib reads cost +118.2%/+122.6% locally versus plain transport, while the
independent byte counter proves large savings for the compressible test data.
Progress-enabled versus disabled queries differ by -5.6% in this capture; the
same-source disabled-path signal demonstrates why this small local difference
cannot establish a feature speedup. These APIs provide bounded input buffering,
fetch control, progress information and compression choices with explicit costs.

The sole retained correctness failure remains the conflicting frozen timeout
expectation. PAM/GSSAPI require separate implementation/fixtures. No commit or
push occurred; the complete diff is available for review on main.


## Committed publication — 9 November 2026

Anton authorized committing and pushing the reviewed work directly on main.
Source commit `9c4bac0cbeabc269d41ec307aa53e4f2da50f345` contains the implementation,
regressions, frozen wire-feature baseline and retained review evidence. The
[publication manifest](../validation/results/stage6-publication.json) and
[live report](../validation/RESULTS.md) record a complete run on those committed
inputs: **793 PASS / 1 known timeout-contract FAIL / 0 UNSUPPORTED / 2 unavailable**,
all 95 Stage 6 checks passing, and all 60 runnable profiles with seven repetitions.
All 176 executable file hashes match the earlier review and Linux captures.

The completed publication run exits 1 because parallel reads cross the 20%
timing threshold. Correctness and evidence gates pass; timing acceptance stays
open. Its eighteen ordinary timing/reference signals, two reuse signals and one
wire-feature signal remain visible. Native/CDC timing and all allocation
investigation lists are empty. No reference advances and no measurements are
changed. The earlier full review captures remain retained independently.

An unnecessary second publication confirmation was stopped when Anton instructed
publishing immediately; its partial log and interruption are retained in the
publication manifest. The live report presents the completed committed-input run
with its timing alarms. This publication supersedes the uncommitted status in
the historical checkpoints above.
