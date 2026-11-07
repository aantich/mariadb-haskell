# Stage 2 — native MariaDB connections and authentication

**Implementation, review and publication, 7 November 2026.** Stage 2 was reviewed as an uncommitted implementation on `codex/stage2-native-connections`, based on published Stage 1 `b1cf486`. Anton subsequently authorized committing and pushing it. The retained review windows identify their exact working-tree contents; the [live results](../validation/RESULTS.md) identify the committed inputs tested for publication. The original frozen baseline and the older accepted performance reference remain unchanged. The previously deferred Stage 1 performance work stays deferred.

## Implemented behavior

### Native handshake

Greeting, authentication and SSLRequest capabilities now retain both 32-bit words as `Word64`. Native client responses clear MariaDB's legacy-client marker and write the extension word at bytes 28–31; the greeting reads MariaDB's upper word from its reserved area. Ordinary capabilities are intersected with the server's offer, and session tracking/OK terminators remain a negotiated pair.

No unimplemented high-word extension is advertised. Bulk execution, extended/cached metadata, progress and prepared OUT-result handling remain separate work. The original prepared-OUT capability failure remains visible instead of enabling its flag prematurely.

Challenge parsing uses the declared length. Embedded NUL bytes are preserved; only a known plugin's optional terminal byte is removed when the exact expected length proves it is a terminator. Greeting parsing consumes the full packet. Initial server errors preserve their ERR diagnostic, and malformed protocol/plugin envelopes fail before credential responses are sent.

### Authentication

The supported wire plugins are `mysql_native_password`, `client_ed25519`, `parsec` and `caching_sha2_password`. These protocol identifiers are used by MariaDB; their spelling does not add a MySQL-server support target. Unknown plugins raise `AuthException` instead of silently using a different password algorithm.

MariaDB's password-based ed25519 variant expands the password into a scalar/prefix and uses crypton's constant-time Edwards operations. PARSEC separately derives a 32-byte standard Ed25519 seed with PBKDF2-SHA512, generates a fresh client nonce, and signs the server/client nonce pair. The server's independent ed25519 golden vector and real server acceptance validate these distinct paths. The implementation uses crypton's primitives rather than introducing custom curve arithmetic.

Every authentication switch carries its plugin and exact nonce together. SHA-2 full authentication therefore uses the active switch nonce, fixing the earlier TCP failure. TLS and Unix-domain sockets use the secure-transport password path; plain TCP uses the bounded RSA exchange. RSA keys are restricted to 2048–8192 bits and bounded exponents/envelopes. Signed/zero moduli, invalid exponents and non-RSA algorithm identifiers are rejected before integer conversion. Fetching an RSA key over plain TCP does not establish server identity; use verified TLS when identity verification is required.

Conversations are bounded to 16 exchanges. PARSEC's server-requested work must fit `maximumAuthIterations` (default **2^20**); invalid factors/algorithms/lengths are rejected before derivation. The option supports an explicit higher limit up to the server's 2^30 ceiling. These CPU bounds complement the establishment deadline. As with other asynchronous Haskell deadlines, cancellation is delivered at interruptible boundaries; an ongoing crypton call may finish first. Raising the work limit can therefore increase that delay.

