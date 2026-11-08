#!/usr/bin/env python3
"""Run one CDC check on a disposable, socket-only semisynchronous MariaDB.

The managed server and its settings are untouched. The child has a deadline,
cleanup always waits for the owned server, and no network listener is exposed.
Only the temporary datadir is removed; existing server data is never opened.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def main(arguments):
    if not arguments:
        raise ValueError('expected validation executable and arguments')
    required = ('mariadbd', 'mariadb-install-db', 'mariadb')
    programs = {name: shutil.which(name) for name in required}
    if not all(programs.values()):
        raise RuntimeError('installed MariaDB server binaries are required for the CDC fixture')
    with tempfile.TemporaryDirectory(prefix='mb-cdc-', dir='/tmp') as name:
        directory = Path(name)
        datadir = directory/'data'
        sock = directory/'server.sock'
        with (directory/'server.log').open('w+') as log:
            subprocess.run([programs['mariadb-install-db'], '--no-defaults', '--datadir='+str(datadir),
                            '--auth-root-authentication-method=normal', '--skip-test-db'],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=45)
            command = [programs['mariadbd'], '--no-defaults', '--datadir='+str(datadir),
                       '--socket='+str(sock), '--pid-file='+str(directory/'server.pid'),
                       '--skip-networking', '--server-id=610129', '--log-bin='+str(directory/'bin'),
                       '--binlog-format=ROW', '--binlog-row-image=FULL', '--binlog-checksum=CRC32',
                       '--plugin-load-add=semisync_master', '--rpl-semi-sync-master-timeout=5000',
                       '--default-time-zone=+00:00']
            if os.geteuid() == 0:
                command.append('--user=root')
            server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            child = None
            try:
                def sql(statement):
                    return subprocess.run([programs['mariadb'], '--no-defaults', '--protocol=socket',
                        '--socket='+str(sock), '--user=root', '--batch', '--skip-column-names'],
                        input=statement, text=True, capture_output=True, timeout=8)
                deadline = time.monotonic()+30
                while time.monotonic() < deadline:
                    ready = sql('SELECT VERSION()')
                    if ready.returncode == 0:
                        break
                    if server.poll() is not None:
                        raise RuntimeError('disposable CDC server stopped before readiness')
                    time.sleep(0.1)
                else:
                    raise RuntimeError('disposable CDC server readiness deadline')
                setup = sql('CREATE DATABASE cdc_validation; '
                            'CREATE TABLE cdc_validation.changes(id INT PRIMARY KEY); '
                            'SET GLOBAL rpl_semi_sync_master_enabled=1;')
                if setup.returncode:
                    raise RuntimeError('semisync fixture setup failed: '+setup.stderr)
                print('Disposable CDC MariaDB:', ready.stdout.strip(), flush=True)
                child = subprocess.Popen(arguments, env={**os.environ, 'MB_CDC_SOCKET': str(sock),
                                                        'MB_CDC_CONTROL': str(directory)})
                child_deadline = time.monotonic()+40
                while child.poll() is None:
                    if time.monotonic() >= child_deadline:
                        raise RuntimeError('CDC fixture child deadline exceeded')
                    request = directory/'restart.request'
                    if request.exists():
                        request.unlink()
                        server.terminate()
                        server.wait(timeout=10)
                        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                        ready_deadline = time.monotonic()+10
                        while time.monotonic() < ready_deadline:
                            if sql('SELECT 1').returncode == 0:
                                break
                            if server.poll() is not None:
                                raise RuntimeError('CDC fixture failed to restart')
                            time.sleep(0.05)
                        else:
                            raise RuntimeError('CDC restart readiness deadline')
                        (directory/'restart.done').touch()
                    time.sleep(0.02)
                return child.returncode
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read()[-4000:], file=sys.stderr)
                raise
            finally:
                if child is not None and child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=10)


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
