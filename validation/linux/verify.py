#!/usr/bin/env python3
"""Run real MariaDB correctness on Linux with isolated disposable fixtures.

The Docker image owns its database and CA; it never changes the host server or
trust store. Results are a separate profile, with no cross-platform timing claim.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('MB_LINUX_OUTPUT', ROOT / 'validation/results/runs/stage2-linux'))
LOCAL = ROOT / 'validation/.local'
TLS = Path('/tmp/mariadb-haskell-stage2-tls')


def command(args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)


def certificates():
    TLS.mkdir(mode=0o755, exist_ok=True)
    command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
             '-keyout', TLS/'ca-key.pem', '-out', TLS/'ca.pem', '-days', '3650',
             '-subj', '/CN=MariaDB Haskell Linux Test CA'], capture_output=True)
    (TLS/'index').touch()
    (TLS/'serial').write_text('01\n')
    (TLS/'ca.cnf').write_text(f'''[ca]
default_ca=local
[local]
database={TLS}/index
serial={TLS}/serial
new_certs_dir={TLS}
certificate={TLS}/ca.pem
private_key={TLS}/ca-key.pem
default_md=sha256
default_days=365
policy=policy
unique_subject=no
x509_extensions=v3
[policy]
commonName=supplied
[v3]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:localhost,DNS:Winter,IP:127.0.0.1
''')
    for stem in ['server', 'client', 'expired-client']:
        command(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
                 '-keyout', TLS/f'{stem}-key.pem', '-out', TLS/f'{stem}.csr',
                 '-subj', '/CN=localhost'], capture_output=True)
        validity = ['-startdate', '20200101000000Z', '-enddate', '20210101000000Z'] if stem == 'expired-client' else []
        command(['openssl', 'ca', '-batch', '-config', TLS/'ca.cnf', '-in', TLS/f'{stem}.csr',
                 '-out', TLS/f'{stem}-cert.pem', *validity], capture_output=True)
    # Supply auth RSA keys explicitly. Full SHA-2 TCP authentication must not
    # depend on server-side password caches or automatic key-file creation.
    command(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
             '-out', TLS/'auth-rsa-key.pem'], capture_output=True)
    command(['openssl', 'pkey', '-in', TLS/'auth-rsa-key.pem', '-pubout',
             '-out', TLS/'auth-rsa-public.pem'], capture_output=True)
    for path in TLS.glob('*-key.pem'):
        path.chmod(0o600)
    shutil.chown(TLS/'server-key.pem', user='mysql', group='mysql')
    shutil.chown(TLS/'auth-rsa-key.pem', user='mysql', group='mysql')


def main():
    LOCAL.mkdir(parents=True, exist_ok=True)
    command(['git', 'config', '--global', '--add', 'safe.directory', str(ROOT)])
    OUT.mkdir(parents=True, exist_ok=False)
    certificates()
    server_log = (OUT/'server.log').open('w')
    process = subprocess.Popen([
        '/usr/local/bin/docker-entrypoint.sh', 'mariadbd', '--user=mysql',
        '--bind-address=127.0.0.1', '--port=3306', '--skip-name-resolve=0', '--max-allowed-packet=384M',
        '--plugin-load-add=auth_mysql_sha2',
        f'--loose-caching-sha2-password-private-key-path={TLS}/auth-rsa-key.pem',
        f'--loose-caching-sha2-password-public-key-path={TLS}/auth-rsa-public.pem',
        '--server-id=610124', '--log-bin=mariadb-bin', '--binlog-format=ROW',
        '--binlog-row-image=FULL', '--binlog-checksum=CRC32',
        '--character-set-server=utf8mb4', '--collation-server=utf8mb4_unicode_ci',
        '--default-time-zone=+00:00', f'--ssl-ca={TLS}/ca.pem',
        f'--ssl-cert={TLS}/server-cert.pem', f'--ssl-key={TLS}/server-key.pem',
    ], env={**os.environ, 'MARIADB_ALLOW_EMPTY_ROOT_PASSWORD': '1'}, stdout=server_log, stderr=subprocess.STDOUT)
    try:
        for _ in range(90):
            # The image's bootstrap server accepts socket queries before it
            # stops/restarts. TCP readiness excludes that temporary server.
            probe = subprocess.run(['mariadb', '--protocol=tcp', '--host=127.0.0.1',
                                    '--connect-timeout=1', '--skip-ssl', '-uroot', '--batch', '--skip-column-names',
                                    '-e', 'SELECT VERSION()'], capture_output=True, text=True)
            if probe.returncode == 0 and 'MariaDB' in probe.stdout:
                print('Server verified before build:', probe.stdout.strip(), flush=True)
                break
            if process.poll() is not None:
                raise RuntimeError('Linux MariaDB stopped; inspect server.log')
            time.sleep(1)
        else:
            raise RuntimeError('Linux MariaDB startup deadline exceeded')
        config = LOCAL/'linux-environment.json'
        command([sys.executable, 'validation/provision.py', '--client', 'mariadb',
                 '--socket', '/run/mysqld/mysqld.sock', '--tls-ca', TLS/'ca.pem', '--output', config])
        command([sys.executable, '-m', 'unittest', 'discover', '-s', 'validation', '-p', 'test_*.py'])
        command(['cabal', 'build', 'exe:mariadb-validation', 'test:test', 'test:integration', '--enable-tests', '-O2'])
        setups = list((ROOT/'dist-newstyle/build').glob('*/ghc-*/mysql-haskell-*/opt/setup-config'))
        if len(setups) != 1:
            raise RuntimeError('expected one built library installation directory')
        command(['cabal', 'v1-copy', 'lib:mysql-haskell', '--builddir='+str(setups[0].parent)])
        run_dir = OUT/'suite'
        command([sys.executable, 'validation/run.py', '--config', config, '--output', run_dir,
                 '--no-benchmarks', '--compare', 'validation/baselines/macos-arm64-mariadb-12.3.3/results.json',
                 '--correctness-only-comparison'])
        data = json.loads((run_dir/'results.json').read_text())
        manifest = json.loads((ROOT/'validation/results/previous-stage.json').read_text())
        previous = json.loads((ROOT/'validation/results'/manifest['reference']).read_text())
        current = {case['id']:case['status'] for case in data['correctness']}
        lost = [case['id'] for case in previous['correctness']
                if case['status']=='PASS' and current.get(case['id'])!='PASS']
        added_failures = [case['id'] for case in data['correctness']
                          if case['id'].startswith(('stage2.', 'stage3.', 'stage4.', 'stage5.', 'stage6.')) and case['status']!='PASS']
        sys.path.insert(0, str(ROOT/'validation'))
        import stage1_gates
        native_failures = [ident for ident in stage1_gates.NATIVE_TARGETS + stage1_gates.STATEMENT_TARGETS + stage1_gates.SESSION_TARGETS + stage1_gates.CDC_TARGETS if current.get(ident) != 'PASS']
        if lost or added_failures or native_failures:
            raise RuntimeError('Linux correctness regressions: '+repr(lost+added_failures+native_failures))
        # Smoke all native benchmark paths on this compiler/server too. These
        # one-iteration checks are not compared with macOS timing baselines.
        binary = subprocess.check_output(['cabal', 'list-bin', 'exe:mariadb-validation', '-O2'], cwd=ROOT, text=True).strip()
        native_env = {**os.environ, **json.loads(config.read_text()), 'TZ': 'UTC'}
        for profile in ['bulk.native', 'bulk.units', 'bulk.prepared', 'bulk.text-batch',
                        'prepared.narrow.cached', 'prepared.narrow.uncached',
                        'prepared.wide.cached', 'prepared.wide.uncached']:
            command([binary, 'stage3-bench', profile, '1', '+RTS', '-N4', '-T', '-RTS'], env=native_env)
        for transport in ['tcp', 'tls', 'socket']:
            for mode in ['reset', 'reconnect']:
                command([binary, 'stage4-bench', f'reuse.{transport}.{mode}', '1',
                         '+RTS', '-N4', '-T', '-RTS'], env=native_env)
        command([binary, 'stage4-bench', 'session.snapshot', '1', '+RTS', '-N4', '-T', '-RTS'], env=native_env)
        for profile in ['cdc.decode.single-table', 'cdc.decode.interleaved', 'cdc.decode.compressed',
                        'cdc.decode.sparse-update', 'cdc.framing.crc32', 'cdc.live.rows', 'cdc.live.checkpoints', 'cdc.retention']:
            command([binary, 'stage5-bench', profile, '1000', '+RTS', '-N4', '-T', '-RTS'], env=native_env)
        import stage6_benchmarks
        for profile in stage6_benchmarks.PROFILES:
            command([binary, 'stage6-bench', profile, '1', '+RTS', '-N4', '-T', '-RTS'], env=native_env)
        print('Linux correctness profile passed; frozen timings were not compared.', flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        server_log.close()


if __name__ == '__main__':
    main()
