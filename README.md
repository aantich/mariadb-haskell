# mariadb-haskell

A pure Haskell database driver focused **exclusively on MariaDB**.

This project is a fork of [mysql-haskell](https://github.com/winterland1989/mysql-haskell), originally created by Winterland and maintained by its upstream contributors. We are building on that work to make a reliable, well-tested and efficient MariaDB driver. **Supporting MySQL servers is outside the scope of this fork.**

## What we want to achieve

- **Make correctness dependable.** Preserve values accurately, handle large results and unusual data, and report errors clearly.
- **Work well with MariaDB.** Test supported MariaDB releases, authentication methods, data types, stored procedures and transaction behavior.
- **Stay reliable when things go wrong.** Handle timeouts, cancelled queries, broken connections and unfinished results without leaving a connection in an unsafe state.
- **Read and write efficiently.** Improve result decoding, reduce unnecessary allocations, and use MariaDB features such as binary bulk operations and prepared statement metadata caching.
- **Measure before optimizing.** Establish correctness and performance baselines for the current fork, then run the same checks against every improvement. Record failures and unsupported features as well as successes.
- **Keep the library practical.** Provide clear documentation, repeatable local setup and an API that higher-level Haskell libraries can build on.

These are current goals, not a claim that all of them are implemented. The first milestone is a comprehensive MariaDB test and benchmark suite, run against the existing driver before changing its implementation. Historical upstream benchmarks do not establish this fork's performance on MariaDB.

## Current status

The inherited driver supports streaming results, prepared statements, TLS and Unix sockets. A source review has identified compatibility and reliability gaps that the baseline suite will make visible.

The Cabal package is still named `mysql-haskell`, and public modules still use `Database.MySQL.*`. We are keeping those names while establishing the baseline. Some protocol identifiers containing `mysql` are also used by MariaDB itself; those names do not imply support for MySQL servers.

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

The integration suite requires a configured MariaDB instance. Reproducible setup, coverage and baseline commands will live alongside the new validation suite. Until that suite has run, there is no published MariaDB performance baseline for this fork.

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
