# Stage 7: external authentication and timeout-contract correction

Approved 9 November 2026. Work starts on main at `7b92ded`; changes remain
uncommitted for review. All earlier baselines and performance investigations
remain intact.

## Contracts

- PAM uses MariaDB's `dialog` and `mysql_clear_password` client protocols.
  Applications explicitly provide a callback; the driver never opens a terminal.
  Cleartext replies require TLS or a Unix socket. Prompts/replies, rounds and
  token sizes are bounded; callback failures/cancellation close establishment.
- GSSAPI uses the operating system provider and existing Kerberos credentials,
  with explicit server-principal pinning, mutual authentication and no delegated
  credentials. Native contexts/buffers belong to one worker and are always
  released; cancellation never closes a context during a native call. Native
  work may finish after cancellation, but cannot write to the retired socket.
- Existing password connections retain their current APIs and fast path. New
  authenticated constructors accept callbacks/principal configuration without
  storing credentials in the established connection or resource-options record.
- Authentication fixtures use an owned disposable MariaDB/Kerberos/PAM setup.
  They do not modify host PAM policies, OS users, default ticket caches or trust.
  Missing explicitly requested fixtures are failures, never successful skips.
- Anton explicitly approved correcting `reliability.timeout-before-metadata`:
  assert retirement, command rejection and health of a fresh connection after
  cancellation. Keep its original ID, SQL, timeout and frozen historical baseline.
  Reports identify a test-contract correction separately from driver improvements.

## Validation

Protect all 793 published passes; add literal malformed/multi-round/auth-switch
checks and real PAM/Kerberos success, rejection, cancellation and resource cases.
Exercise the same client APIs on Mac and Linux. Run policy/unit/integration
checks, review the implementation, then one complete stable-source run of the
existing correctness and 60-profile benchmark workflow. Preserve every attempt
and all original/accepted/native/reuse/CDC/wire-feature references. Record setup
costs independently; ordinary query workloads remain unchanged.

## Protocol sources

