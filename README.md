# mariadb-haskell

A pure Haskell database driver focused **exclusively on MariaDB**.

This project is a fork of [mysql-haskell](https://github.com/winterland1989/mysql-haskell), originally created by Winterland and maintained by its upstream contributors. We are building on that work to make a reliable, well-tested and efficient MariaDB driver. **Supporting MySQL servers is outside the scope of this fork.**

## Live test and benchmark results

**[Read the current correctness and benchmark results](validation/RESULTS.md).** This live document is maintained on `main` and refreshed for each tested code change. It identifies the tested commit, shows outstanding failures and compares performance with the [original unchanged-driver baseline](validation/baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md). Earlier results remain in Git history; the original reference remains available.

Every full `python3 validation/check.py` run updates the live document and its [raw results](validation/results/current.json), including failed runs. The [validation guide](validation/README.md) describes the required test-and-publish workflow. CI flags results that no longer match the current source.

## What we want to achieve

- **Make correctness dependable.** Preserve values accurately, handle large results and unusual data, and report errors clearly.
- **Work well with MariaDB.** Test supported MariaDB releases, authentication methods, data types, stored procedures and transaction behavior.
- **Stay reliable when things go wrong.** Handle timeouts, cancelled queries, broken connections and unfinished results without leaving a connection in an unsafe state.
- **Read and write efficiently.** Improve result decoding, reduce unnecessary allocations, and use MariaDB features such as binary bulk operations and prepared statement metadata caching.
- **Measure before optimizing.** Establish correctness and performance baselines for the current fork, then run the same checks against every improvement. Record failures and unsupported features as well as successes.
- **Keep the library practical.** Provide clear documentation, repeatable local setup and an API that higher-level Haskell libraries can build on.

These are current goals, not a claim that all of them are implemented. The comprehensive MariaDB suite and unchanged-driver baseline are in place; the live results track progress from that starting point. Historical upstream benchmarks do not establish this fork's performance on MariaDB.

## Current status

The inherited driver supports streaming results, prepared statements, TLS and Unix sockets. The [live results](validation/RESULTS.md) record current correctness failures, unsupported functionality and measured performance. The [initial MariaDB baseline](validation/baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md) records the starting point before implementation changes.

Stage 1 implements connection ownership, cancellation, transaction cleanup, exact values and session-aware parameter rendering. Read the [migration notes](docs/STAGE1_MIGRATION.md) and [implementation/review evidence](docs/STAGE1_IMPLEMENTATION_NOTES.md) before adopting these API changes. The live results identify the committed inputs tested for publication; earlier review measurements retain their working-tree fingerprints.

The remaining performance investigations are deferred by project decision on 7 November 2026. Their measurements remain visible, and the original baseline is unchanged. This is permission to publish the reviewed correctness work, not a claim that every performance goal has passed.

Stage 2 adds the native MariaDB handshake, ed25519/PARSEC/SHA-2 authentication, bounded connection establishment, certificate helpers and installed CA data. The [Stage 2 implementation report](docs/STAGE2_IMPLEMENTATION.md) records the retained review measurements, committed publication results and Linux coverage. The live report identifies the actual tested inputs.

The [latest code review report](docs/STAGE1_CODE_REVIEW_2.md) records the subsequent correctness fixes, Haskell readability/comment improvements and remaining performance investigations.

The Cabal package is still named `mysql-haskell`, and public modules still use `Database.MySQL.*`. We are keeping those names while hardening the driver and stabilizing its API. Some protocol identifiers containing `mysql` are also used by MariaDB itself; those names do not imply support for MySQL servers.

## A first query

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Exception (bracket)
import Database.MySQL.Base
import qualified System.IO.Streams as Streams

main :: IO ()
main = bracket
    (connect defaultConnectInfoMB4
        { ciUser = "app"
        , ciPassword = "password"
        , ciDatabase = "app"
        })
    close
    (\conn -> do
        (_, rows) <- query_ conn "SELECT 1"
        print =<< Streams.toList rows)
```

Consume or explicitly discard the entire result stream before issuing another command on the same connection. Use a separate connection for each concurrent worker. Prefer prepared statements for parameterized queries.

## Building

With GHC and Cabal installed:

```sh
cabal update
cabal build all --enable-tests
cabal test test
```

Install, start and verify MariaDB before running integration tests or benchmarks. The [managed macOS setup](validation/MACOS.md) uses Homebrew and requires no server source build. The [validation guide](validation/README.md) covers the comprehensive suite, initial baseline capture and comparison commands; [coverage](validation/COVERAGE.md) lists the tested surfaces and explicit gaps.

## Upstream and attribution

The original project is [winterland1989/mysql-haskell](https://github.com/winterland1989/mysql-haskell). This fork retains its BSD 3-Clause license and the original copyright notices. See [LICENSE](LICENSE).

License
-------

Copyright (c) 2016, winterland1989

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of winterland1989 nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
