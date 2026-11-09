# Stage 6 follow-up code review — 9 November 2026

**Historical review: two P1 reliability defects and one P2 validation defect.**
All three findings are corrected in the current uncommitted working tree after
Anton requested fixing them and running the full documented validation. The
original reproductions below retain the source identity and failures found by
the review. See the resolution record at the end for the corrections.

Reviewed input fingerprint:
`413b8f4e267ca8b749b9da72c0fda6e3523bb4e638c4b45d04d7ddbda359a050`
(172 files; parent `1516216`). The [review manifest](../validation/results/stage6-review.json)
records source identity, probe results and evidence hashes.

## S6-R1 · P1 · Repeated cancellation skips cursor cleanup

**Location:** `src/Database/MySQL/Base.hs:889–891`, `withOpenedCursor`.

The bracket restores asynchronous exceptions around the whole `closeCursor`
call. A pending second cancellation can therefore arrive before `closeCursor`
enters its own mask and installs its protected cleanup. The exception escapes
without statement RESET or transport retirement. A connection can remain
`Streaming` after its owning thread exits.

The [standalone probe](../validation/results/experiments/stage6-review-cursor-cancel.hs.txt)
prepares a statement, enters `withCursor`, blocks its body and delivers
`ThreadKilled` twice. **All 10 repetitions leak cleanup:** two writes (PREPARE
and EXECUTE), zero transport closes, connection still `Streaming`. The
[output](../validation/results/experiments/stage6-review-cursor-cancel.log)
retains every repetition. The statement intentionally has a longer lifetime
than the cursor; an outer statement bracket must not be required to repair
`withCursor`'s own cleanup guarantee.

**Required correction:** enter cleanup while masked, install exception and
deadline handling, and restore the caller's masking state only inside that
protected action. Share this mechanism between explicit cursor close and both
cursor brackets. Preserve cancellation, bounded cleanup and terminal retirement.
Add repeated-cancellation regressions for both `withCursor` and
`withCursorStream`; existing tests only cover acquisition, fetch and cleanup
I/O deadlines separately.

## S6-R2 · P1 · Compression breaks semisynchronous CDC acknowledgements

**Locations:** `src/Database/MySQL/Protocol/Compression.hs:78–80`; its interaction
with the manual ACK at `BinLog.hs:181` and automatic ACK at `BinLog.hs:272`.

The new compressed writer uses the exchange's advancing sequence counter for
every write. Existing CDC ACKs call `mysqlWrite` directly, without the command
reset used by `sendCommand`. MariaDB receives semisync ACKs as independently
reset exchanges; the compressed ACK is consequently numbered incorrectly.

On a disposable **MariaDB 12.3.3** instance, changing only the existing
`stage5.live-semisync-ack` test's connection to enable compression causes
**`writer did not resume after ACK`**. The unchanged uncompressed test passes.
A diagnostic compressed variant that resets compression immediately before the
ACK also passes, confirming the sequencing cause.

The [compressed test variant](../validation/results/experiments/stage6-review-cdc-compressed.patch),
[failure](../validation/results/experiments/stage6-review-cdc-compressed.log),
[uncompressed control](../validation/results/experiments/stage6-review-cdc-uncompressed-control.log),
[reset control variant](../validation/results/experiments/stage6-review-cdc-reset-control.patch)
and [successful reset-control output](../validation/results/experiments/stage6-review-cdc-reset-control.log)
are retained. Each run uses the existing disposable fixture; the managed server
and its configuration were unchanged. The server sources confirm the contract:
`semisync_master_ack_receiver.cc` clears the receiver's NET before an ACK,
`semisync_slave.cc` clears it before sending, and `semisync_master.cc` resets
packet counters after a synchronizing flush.

**Required correction:** explicitly integrate compression with replication ACK
sequencing for both acknowledgement modes. Cover multiple acknowledgements,
continued reads, buffering and reconnect/resume, rather than relying on the
single diagnostic reset as a complete fix. Retain strict compressed sequence
validation for ordinary commands. Until supported, an incompatible combination
must be rejected explicitly rather than appearing to acknowledge successfully.

## S6-R3 · P2 · The heap test accepts whole-source buffering

**Location:** `validation/hs/Validation/Stage6Bench.hs:30–41`.

The retention workload allocates one 64 KiB chunk and returns slices of that
same storage for the entire logical 64 MiB upload. Retaining every chunk still
retains only one payload allocation plus a small list. This cannot distinguish
incremental uploading from buffering the complete input first.