The checked-out MariaDB server sources are the protocol reference:
`plugin/auth_dialog/dialog.c`, `include/mysql/auth_dialog_client.h`,
`plugin/auth_pam/`, and `plugin/auth_gssapi/`.
See also the official [PAM documentation](https://mariadb.com/docs/server/reference/plugins/authentication-plugins/authentication-with-pluggable-authentication-modules-pam/authentication-plugin-pam)
and [GSSAPI documentation](https://mariadb.com/docs/server/reference/plugins/authentication-plugins/authentication-plugin-gssapi).

## Progress

- [x] Record the approved timeout contract and preserve the original baseline.
- [x] Implement bounded external authentication and public API documentation.
- [x] Provision isolated PAM/Kerberos fixtures; replace unavailable placeholders.
- [x] Add protocol, live, failure/cancellation and policy regressions.
- [x] Review, fix and validate on both platforms; refresh the complete live report.


## Public API and deployment

Existing connection constructors keep external authentication disabled. Use
`connectWithAuthentication` (TCP), `connectUnixSocketWithAuthentication` or
`Database.MySQL.TLS.connectWithAuthentication`, with explicit `ConnectionOptions`,
`AuthenticationOptions` and the existing `ConnectInfo`. Greeting-returning
variants are available for each transport.

For a single-password PAM service, set
`authenticationDialog = Just (passwordDialog secret)`. For username/PIN/MFA
conversations, supply a callback accepting `DialogPrompt`; it exposes the prompt
bytes, echo mode, last-question flag and zero-based question index. The helper
refuses a second factor rather than resending the first password. Only TLS and
Unix sockets admit these replies. A server's empty `dialog` switch first receives
a zero-byte acknowledgement; no password is sent until an actual question.
Question/reply text is bounded to 65,535 bytes, individual authentication tokens
to 1 MiB, and the conversation to sixteen exchanges. Embedded NULs are rejected
rather than silently truncating a credential. There is no terminal/UI fallback.

For Kerberos, set `authenticationGSSAPIPrincipal` to the exact server principal,
for example `Just "mariadb/db.example@EXAMPLE.TEST"`. Acquire credentials through
the operating system first, optionally selecting a process-specific ticket cache.
The driver never performs a password-based `kinit`, delegates a TGT, changes the
host realm configuration or silently trusts a principal supplied by a server.
It verifies completion of the native mutual-authentication context before the
SQL OK. Continuation payloads cannot masquerade as a terminal OK.

GSSAPI requires the application to be linked with `-threaded`; otherwise it
fails before acquiring native credentials. Each context belongs to one provider
worker. Cancellation stops waiting for native work and closes establishment;
that worker can finish an OS KDC request later, then release its context without
accessing the retired socket. The OS Kerberos retry policy still bounds that
background native request. Native provider failures become `AuthException` with
numeric diagnostic codes; tokens, passwords and cache contents are never logged.

macOS uses the system GSS framework. Linux builds need the GSSAPI development
headers/library (`libkrb5-dev` on Debian/Ubuntu). The small `cbits/gssapi.c` bridge
only owns native GSS objects/buffers; query/protocol processing remains Haskell.
Ordinary Windows builds do not link Unix libraries; Windows GSSAPI/SSPI is outside
the validated Mac/Linux provider and fails explicitly. No Windows/Nix validation
claim is made by the Mac/Linux records.

## Reproducible fixtures and measurements

`python3 validation/check.py --working-tree` prepares an owned, loopback-only
Docker fixture automatically unless fixture settings are supplied explicitly.
It requires the managed MariaDB server to pass preflight first. The fixture owns
its PAM policies, deterministic test module, Kerberos realm/keytabs, private CA
and MariaDB server. Per-process temporary ticket caches are removed on exit;
host PAM, OS accounts, default credentials and trust stores stay unchanged.
Missing fixtures now fail actual feature checks rather than returning an
unavailable placeholder. Docker BuildKit and Linux CI use an explicit disposable
image marker; they do not depend on the presence of `/.dockerenv`.

The original 60 query/native/reuse/CDC/wire profiles remain unchanged. Three
additional profiles measure complete connect/authenticate/initialize/SELECT/close
operations, including fresh TLS-parameter/CA setup where applicable, with ten
verified connections per process, two warmups and seven
independent process repetitions. PAM uses TLS; GSSAPI uses TCP with a pre-acquired
service ticket. Those different security/transport workloads are not compared
against each other, and KDC ticket acquisition is excluded. Their separate first
capture under `validation/baselines/macos-arm64-external-authentication/` is
immutable. A different fixture-image identity withholds performance deltas.
The full wrapper embeds and independently verifies these measurements and all
prior feature suites; a full current run therefore has 63 runnable profiles.

## Review corrections and development evidence

The real-server pass exposed two details missing from the first literal probe:
later plugin packets carry an AuthMoreData wrapper, and PAM can send an empty
plugin switch requiring an empty client acknowledgement before the first prompt.
Both are corrected with independent wire regressions. A further review tightened
terminal OK handling, verified native-context cleanup under cancellation, and
required the threaded RTS before native credential access.

Initial fixture setup failures are retained: absent GSSAPI server package,
Docker-VM disk pressure, tmpfs extraction through Docker's archive endpoint, and
a BuildKit container-marker assumption. Only exact task-owned build caches were
removed; application resources were untouched. Disposable database data uses
tmpfs in the local Linux evidence build. These setup failures are not driver
passes and remain separate from the successful validation records.


## Final security review

Two additional security findings were reproduced and fixed before final
publication:

1. Unexpected authentication responses could expose raw packet bytes in an
   exception. A synthetic-token regression fails before the fix and passes after
   it; authentication now uses bounded `AuthException` diagnostics.
2. A configured GSSAPI principal originally permitted a password-only SQL OK
   before GSSAPI negotiation. The independent early-OK probe fails before the
   fix. The pin now **requires GSSAPI**, rejects alternate methods/continuations,
   and suppresses the initial password proof on TCP, TLS and Unix constructors.
   A socket fixture independently inspects the initial client-authentication
   bytes and verifies the empty password field. Password-only accounts cannot
   satisfy this requirement; Kerberos TCP/TLS and wrong-identity checks still pass.

The native provider acquires an explicit Kerberos-only initiator credential
lease, so SPNEGO does not broaden the credentials available to the conversation.
That lease, the context, output tokens and imported principal have one worker
owner and are released together. GSSAPI authentication does not wrap subsequent
MariaDB query packets; use TLS when transport confidentiality/integrity is needed.

The first complete capture (829 passes, 63 profiles) remains historical. A
subsequent capture was stopped for the principal-policy correction. Final-source
validation adds the redaction and method-enforcement regressions; no older run is
relabeled as measuring the later source. These repeats followed code fixes,
not selection of favorable timing samples. All references remain immutable.

Authentication measurements target the owned fixture server, identified by its
immutable image identity and hashed fixture configuration. The shared recorder's
ordinary server metadata also describes the managed control server; do not
attribute its binlog/session settings to the separate authentication fixture.


## Stable authentication benchmark identity

Docker generated different provenance-index IDs for identical fixture rebuilds,
so earlier complete captures conservatively withheld the new
authentication timing deltas. The final recorder fingerprints the actual runtime
filesystem, architecture and execution configuration, excluding provenance-only
IDs. Fresh-fixture validation confirms a stable identity across rebuilds.

The original authentication baseline remains byte-for-byte unchanged. Only its
exact historical index has a verified alias: retained first/current build logs
identify the same configuration digest, and the extracted full configuration
blob hashes to that digest. Its filesystem and execution fields reproduce the
runtime fingerprint. Unknown indexes and different runtimes do not match. The
proof, configuration blob and both logs are mandatory fingerprinted inputs;
publication independently verifies them. This repairs comparison bookkeeping
without advancing a performance reference or changing any measured value.

## Pre-review validation — 9 November 2026

Before the follow-up review, complete Mac run 4 supplied the live report. Its
uncommitted main inputs have parent `7b92ded` and fingerprint
`c2e48f1c67af0255eea4bedf627b7099f71ff5a67b8f6176be072dbd01bb513e`
(198 files). The exact same inputs pass the Linux profile. Both record
**833 PASS / 0 FAIL / 0 UNSUPPORTED / 0 unavailable**, including all 37 new
authentication/security cases, all 793 previously published passes and both
inherited aggregate suites. The original PAM/GSSAPI inventory checks now
exercise real client authentication. The timeout check passes the approved
retirement contract; it is not counted as a driver fix.

All **165 policy tests** pass on both platforms. A separately linked
non-threaded client verifies rejection before native credentials are acquired.
Haddock covers Authentication 5/5, Base 114/114, BinLog 41/41 and TLS 8/8 public
symbols. The source-distribution archive contains the exact tested native bridge,
authentication modules and validation helpers.

The Mac capture completes with exit 0 and measures **63 runnable profiles with
seven repetitions**: 24 original, eight native, seven reuse, eight CDC, thirteen
wire-feature and three authentication profiles. The two historical frozen
benchmark placeholders remain in the recorder; the independently measured native
profiles cover those implemented APIs. Linux smoke-tests all 39 additive paths;
its timings are not compared with Mac baselines.

| Authentication workload | First capture ms/connection | Current ms/connection | Change vs first capture | Current allocated bytes/connection |
| --- | ---: | ---: | ---: | ---: |
| PAM single password over TLS | 45.2593 | 45.7168 | +1.01% | 2,146,041 |
| PAM two questions over TLS | 45.7259 | 45.5451 | −0.40% | 2,195,458 |
| GSSAPI cached service ticket over TCP | 3.9418 | 3.8634 | −1.99% | 266,417 |

Change is `(current / first capture − 1) × 100`; lower time is faster. PAM
includes fresh TLS-parameter/CA loading, and the GSSAPI profile excludes ticket
acquisition. These different transport/security workloads are not alternatives
with equivalent costs. Verified runtime identity makes all three deltas usable;
their timing and allocation investigations are empty. Native, reuse, CDC and
wire-feature investigation lists are also empty in this capture.

**Performance acceptance remains open.** Eight existing-workload timing signals
remain: original text latency +5.00%, text writes +8.25%, the unchanged C narrow
text read +6.57%, prepared latency +8.43% and Haskell narrow text reads +6.34%;
accepted-reference parallel-4 reads +20.44% and prepared latency +12.38%; and
previous-stage prepared latency +19.61%. There are no allocation investigations.
The accepted-reference parallel signal exceeds 20% even though the wrapper's
original-baseline alarm does not fire. No reference advances, performance waiver
or timing-only rerun was used to close this stage's functionality work.

The [confirmation manifest](../validation/results/stage7-confirmation.json)
links all selected evidence and retained earlier captures. Runs 1 and 3 are
complete historical sources; run 2 was interrupted for a security correction.
Run 4 follows the stable-identity bookkeeping repair. Source patches reconstruct
the final input set, the original authentication baseline and earlier complete
captures without relabeling their measurements. Setup failures and failing
security probes remain retained alongside the fixes.

Implementation, documentation and results remain **uncommitted on main** for
review. Publication requires a separate request. Windows SSPI, advanced CDC
lifecycles and previously deferred ordinary-workload optimizations remain outside
this stage; the Mac/Linux fixture does not certify every PAM module or realm.

## Final review-fix validation — 9 November 2026

All five findings in the [follow-up review](STAGE7_CODE_REVIEW.md) are resolved.
Authentication packet decoding now redacts malformed buffers, preserves callback
exception identity, and recognizes SQL ERR only in its original envelope.
Constructors use a pre-body authentication framing cap, then return to the
ordinary reader without adding a mutable phase check to query packets. A
clear-password challenge cannot bypass the token budget. Tooling shares one
full-run predicate, cleans up partially created owned containers, and omits
external-service startup for non-live filtered checks.

The current source remains uncommitted on main, parent `7b92ded`, fingerprint
`23d359d9d3550220aeb8532dc977df242c6a6d79319148ec1186b1f7d1870bcf`
(198 executable inputs). The final full Mac run and exact-source Linux profile
both record **844 PASS / 0 FAIL / 0 UNSUPPORTED / 0 unavailable**. All 48 Stage 7
cases pass, including 11 new driver regressions; all 833 pre-review passes are
preserved. All **173 policy tests** pass on both platforms, including eight added
review tests. Haddock remains Authentication 5/5, Base 114/114, BinLog 41/41 and
TLS 8/8; the source archive contains the exact tested driver/tooling payload.

The final full Mac capture completes with exit 0 and measures **63 runnable
profiles seven times**. Linux smoke-tests all 39 additive paths without comparing
timings across OS profiles. Authentication medians against the unchanged first
capture are:

| Workload | Baseline ms/connection | Current ms/connection | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| PAM single password over TLS | 45.2593 | 43.8153 | −3.19% | +0.10% |
| PAM two questions over TLS | 45.7259 | 44.2070 | −3.32% | +0.09% |
| GSSAPI cached service ticket over TCP | 3.9418 | 3.9270 | −0.38% | +0.96% |

These remain distinct end-to-end transport/security workloads, with fresh
TLS-parameter/CA setup included for PAM and ticket acquisition excluded for
GSSAPI. Lower time is faster; changes are `(current / baseline − 1) × 100`.
The verified runtime identity permits these deltas; authentication timing and
allocation investigation lists are empty. This single capture does not establish
a repeatable speedup.

**Performance acceptance remains open.** There are 49 ordinary workload/reference
timing signals, five reuse, four CDC and seven wire-feature signals; native and
authentication timing lists are empty, as are all allocation lists. Some
ordinary entries compare the same workload with multiple references. The
accepted-reference parallel-4 read signal is +28.84%, and previous-stage prepared
latency is +21.71%, despite no >20% original-baseline alarm and wrapper exit 0.
Unchanged C controls also slow down. The retained host snapshot records active
CPU-intensive applications; contention is a plausible contributor, not a proven
explanation for every result. No reference advances or timing-only repeat was
used to select results.

The [live report](../validation/RESULTS.md) and updated
[confirmation manifest](../validation/results/stage7-confirmation.json) select
this capture. They retain earlier failures, before-fix reproductions, complete
captures, exact historical live artifacts and source reconstruction back to the
first authentication baseline. The earlier section above is historical.
All changes remain **uncommitted on main** for review.
