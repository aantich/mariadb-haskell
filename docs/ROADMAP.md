# MariaDB driver roadmap

Accepted sequence, 7 November 2026. This file is the continuation point for future
work. It records priorities, dependencies and completion evidence; an unchecked
item is not an implemented feature. The [live validation report](../validation/RESULTS.md)
and its original frozen baseline remain the source of measured results.

## Current stage: prepared statements and native performance

Anton approved proceeding with steps 1–2 below. Work started from published
Stage 2 `e12462a`, on `codex/stage3-native-statements`.

1. **Prepared result and statement foundations — implemented and validated.** Resolve the two
   prepared OUT failures, expose complete prepared multiple results, and provide
   connection-owned statement handles with explicit close/reset and metadata
   lifetime. Preserve the existing streaming/raw-ID APIs. Reject foreign/closed
   handles and incorrect parameter counts before sending bytes.
2. **Native MariaDB performance — implemented and validated.** Add bounded
   binary bulk execution, prepared metadata caching and extended column metadata.
   Distinguish aggregate bulk results from optional per-operation results. Never
   replay or silently split a failed batch. Cache by statement ownership and
   result shape; replace metadata on server refresh/reprepare and invalidate on
   close or terminal failure. Preserve matching metadata on statement reset,
   which does not reset server omission state. Enable only fully implemented
   negotiated capabilities.
   Measure new workloads separately while preserving every frozen workload.
3. **Safe connection reuse — future stage.** Expose session changes already
   processed internally and add `COM_RESET_CONNECTION` for clean sessions.
   Invalidate prepared handles/caches and restore required session settings.
   Resetting a session does not recover a desynchronized transport.
4. **Complete CDC — future stage.** First fix the 16 existing event/table-map/
   checksum failures. Design GTID resume and explicit acknowledgement/checkpoint
   controls alongside the event model, then implement them on the corrected
   decoder. Test rotation, transaction boundaries, corruption and recovery using
   real MariaDB logs. Move this stage earlier if the first application needs CDC.
5. **Workload-specific features — future stage.** Cursor fetch, long-data upload,
   compression, progress callbacks and PAM/GSSAPI fixtures, ordered by actual
   workloads and measured benefit. These are separate API/environment gaps.

## Timeout contract

The frozen `reliability.timeout-before-metadata` test requires immediate reuse
after cancelling `SELECT SLEEP(0.2)`. Published Stage 1's
`stage1.timeout.connection-retired` performs the same operation and requires
terminal retirement. Both expectations cannot pass unchanged. Keep retirement
as the default, retain the original failure and baseline, and document the
conflict rather than weakening assertions. Any future bounded recovery API
needs an explicit contract and independent cancellation/desynchronization tests;
it must never replay SQL or claim an uncertain transaction succeeded.

## Acceptance and continuation record

- [x] Stage 1 query correctness and Stage 2 native connections published.
- [x] Five-step sequence saved and linked from the main README.
- [x] Step 1 prepared statement/result implementation and regression tests.
- [x] Step 2 bulk/cache/extended metadata implementation and regression tests.
- [x] Existing published PASS records preserved; new feature inventory entries
      replaced with executable checks. Remaining CDC/timeout gaps stay visible.
- [x] Full unchanged suite and seven-repetition benchmarks rerun on stable
      inputs; additive native benchmarks retain checksums, allocations and all
      samples. Preserve original and accepted performance references.
- [x] Public API/migration comments and implementation evidence reviewed.

Each completed stage should add its implementation/evidence link here and leave
the next unchecked item as the resumption point. Previously deferred narrow-read,
text-write and setup-cost investigations remain open; new features do not waive
those measurements or advance the accepted performance reference.

## Stage 3 continuation checkpoint — 7 November 2026

Steps 1–2 are implemented and validated on `codex/stage3-native-statements`,
with review completed and publication authorized on 7 November 2026. Read the
[implementation/API and measured results](STAGE3_IMPLEMENTATION.md) and [live report](../validation/RESULTS.md).
Post-review Mac and Linux results: **462 PASS / 17 FAIL / 8 UNSUPPORTED / 2 unavailable**;
all 56 additive cases and 101 policy tests pass. Native bulk and metadata caching
have measured same-build benefits; ordinary-profile timing investigations remain
open, with no accepted-reference advancement. The four review issues are fixed,
including buffered cleanup deadlines, incremental metadata accounting, required
native baseline publication checks and overflow-safe bulk bounds. Dependency
JSON normalization also restores native baseline comparisons. The three new
full runs and the 38.2% large-registry diagnostic improvement are recorded in the
[review-fix evidence](STAGE3_IMPLEMENTATION.md#review-fix-validation-and-measurements).

- [x] Review Stage 3 and authorize publication using the committed-input workflow.
      The live report identifies the implementation revision tested for publication.
- [ ] Resume with **step 3 planning: clean-session reset and public session-state
      reporting**, after approval. Keep default timeout retirement; never reset
      an out-of-sync transport or silently replay statements.
- [ ] Then complete step 4 CDC before adding GTID resume/durable acknowledgement.
- [ ] Prioritize step 5 features using actual workload demand.
