# Managed MariaDB on macOS

Use **MariaDB 12.3 LTS** through Homebrew. It supplies a precompiled Apple Silicon package, the command-line tools and MariaDB Connector/C. Homebrew manages startup through launchd. [Homebrew package](https://formulae.brew.sh/formula/mariadb@12.3), [MariaDB installation guide](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/installing-mariadb/binary-packages/installing-mariadb-on-macos-using-homebrew)

## Install and verify the server

```sh
brew update
brew install mariadb@12.3
brew services start mariadb@12.3
export PATH="$(brew --prefix mariadb@12.3)/bin:$PATH"
mariadb --protocol=socket -e 'SELECT VERSION(), USER()'
```

The first startup can take several seconds. `brew services info mariadb@12.3` reports its status. If macOS asks to allow the new background item, allow the MariaDB service under System Settings, General, Login Items and Extensions.

The Homebrew installation creates a socket administrator matching your macOS username, so the verification command normally needs no root password or `sudo`. Use an application/test account for TCP connections. The versioned formula is keg-only; the `PATH` command above makes its tools available in the current shell. The scripts also recognize the standard Apple Silicon path directly.

On the initial development Mac, installation and both socket/TCP verification succeeded with MariaDB **12.3.3**, Homebrew bottle revision 1. The source revision and actual server settings are recorded again by each baseline run.

## Configure the validation environment

From this repository:

```sh
python3 validation/configure_macos.py
python3 validation/provision.py
```

The configuration helper requires the package to be installed first. It creates a private development CA and TLS certificates, enables row binlogs, allows 384 MiB packets for the inherited large-packet tests, pins default sessions to UTC and binds the server to **127.0.0.1**. It restarts the managed service and waits for readiness. It preserves the database directory and refuses to overwrite an unrelated `my.cnf`; in that situation merge the settings explicitly instead.

Provisioning creates only the reserved `mariadb_haskell_validation` and `testMySQLHaskell` databases and dedicated validation accounts. It can reset the passwords of those fixture accounts on repeated runs. The inherited suite requires its original localhost-only passwordless fixture account and database names; the new suite uses a separately generated password. Do not use these accounts for application data.

The native-password, ed25519, parsec and optional SHA-2 fixtures belong to MariaDB. MariaDB authentication mechanisms can retain historical `mysql` identifiers. PAM/GSSAPI need additional operating-system/realm setup and are recorded separately when that environment is unavailable.

On Apple Silicon the managed files are:

| Purpose | Location |
| --- | --- |
| Server and tools | `/opt/homebrew/opt/mariadb@12.3/bin` |
| Server configuration | `/opt/homebrew/etc/my.cnf` |
| Data directory | `/opt/homebrew/var/mysql` |
| Socket | `/tmp/mysql.sock` |
| Private development TLS files | `/opt/homebrew/var/mariadb-haskell/tls` |
| Test connection settings | `validation/.local/environment.json` in this repository |

## Start and stop it

```sh
brew services info mariadb@12.3
brew services stop mariadb@12.3
brew services start mariadb@12.3
brew services restart mariadb@12.3
```

Starting through `brew services` also registers startup at login. Stop the service when it is not needed. A system-wide binary installation does not require running the server as root.

## Keep test results comparable

```sh
brew update
brew outdated mariadb@12.3
```

Upgrade deliberately with `brew upgrade mariadb@12.3`, then restart the service and follow the package's database-upgrade instructions if required. Keep a backup before upgrading an instance containing valuable data. Capture a new version-specific baseline after an upgrade; never overwrite the old results or compare changed server versions as if only the driver changed.
