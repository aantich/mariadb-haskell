# Releasing mariadb-haskell

Release preparation, 9 November 2026. Package **mariadb-haskell 0.1.0.0**;
maintainer **Anton Antich <anton.antich@gmail.com>**. Public imports remain
`Database.MySQL.*`. No public Hackage release has been uploaded.

## Implemented release work

* Independent Cabal manifest, self-dependencies, generated `Paths` module,
  examples, Linux tooling and Nix attributes now use `mariadb-haskell`.
* The minimum supported compiler is GHC 9.4 (`base >=4.17`); the current upper
  bound admits GHC 9.12. `tested-with` lists the actually recorded 9.4.7/9.10.3
  profiles, not every compiler listed in the broader CI matrix.
* Linux CI installs MIT Kerberos headers/libraries alongside zlib/C tooling.
  Nix explicitly resolves `gssapi_krb5` to `libkrb5`. Native macOS uses GSS.framework.
  Generic CI covers Linux/macOS; Windows is outside the verified release scope.
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

The public package lookup returned HTTP 404 during preparation; this is not a
name reservation. Local Cabal currently has no Hackage authentication configured.
Upload requires Anton's authenticated account/API token, configured locally.
Do not put passwords/tokens in source, logs or this chat.

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

## Supported scope

The original capability inventory is green. Advanced XA checkpointing,
two-phase ALTER/storage-engine-binlog GTID semisync, broader text codecs and
untested server/OS profiles remain explicitly excluded. A scoped first release
can retain these limits. Exposed low-level connection/protocol helpers remain
experimental implementation APIs, with some documentation/link debt; the main
application API has complete Haddock item coverage. Retaining module names
is compatibility, not a MySQL server support promise.

## Evidence checkpoint

Implementation and focused checks are in progress. Final source-archive,
Mac/Linux correctness, full benchmark and freshness outcomes are recorded here
when complete. Candidate upload/remote inspection remains pending authentication.
