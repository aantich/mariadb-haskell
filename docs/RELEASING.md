# Releasing mariadb-haskell

Released 9 November 2026. Package **mariadb-haskell 0.1.0.0**;
maintainer **Anton Antich <anton.antich@gmail.com>**. Public imports remain
`Database.MySQL.*`.

**Published:** [Hackage package](https://hackage.haskell.org/package/mariadb-haskell-0.1.0.0)
· [API documentation](https://hackage.haskell.org/package/mariadb-haskell-0.1.0.0/docs/Database-MySQL-Base.html).
Anton reviewed the candidate and explicitly approved publication on 9 November
2026. The public source download matches the reviewed archive's SHA-256, and
the public API and source pages resolve. The receipt below records the exact
artifacts, approval and verification.

**Readiness: Alpha.** Automated tests and benchmarks do not replace real-world
application validation, which is still outstanding. The Cabal stability field,
description, README, user guide and main API documentation identify this status.

**Publication policy:** upload a candidate and its documentation for Anton to review
as rendered on Hackage. Do not publish to the main Hackage index until Anton has
reviewed that preview and explicitly approved publication. Candidate upload and
documentation inspection do not grant permission to publish the release.

## Implemented release work

* Independent Cabal manifest, self-dependencies, generated `Paths` module,
  examples, Linux tooling and Nix attributes now use `mariadb-haskell`.
* The minimum supported compiler is GHC 9.4 (`base >=4.17`); the current upper
  bound admits GHC 9.12. `tested-with` lists the actually recorded 9.4.7/9.10.3
  profiles, not every compiler listed in the broader CI matrix.
* Linux CI installs MIT Kerberos headers/libraries alongside zlib/C tooling.
  Nix explicitly resolves `gssapi_krb5` to `libkrb5`. Native macOS uses GSS.framework.
  Generic CI covers Linux/macOS; Windows is outside the verified release scope.
  The GHC 9.4 Linux job uses Ubuntu 24.04: its bindist selects Gold, which
  was missing from the Ubuntu 26.04 runner in the first CI attempt.
* The validation executable is a **manual, default-off** package flag. Only
  the developer checkout's `cabal.project` opts in and selects optimization 2.
  Source archives omit that project. A normal Hackage library installation
  does not install a benchmark/validation command.
* The old June 2017 CA file is replaced by the verified 5 November 2026 Mozilla
  extract: 118 certificates, exact source/checksum/provenance and MPL-2.0 notice.
  See [CA bundle maintenance](https://github.com/aantich/mariadb-haskell/blob/main/docs/CA_BUNDLE.md).
* `Show ConnectInfo` now redacts passwords without evaluating them. New unit
  regressions cover empty/text/binary secrets, preserved credentials, context
  and Show precedence.
* README, user/migration/benchmark guides and examples ship in the source
  archive. Public application API comments explain ownership, lifetimes,
  limits, cancellation, reset, authentication and CDC durability.
* `cabal check` is clean. Optimization is selected by the developer project or
  explicit benchmark command rather than forced through published component flags.

## Preserve benchmark history through the rename

`validation/run.py` remains byte-for-byte frozen, SHA-256
`e756bc0f593b54bc9207fd88d2a53120a4654832650d0a148555a69ebd413346`.
The command entry point is now `validation/release_recorder.py`. It first verifies
that digest, substitutes only the manifest filename and self-package dependency
exclusion, and handles entry-point dispatch itself. Workload bodies, warmups,
repetitions, ordering, comparisons and frozen references remain unchanged.

Every new recorder snapshot separately records the original hash, adapter hash,
derived body hash and exact substitutions. The publication guard verifies this
against current fingerprinted inputs. Tests reject any change to the pinned
recorder, including sampling or regression thresholds. Matching original workload
hashes do not assert that the metadata adapter existed in the old capture.
All immutable original/feature baselines and previous measurements remain intact.

## Source package and documentation verification

Run from a checkout, using a new output directory each time:

```sh
python3 -m unittest discover -s validation -p 'test_*.py'
python3 tools/update_ca_bundle.py --check
python3 tools/check_release.py --build --output /tmp/mariadb-release-check
```

The checker creates the actual source archive, rejects private/development
files, verifies required source/data/license/doc files, and unpacks a fresh
package without Git or the development project. It builds the library/tests,
copies runtime data to Cabal's configured prefix, runs the existing unit/property
suite, compiles both examples and builds Hackage-format Haddock. It retains
per-command logs, `checks.json`, source/docs archives and `SHA256SUMS`.
Its build uses only the archive; historical full validation still needs the
Git/evidence checkout and a provisioned MariaDB server.

CI repeats source-archive checks on Linux and macOS, with broader compiler and
crypton-series builds separately. Configuring a job is not proof that a remote
job ran; the release evidence below distinguishes local results from pending CI.

## Final validation and measurements

Install/start/provision MariaDB first, following
[validation](https://github.com/aantich/mariadb-haskell/blob/main/validation/README.md).
Commit the final executable inputs locally on main, then run:

```sh
python3 validation/check.py
python3 validation/publish_results.py --check
```

Retain raw complete evidence and update the live report, JSON and colored
summary together. Never relabel old review captures as new committed-source
measurements or clear their dirty-input history. Deferred timing investigations
remain visible; support/performance claims stay limited to measured environments.
Results-only and ordinary documentation updates do not require an endless rerun.

## Candidate inspection and publication

Preview: [Hackage candidate](https://hackage.haskell.org/package/mariadb-haskell-0.1.0.0/candidate)
· [Rendered application API](https://hackage.haskell.org/package/mariadb-haskell-0.1.0.0/candidate/docs/Database-MySQL-Base.html).
These are the retained previews. Anton completed the documentation review and
approved publication on 9 November 2026; the public release is linked above.


The public package lookup returned HTTP 404 during preparation and HTTP 200
after publication. Anton's locally configured token was verified by a read-only Hackage request
as account **aantich**, and uploader-group membership is confirmed. The
configuration is owner-only and its Hackage repository uses HTTPS.
Do not put passwords/tokens in source, logs or this chat.

For local access, sign in to Hackage's
[account-management page](https://hackage.haskell.org/users/account-management)
and create an authentication token. `cabal path --config-file` identifies the
active configuration (this Mac uses `/Users/aantich/.cabal/config`). Add an
unindented `token: YOUR_TOKEN` there using a local editor and restrict the
file to its owner (`chmod 600`). Cabal 3.16.1 supports this global token field.
Never pass the actual token through a committed script or chat. New accounts
require uploader approval; Hackage's
[registration page](https://hackage.haskell.org/users/register-request) explains
endorsements and trustee requests. Candidate access is not guaranteed merely by
setting the public maintainer email.

After technical checks pass, upload a **candidate** using the exact checksummed
artifacts (without `--publish`):

```sh
cabal upload /path/to/mariadb-haskell-0.1.0.0.tar.gz
cabal upload --documentation /path/to/mariadb-haskell-0.1.0.0-docs.tar.gz
```

Inspect the candidate README, changelog, maintainer, license notices, user guide,
examples and rendered Haddock; verify source/API links and the native dependency
explanation. Candidate inspection requires upload access and is separate from
local artifact verification. Public publication is the final deliberate action;
[Hackage's upload policy](https://hackage.haskell.org/upload) explains why candidate
review matters. See the [Cabal command reference](https://cabal.readthedocs.io/en/stable/cabal-commands.html)
for authentication/upload options.

After approval, publish the same checked archives and verify the public download
and rendered documentation:

```sh
cabal upload --publish /path/to/mariadb-haskell-0.1.0.0.tar.gz
cabal upload --documentation --publish /path/to/mariadb-haskell-0.1.0.0-docs.tar.gz
```

For this release, the source-upload response ended with an HTTP/2 transport
error, but Hackage had accepted the package. The public download's checksum
confirmed successful publication, so the immutable source upload was not retried.
The documentation upload succeeded using HTTP/1.1. Hackage adds a small display
style to served Haddock HTML; removing that injected style reproduces the
reviewed API page exactly.

## Supported scope

The original capability inventory is green. Advanced XA checkpointing,
two-phase ALTER/storage-engine-binlog GTID semisync, broader text codecs and
untested server/OS profiles remain explicitly excluded. A scoped first release
can retain these limits. Exposed low-level connection/protocol helpers remain
experimental implementation APIs, with some documentation/link debt; the main
application API has complete Haddock item coverage. Retaining module names
is compatibility, not a MySQL server support promise.

## Evidence checkpoint

Committed release inputs: `6bbcf13fa3b66d96f26c8c4b36f5d69d5f69c25f`,
209 input files, SHA-256
`23135d7aba3c73c1b39691f9b6ae3ea21104c45838d753a47ce9fa6a73892153`.

* Mac correctness: **844 PASS / 0 FAIL / 0 unsupported / 0 unavailable**.
  Inherited suites: **183 unit/property cases** (182 pass, one inherited
  external-HTTPS ignore) and **32 passing integration tests**.
* **180 policy tests pass**. The archive rejection test was tightened to match
  its intended error reason; the interrupted earlier capture remains retained.
* Full Mac measurements: **63 runnable profiles × seven repetitions**,
  including all five additive families. Frozen workloads/references and the
  149-entry dependency plan remain unchanged. The strict publication guard passes.
* The full command exits 1 because performance acceptance remains open:
  51 ordinary/reference, 0 native, 4 reuse, 0 CDC, 6 wire and
  1 authentication timing signals; no
  allocation signals. Hearthstone/Zoom were active, and Anton explicitly requested
  continuation with timing contention labeled. Linux compilation was paused
  during the Mac capture. The pre-Alpha run is retained; this final run follows the newly committed
  Alpha metadata, rendered-documentation and CI corrections; every earlier
  capture remains retained rather than selecting better timings.
* Both Nix CI derivations instantiate on isolated Linux; dummy credential/build
  directories are absent from the filtered source. This is **evaluation**, not
  a completed Nix VM test locally. The subsequent
  [GitHub Nix job](https://github.com/aantich/mariadb-haskell/actions/runs/42645834954/job/129258710100)
  passed the package build and all 32 MariaDB VM integration cases. The broader
  compiler/OS jobs are tracked separately in the receipt.
* The independent archive check passes all 12 steps, including installed-CA
  lookup outside Cabal, 183 unit/property cases, both examples and Hackage-format Haddock.
  Exact artifact checksums and archive/inspection outcomes are retained in the
  [release receipt](../validation/results/release-0.1.0.0.json).
* Main application API Haddock item coverage is complete; all 117 authored local
  API links across the six main pages resolve. Generated instance links and
  experimental low-level helpers retain some documentation/link debt.

The Linux profile at `250ad82` passes all 844 correctness records, 180 policy
tests and 39 native benchmark smoke paths. Its raw revision is retained; the
subsequent Alpha change is readiness metadata and API documentation. Linux
smoke timings are never compared with Mac baselines.

The committed Alpha captures pass correctness/evidence gates. The preview
inspection found legacy dot separators in Cabal's description and two slash-heavy
Haddock phrases; these documentation-only corrections are committed separately.
The final source/docs archive identities and remote CI state are recorded in the
release receipt. Automated coverage has not established real-world application
readiness. **Anton approved publication, and 0.1.0.0 is published as Alpha.**
At publication, Linux compiler builds (GHC 9.4/9.6/9.8/9.10/9.12), both crypton
series, source-archive verification and Nix passed. Additional macOS CI jobs
were queued or running; native Mac validation above is complete. The receipt
retains both the earlier CI snapshot and the publication-time snapshot.
