# Stage 7 code review — 9 November 2026

Review of the uncommitted authentication implementation, native provider,
connection constructors, fixtures, benchmark recorder and publication checks.
The reviewed main parent is `7b92ded`; all 198 executable inputs retain fingerprint
`c2e48f1c67af0255eea4bedf627b7099f71ff5a67b8f6176be072dbd01bb513e`.
Implementation and existing measured results were not changed by this review.

The review recorded five actionable findings: four P2 correctness/robustness
issues and one P3 development-workflow inefficiency. The original findings below
are preserved; all five are addressed by the subsequent fix pass described at
the end of this report. The prior complete 833-pass Mac/Linux
captures remain evidence for their existing assertions; they do not cover these
newly reproduced cases.

## 1. P2: authentication exception redaction is incomplete

Locations: [dialog parsing](../src/Database/MySQL/Connection.hs#L835),
[terminal parsing](../src/Database/MySQL/Connection.hs#L866) and
[OK decoding](../src/Database/MySQL/Connection.hs#L1292).

After an AuthMoreData packet is unwrapped, `dialogLoop` calls `isERR` on the
plugin payload. A payload beginning with `0xff` is consequently decoded as an SQL
ERR even though the outer packet was plugin data. The probe sends a non-final
question followed by an AuthMoreData-wrapped ERR-shaped token; the synthetic
private marker appears verbatim in `ERRException.errMsg`.

A second probe supplies a malformed terminal OK. `consumeOK` throws
`DecodePacketFailed`, whose displayed value includes buffered packet bytes and
the same marker. The existing redaction regression tests a different unexpected
response path and misses both cases. This does not bypass authentication, but
opaque authentication data can enter application error logs, contrary to the
new redaction contract. Only synthetic markers were used; this review did not
expose actual credentials.

Keep SQL ERR handling at the original wire-envelope boundary, reject ERR-shaped
plugin data with a bounded authentication diagnostic, and sanitize packet-decoder
failures at the authentication boundary. Preserve ordinary, correctly enveloped
server-error handling. Add regressions for wrapped ERR and malformed OK/ERR data.

## 2. P2: the 1 MiB authentication limit is applied too late and has a bypass

Locations: [switch parsing](../src/Database/MySQL/Connection.hs#L724),
[token checks](../src/Database/MySQL/Connection.hs#L784) and
[clear-password branch](../src/Database/MySQL/Connection.hs#L810).

Authentication reads use the ordinary packet decoder, whose default logical
message budget is 64 MiB. `bounded` checks the smaller token limit only after the
body is read; switch parsing also flattens the complete body before checking it.
A byte-stream probe supplies only a header declaring a 2 MiB continuation: the
driver requests its body instead of rejecting the size at the header boundary.
This permits avoidable reads, retention and copying well beyond the intended
authentication budget.

The `mysql_clear_password` branch never calls `bounded` on its challenge. A
second probe passes a 2 MiB switch challenge: authentication succeeds, the
callback runs and the password reply is emitted. Explicit opt-in and the secure
transport requirement still apply; the missing size check does not bypass them.

Apply an authentication-phase limit before packet-body reads, accounting for
wire/plugin-envelope overhead and any smaller caller budget. Validate every
external plugin branch before invoking callbacks or native code. Add header-only
rejection tests and an oversized clear-password switch regression.

## 3. P2: partial-run setup failures can replace the full report's attempt status

Location: [preflight exception handler](../validation/check.py#L304).

The new outer handler recognizes partial runs by searching raw arguments for
exact strings. It misses `--only=protocol.length-0` and a run with
`--repetitions 1`, even though the main parser treats both as partial. On an
injected fixture failure, each incorrectly calls the full report publisher.
The equivalent spaced `--only protocol.length-0` correctly makes no publication.

This falsely marks the live full-validation latest attempt as failed following
a partial development command. Earlier completed evidence is retained, rather
than deleted, but its published current-attempt status becomes misleading.

Parse the arguments once and reuse the same full-run predicate for normal and
preflight-failure publication. Test both argument spellings and sub-seven
repetition runs. Publication was mocked in this review, so the live report was
not altered by these probes.

## 4. P2: fixture ownership is registered after the fallible creation command

Location: [container creation](../validation/auth_fixture.py#L66), followed by
[conditional cleanup](../validation/auth_fixture.py#L130).

`container = owner` runs only after `docker run` returns successfully. If the
daemon has created the container but startup fails or the caller is interrupted,
the exception skips that assignment and the finalizer sees no container to
remove. The owned container can remain, with its fixture services/tmpfs if it
started. Fault injection representing that ordering confirms that no cleanup
subprocess is called; this was not an experiment creating a real orphan.

Register the exact generated identity before the creation call and attempt
idempotent cleanup even if creation returns an error or is cancelled. Keep that
cleanup independent of diagnostic-log failures and limited to the owned resource.

## 5. P3: protocol-only development runs provision the complete auth fixture

Location: [unconditional fixture scope](../validation/check.py#L336).

Without caller-supplied fixture settings, even
`--only protocol.length-0 --no-upstream --no-benchmarks` builds/checks the Docker
image and starts MariaDB, a KDC and PAM services before running the unrelated
protocol check. A mocked execution confirms that the fixture manager is called.
This adds a Docker dependency and service-startup work to focused tests which
do not consume external authentication. No timing magnitude was measured here.

Provision these services only for complete runs or selected checks/benchmarks
that actually need them. Keep real authentication fixtures mandatory for those
checks; this is an opportunity to shorten the development feedback loop.

## Verification and limits

- Re-ran the existing policy suite: **165 tests, all passing**.
- Re-ran the working-tree freshness guard: **PASS**, same executable fingerprint.
- Compiled two standalone Haskell probes against the current library. They
  reproduce the packet-limit and exception findings without a database.
- Used Python fault injection for partial-publication and fixture-creation error
  paths, and a mocked protocol-only execution for the setup inefficiency.
- Left driver code, established test assertions, baselines and the live full-run
  measurements unchanged. No full benchmark confirmation was repeated.

The [probe manifest](../validation/results/experiments/stage7-review-probes.json)
links hashed reproduction sources, outputs and build/policy logs. Suggested fix
order is exception redaction, authentication limits, publication classification,
fixture cleanup, then selective fixture startup. The previously documented
ordinary-workload timing investigations remain open; this review does not claim
a new measured query-throughput regression or certify every provider/realm.


## Review fixes — 9 November 2026

All five findings are implemented on uncommitted main. The current 198-input
fingerprint is `23d359d9d3550220aeb8532dc977df242c6a6d79319148ec1186b1f7d1870bcf`.

1. Raw plugin data no longer takes the SQL ERR path. Authentication decoder
   failures become bounded `AuthException` diagnostics. Redaction wraps decoders,
   preserving the original types of application callback exceptions and genuine
   server errors. Four new malformed/wrapped-packet probes plus server-error and
   callback-exception regressions pass.
2. TCP, TLS and Unix constructors use a separate pre-body authentication reader,
   capped at 1 MiB of plugin data plus at most 130 bytes of switch envelope, or a
   smaller caller budget. Initial switches and clear-password challenges are
   checked before credential callbacks. After login, the ordinary reader resumes
   the full caller budget; it has no per-packet mutable phase check. Header-only
   initial/continuation/caller-budget tests and a larger post-auth packet pass.
3. Setup and execution share argument parsing and the full-run predicate. Both
   spellings of `--only`, short repetition runs and interruptions are tested;
   partial failures do not publish full-run status.
4. Container identity is registered before the creation call. Cleanup verifies
   the invocation label, handles failed/interrupted starts and still attempts
   removal when diagnostic logging fails. Collision/absent-container cases are
   protected by regressions.
5. Non-live filtered checks bypass external services. Live-filter selection is
   tested against the source inventory, including substring selections. Private
   fixture configuration preserves caller settings and original arguments. A real
   protocol-only smoke run passed without Docker fixture provisioning.

The focused Mac run passes all **48 Stage 7 cases**, including **11 new driver
regressions**; all **173 policy tests** pass. Exact-source Linux correctness
records **844 PASS / 0 FAIL / 0 UNSUPPORTED / 0 unavailable**, with all 39 additive
benchmark smoke paths and 173 policy tests passing. Public Haddock covers
Authentication 5/5, Base 114/114, BinLog 41/41 and TLS 8/8 symbols.

The first local build/focused attempt hit sandbox restrictions on the Cabal log
and local socket. Re-running with the required local cache/socket permissions
passes; these attempts remain retained as environment failures. The final Mac
full capture, source proof and complete evidence are linked from the current
confirmation manifest and live report. Earlier 833-pass captures and the
pre-fix probes remain historical; their measurements are not relabeled.

The final Mac full run completes with exit 0, **844 PASS / 0 FAIL /
0 UNSUPPORTED / 0 unavailable** and all **63 runnable benchmark profiles repeated
seven times**. All 833 pre-review passes and all 793 published Stage 6 passes
remain passing. The working-tree freshness guard and exact-payload source
distribution check pass. Authentication timing/allocation comparisons have no
investigation signal; all allocation lists are empty.

Performance acceptance remains open. The capture records 49 ordinary workload/
reference timing signals, five reuse, four CDC and seven wire-feature timing
signals. Several ordinary entries refer to the same workload against different
references. The unchanged C controls also slow down, while other CPU-intensive
applications were active on the host. That pattern is consistent with contention
but does not establish the cause of each signal. No idle-host claim, performance
waiver, baseline advance or timing-only rerun is made. See the
[current live report](../validation/RESULTS.md) and
[confirmation manifest](../validation/results/stage7-confirmation.json).