Primary protocol references: [MariaDB connection/authentication protocol](https://mariadb.com/docs/server/reference/clientserver-protocol/1-connecting/connection), [PARSEC description](https://mariadb.com/docs/server/reference/plugins/authentication-plugins/authentication-plugin-parsec). Local server comparison used checkout `b439f350ce3`, including its ed25519 vector, PARSEC salt layout and SHA-2 transport handling.

### Transport and TLS

`connectTimeoutMicros` defaults to **ten seconds** for the entire establishment sequence: DNS, address attempts, TLS, authentication and session initialization. All socket attempts share that bound. Failed addresses release their sockets; only IO errors allow the next resolved address. Cancellation propagates immediately. Authentication/TLS failures do not trigger another address attempt or a plaintext downgrade.

TLS uses the verified subject name and preserves the caller's SNI preference. Default client parameters enable SNI; an explicit opt-out remains honored. The real TLS fixture verifies both settings while still checking the server certificate. The client-certificate helper installs its sole configured credential in the certificate-request hook, fixing mutual-TLS authentication without requiring an extra caller callback.

`mozillaCAStore.pem` is declared as Cabal package data. The validation wrapper now performs the built library's actual Cabal copy/install step before executing the suite, so the installed-data test neither depends on the current directory nor accidentally uses stale data. Installation errors/interruption produce a failed attempt. System trust remains available through `SystemCAStore`; `MozillaCAStore` is the shipped snapshot, updated through reviewed package changes rather than an implicit network download. Malformed/empty CA files fail as IO errors.

## API and migration

- Capability fields in `Greeting`, `Auth`, `SSLRequest` and the internal connection are now `Word64`; update explicit `Word32` annotations.
- Prefer `defaultConnectionOptions` with record overrides. Fully constructed/positional option values need the new `connectTimeoutMicros` and `maximumAuthIterations` fields.
- `AuthException` is available through the public Base API. Server ERRs retain `ERRException`; asynchronous cancellation retains its identity. Low-level transport failures can still be IO exceptions.
- Internal `completeAuth` callers now supply the connection, greeting and secure-transport fact so plugin/nonce state cannot drift. Applications using the public connection constructors need no call-site change.
- Existing Stage 1 ownership, rendering-context, transaction and exact-value contracts remain in effect. Read [Stage 1 migration notes](STAGE1_MIGRATION.md).

## Verification and review

All **14 targeted original failures** now pass:

| Area | Previously failing cases resolved |
| --- | ---: |
| Binary challenge, unknown plugin and native handshake | 3 |
| ed25519, PARSEC, SHA-2 and client-certificate helper | 9 |
| Address fallback and installed CA data | 2 |

There are **30 additive Stage 2 cases**. They include the independent signing vector, upper-word offsets/roundtrips, flag intersection, NUL challenges, malformed/unknown switches, bounded loops/PBKDF2, malformed SHA-2/RSA input, SNI and opt-out, peer-observed deadline/cancellation cleanup, nine wrong-password combinations, and fresh-account full SHA-2 exchanges on all three transports. Original assertions and the four frozen recorder/workload files are unchanged.

All **59 Python policy tests** pass on macOS and Linux. Added checks protect library-versus-executable installation selection, installation failure/cancellation, every published Stage 1 PASS, native targets and CI/Linux/reference fingerprints. The separate [previous-stage manifest](../validation/results/previous-stage.json) protects Stage 1 without silently advancing the older accepted performance reference.

The [Linux result](../validation/results/references/stage2-linux-complete.json) uses MariaDB **12.3.3**, Linux **aarch64**, GHC **9.4.7** and Cabal **3.14.1.1**: **401 PASS / 19 FAIL / 11 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE**. All 30 Stage 2 cases, all native targets and both inherited suites pass. Driver and actual Haskell harness source hashes match the Mac inputs. Linux timings are not compared with the Mac baseline. [Linux validation log](../validation/results/experiments/stage2-linux-validation-complete.log).

The Linux fixture initially hit the shared Docker disk limit; its database/build work was moved into task-local temporary storage without pruning unrelated Docker data. A second fixture issue came from the container's disabled name resolution conflicting with the reserved `@localhost` accounts; the disposable server now explicitly enables resolution. Its SHA-2 RSA keys are generated and configured explicitly, so full TCP authentication does not depend on automatic key creation or warmed caches. A final independent malformed-key probe demonstrated that the old RSA parser accepted negative ASN.1 integers; a new five-fixture regression ([reproduction](../validation/results/experiments/stage2-rsa-negative-reproduction.txt)) requires early rejection of signed/zero integers, invalid exponents and unrelated algorithm identifiers. The Linux readiness probe now waits for TCP, excluding the image's temporary socket-only bootstrap server and preventing provisioning during its shutdown. A wrapper review also found that the nearest Cabal Setup directory could be the executable's; it now verifies the library interface and has a regression test. Earlier attempts remain in local logs rather than being presented as successful runs.

Haddock compilation succeeds; Auth (16/16), Base (71/71), TLS (6/6) and TLSSetting (10/10) have full symbol documentation. [Documentation log](../validation/results/experiments/stage2-haddock-final.log). Existing inherited missing-symbol/link warnings remain visible. The implementation comments explain binary challenge ownership, signing differences, authentication work limits, capability layout and cancellation boundaries.

## Full Mac benchmark confirmation

The [idle confirmation window](../validation/results/stage2-confirmation.json) was declared before measurement after Anton confirmed the Mac was idle: three consecutive complete runs, seven measured process repetitions per frozen profile, all retained, with the third published as current. No competing build or Linux container ran during measurement.

All three runs and the fresh supplementary measurements use the unchanged final input fingerprint `0c4456b8f17af803344b7ad73a2b75e14c0e65c7b8d2be53be43891cd08ff6e1`. Each full run records **401 PASS / 19 FAIL / 11 UNSUPPORTED / 2 ENVIRONMENT_UNAVAILABLE** across **433 records**, with all 30 Stage 2 cases passing. Every published Stage 1 PASS and all 399 passes in the earlier development window remain passing. All 24 runnable frozen benchmark profiles complete seven repetitions in each run: **21 measured process samples per profile** across the window.

**All three full runs exit 0 and clear every original >20% timing alarm. Correctness, source/evidence and allocation gates pass.** The broad C/Haskell slowdown observed during interactive host activity is absent in this idle window. The source did not change between these windows; the difference does not establish a driver optimization or prove one particular cause for the earlier slowdown.

**Stricter performance acceptance remains open.** The >5% investigation gate reports six, six and five reference/profile signals across the three runs. Three signals repeat in every run:

| Workload / reference | Run 1 change | Run 2 change | Run 3 change |
| --- | ---: | ---: | ---: |
| `haskell/read.parallel-4` / older accepted reference | +22.4% | +12.7% | +34.8% |
| `connector-c/read.text.narrow` / original baseline | +6.2% | +7.9% | +8.0% |
| `haskell/write.text` / original baseline | +7.6% | +7.7% | +7.8% |

The parallel-read signal varies considerably between runs. The narrow C control is unchanged code; its signal remains visible alongside the Haskell results. Neither these alerts nor the previously deferred Stage 1 investigations are waived, and the accepted performance reference has not advanced.

The following table uses the **median of the three run medians**. The live results document uses the third run itself, so individual values can differ. Baseline is the original frozen unchanged-driver measurement. Change is `(current / baseline - 1) × 100`; lower time and allocation are better.

| Workload | Baseline ns/unit | Current window ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/read.text.narrow` | 305.48 | 318.84 | +4.4% |
| `haskell/write.text` | 38,324.00 | 41,269.00 | +7.7% |
| `haskell/write.execute-many` | 9,670.00 | 7,998.00 | -17.3% |
| `haskell/read.text.wide` | 2,876.43 | 2,678.50 | -6.9% |
| `haskell/read.vector.narrow` | 365.84 | 342.02 | -6.5% |
| `haskell/micro.text-row` | 313.24 | 285.99 | -8.7% |
| `connector-c/read.text.narrow` | 197.44 | 213.04 | +7.9% |
| `connector-c/read.text.wide` | 1,261.03 | 1,159.67 | -8.0% |
| `connector-c/write.text` | 28,478.00 | 28,274.00 | -0.7% |

Compared with published Stage 1, the window medians for narrow text reads and text writes are 0.9% and 0.7% lower respectively. Their remaining costs against the original fork are therefore still part of the deferred Stage 1 performance work. This comparison records observed timings; it does not isolate a Stage 2 causal effect.

There are **zero allocation alerts above 5%** against the original baseline, older accepted reference or published Stage 1 in any idle run:

| Workload | Baseline bytes/unit | Current window bytes/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `haskell/read.text.narrow` | 2,831.95 | 2,232.95 | -21.2% |
| `haskell/write.text` | 43,608.14 | 32,704.18 | -25.0% |
| `haskell/write.execute-many` | 20,261.29 | 8,330.94 | -58.9% |
| `haskell/read.text.wide` | 30,532.35 | 25,994.24 | -14.9% |
| `haskell/read.vector.narrow` | 3,136.04 | 2,352.50 | -25.0% |
| `haskell/micro.text-row` | 2,952.02 | 2,448.02 | -17.1% |

The [interactive-host window](../validation/results/experiments/stage2-busy-host-window.json) preserves all three earlier final-source runs, including every timing alarm and their raw references. It is superseded for current idle measurement, not deleted. The [first window](../validation/results/experiments/stage2-pre-documentation-window.json) and [documented pre-RSA window](../validation/results/experiments/stage2-documented-before-rsa-window.json) also remain historical evidence for their own earlier inputs.

### Supplementary measurements

The [idle supplementary run](../validation/results/references/stage2-supplementary-idle.json) uses the same final source fingerprint and seven process repetitions. These setup/helper workloads are separate from the frozen benchmark suite. Their baseline is the preserved [unchanged-driver supplementary reference](../validation/results/references/stage1-before.json). The [earlier supplementary measurements](../validation/results/references/stage2-supplementary-final.json) remain archived.

| Workload | Baseline ns/unit | Current ns/unit | Change vs baseline |
| --- | ---: | ---: | ---: |
| `connect.tcp` | 177,466.67 | 247,333.33 | +39.4% |
| `parameters.select` | 37,064.00 | 38,726.00 | +4.5% |
| `parameters.mixed` | 75,894.00 | 71,408.00 | -5.9% |
| `transaction.empty` | 63,173.33 | 65,893.33 | +4.3% |
| `batch.1000` | 11,008.60 | 10,321.80 | -6.2% |
| `stream.retention` | 351.03 | 330.35 | -5.9% |

Connection setup measures about 247 µs, compared with 177 µs in the unchanged-driver reference and 281 µs in the preserved Stage 1 supplementary run. Its remaining cost against the original fork is visible; this idle measurement does not show an additional Stage 2 slowdown.

Current live heap after GC remains bounded in the tested paths. These memory experiments have no invented pre-change baseline and are separate from timed throughput:

| Retention experiment | Median final live bytes | Maximum checkpoint live bytes |
| --- | ---: | ---: |
| `retention.10000` | 127,840 | 127,848 |
| `retention.1000000` | 127,848 | 149,664 |
| `retention.tiny-slice` | 115,656 | 118,120 |

The 100-fold row-count increase does not produce proportional retained heap. Holding one exact byte after a 16 MiB result releases the large payload in the tested path.

## Remaining work

The remaining 19 original failures consist of 16 CDC cases, two prepared-OUT cases and the original timeout-reuse expectation that conflicts with safe retirement. The 11 missing-API and two unavailable-environment entries remain explicit. Windows, other Linux architectures and other MariaDB versions need separate profiles. The Linux workflow is included for future repository CI; this local run does not claim a GitHub Actions execution.

The Stage 1 performance investigations remain open and deferred. New Stage 2 costs are still reported against the immutable baseline, the older accepted reference and published Stage 1; none are silently waived by passing correctness.