The [negative control](../validation/results/experiments/stage6-review-heap-negative-control.patch)
inserts `S.toList source` before any upload and then replays the materialized
list. All value assertions and **the real `verify_heap` guard still pass**.
The measured final live heap is only **278,832 bytes** despite materializing all
64 MiB of logical input. The
[output](../validation/results/experiments/stage6-review-heap-negative-control.log)
retains all twelve checkpoints. Its elapsed time is not benchmark confirmation.

This finding does not demonstrate a buffering leak in the current driver.
It invalidates the claim that this workload would catch one. The earlier
183–216 KiB observation remains an accurate measurement of an aliased source.

**Required correction:** allocate fresh payload storage inside each producer
read, using IO allocation so the compiler cannot hoist it. Require a deliberately
buffering control to fail the retention guard, then repeat the real driver
measurement before freezing the baseline. Check every checkpoint against the
allowance, not just final-minus-first heap. Keep live heap distinct from total
allocation and process high-water memory.

## Checks and limits of this pass

- Re-ran all **153 Python validation-policy tests**: pass.
- Reproduced cursor cleanup loss, compressed CDC ACK failure and the heap
  guard's false acceptance using temporary probes and isolated test copies.
- Verified that all **172 executable input hashes remain unchanged**.
- Left original/accepted/feature baselines and the live full report unchanged.
- No final benchmarks were collected; the idle-window confirmation remains
  pending. The 8 November full Mac/Linux results remain historical evidence
  for their existing cases, which do not cover these reproductions.

The public API comments explain the main ownership and lifetime contracts well.
The fixes should preserve that standard and document why masking and replication
sequence resets differ between their respective execution phases.
Also correct the stale framing comment at `Connection.hs:331`: it says ordinary
exchanges never use policy 256, although compressed ordinary commands now do.

## Resolution — 9 November 2026

- **S6-R1 fixed:** both cursor brackets call the same masked `cleanupCursor`
  helper as explicit close. Cancellation is restored inside its timed failure
  handler. Two regression cases each deliver repeated cancellation twenty times,
  covering scalar and actually streamed parameters without an outer statement
  bracket. The connection must be synchronized or terminally retired.
- **S6-R2 fixed:** manual and legacy on-read ACKs share `sendSemiAck`, which
  resets outgoing compressed numbering without discarding incoming buffers.
  A dedicated semisync receive policy follows MariaDB's
  `pkt_nr_can_be_reset` behavior for interleaved directions. Ordinary commands
  and replication without ACKs keep strict compressed sequence validation.
  Live regressions exercise three acknowledgements, duplicate manual ACKs,
  legacy automatic ACKs and reconnect/resume; server counters require three
  acknowledged commits and zero fallback commits. Another case checks buffered
  incoming packets survive an ACK. The stale framing comment is corrected.
- **S6-R3 fixed:** each retention-source read allocates fresh payload storage in
  IO. A separate deliberately buffering consumer uses the same producer and all
  twelve checkpoints; the real Python publication guard must reject its output.
  The allowance is checked at every checkpoint, including temporary growth that
  disappears before the final point. Its live heap now reaches about 64 MiB and
  is rejected. The original aliased-source measurement is not reused as proof.

All **95 Stage 6 correctness cases** and **155 policy tests** pass in the focused
confirmation. Public Base/BinLog Haddock remains 106/106 and 41/41. The first
independent thirteen-profile wire-feature capture has seven repetitions and a
fresh-source live heap range of 182,952–281,584 bytes across 84 checkpoints.
This new reference preserves every earlier baseline. Final Mac and matching
Linux checks record **793 PASS / 1 known FAIL / 0 UNSUPPORTED / 2 unavailable**.
Both complete Mac runs measure all 60 profiles seven times and exit 0. The
second supplies the refreshed live report; working-tree provenance passes.
Six ordinary timing/reference, two reuse and three wire-feature timing signals
remain open in that capture. Native/CDC timing and all allocation investigations
are absent; no >20% same-workload alarm occurs. These are measured investigation
signals, not waived acceptance criteria. The [final checkpoint](STAGE6_IMPLEMENTATION.md#final-review-fix-validation--9-november-2026)
and [confirmation manifest](../validation/results/stage6-confirmation.json)
retain both captures. Changes remain uncommitted on main.
