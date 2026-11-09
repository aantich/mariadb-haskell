#!/usr/bin/env python3
"""Manage a disposable external-authentication fixture and private client files.

The normal Mac workflow uses a container. Linux CI runs the same services inside
its already disposable container. Neither mode changes host PAM/realm settings.
"""
from contextlib import contextmanager
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
IMAGE = 'mariadb-haskell-stage7-auth'



def runtime_identity(image):
    """Hash runtime files/configuration, excluding changing provenance indexes."""
    config_keys = ('Env', 'Entrypoint', 'Cmd', 'WorkingDir', 'User', 'ExposedPorts',
                   'Volumes', 'Labels', 'StopSignal', 'Healthcheck', 'OnBuild',
                   'Shell', 'ArgsEscaped')
    fields = {key: image.get(key) for key in ('Architecture', 'Os', 'Variant', 'RootFS')}
    fields['Config'] = {key: image.get('Config', {}).get(key) for key in config_keys}
    # OCI omits the default working directory; Docker inspect spells it ''.
    fields['Config']['WorkingDir'] = fields['Config']['WorkingDir'] or ''
    return 'docker-runtime-sha256:'+hashlib.sha256(json.dumps(fields,
        sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def command(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def cleanup_container(owner):
    """Remove only a container bearing this invocation's unique ownership label.

    Docker can create a container before run reports a startup error. Probe the
    registered name even on that failure path; a name collision is not ownership.
    Diagnostic failures must never prevent the removal attempt.
    """
    inspected = subprocess.run(['docker', 'inspect', '--format',
        '{{ index .Config.Labels "mariadb-haskell.fixture-owner" }}', owner],
        capture_output=True, text=True, check=False, timeout=15)
    if inspected.returncode or inspected.stdout.strip() != owner:
        return
    try:
        subprocess.run(['docker', 'logs', owner], check=False, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        subprocess.run(['docker', 'rm', '-f', owner], check=True,
                       stdout=subprocess.DEVNULL, timeout=30)


@contextmanager
def environment(*, local=False):
    """Yield fixture-specific environment and clean up only owned resources.

    The caller must keep this scope alive throughout validation. Credentials,
    caches and CA files are private temporary files, never report artifacts.
    """
    (HERE/'.local').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='external-auth-', dir=HERE/'.local') as directory:
        private = Path(directory)
        owner = 'mariadb-haskell-auth-'+uuid.uuid4().hex[:12]
        process = None
        container = None
        fixture_root = Path('/fixture')
        try:
            if local:
                # This branch is for the disposable Linux CI image only.
                if not Path('/opt/driver-auth/disposable-fixture').is_file() or not Path('/opt/driver-auth/pam_fixture.so').is_file():
                    raise RuntimeError('local authentication fixtures require the disposable Linux CI image')
                fixture_root = private/'services'
                process = subprocess.Popen(['python3', str(HERE/'auth_fixture/serve.py')],
                    env={**os.environ, 'MB_AUTH_FIXTURE_ROOT': str(fixture_root),
                         'MB_AUTH_FIXTURE_PORT': '3307'})
                port, kdc_port = 3307, 10088
            else:
                command(['docker', 'build', '-t', IMAGE, '-f', HERE/'auth_fixture/Dockerfile', HERE/'auth_fixture'])
                # Register before the fallible creation call: the daemon may
                # have created the resource when its client fails or is killed.
                container = owner
                command(['docker', 'run', '-d', '--name', owner,
                    '--label', 'mariadb-haskell.fixture=external-authentication',
                    '--label', 'mariadb-haskell.fixture-owner='+owner,
                    '--tmpfs', '/fixture:rw,mode=0700,size=536870912',
                    '-p', '127.0.0.1::3306', '-p', '127.0.0.1::10088', IMAGE],
                    stdout=subprocess.DEVNULL)
                def published_port(number):
                    value = subprocess.check_output(['docker', 'port', owner, f'{number}/tcp'], text=True).strip()
                    if not value.startswith('127.0.0.1:'):
                        raise RuntimeError('authentication fixture must be bound to loopback')
                    return int(value.rsplit(':', 1)[1])
                port, kdc_port = published_port(3306), published_port(10088)
            for _ in range(160):
                if local:
                    ready = (fixture_root/'ready.json').is_file()
                    alive = process.poll() is None
                else:
                    ready = subprocess.run(['docker', 'exec', owner, 'test', '-f', '/fixture/ready.json'],
                                           capture_output=True).returncode == 0
                    alive = subprocess.check_output(['docker', 'inspect', '-f', '{{.State.Running}}', owner], text=True).strip() == 'true'
                if ready:
                    break
                if not alive:
                    raise RuntimeError('external authentication fixture stopped before readiness')
                time.sleep(0.25)
            else:
                raise RuntimeError('external authentication fixture readiness deadline exceeded')
            for filename in ['ready.json', 'tls-cert.pem', 'driver.ccache', 'other.ccache']:
                if local:
                    shutil.copyfile(fixture_root/filename, private/filename)
                else:
                    # Docker's archive endpoint can omit tmpfs mount contents.
                    # Read through the owned container process instead; ticket
                    # bytes go directly into private files, never tool output.
                    (private/filename).write_bytes(subprocess.check_output(
                        ['docker', 'exec', owner, 'cat', '/fixture/'+filename]))
                (private/filename).chmod(0o600)
            metadata = json.loads((private/'ready.json').read_text())
            realm = metadata['realm']
            (private/'krb5.conf').write_text(f'''[libdefaults]
 default_realm = {realm}
 dns_lookup_kdc = false
 dns_lookup_realm = false
 rdns = false
 udp_preference_limit = 1
[realms]
 {realm} = {{
  kdc = 127.0.0.1:{kdc_port}
 }}
''')
            if local:
                identity = 'local-disposable-linux-profile'
            else:
                image_id = subprocess.check_output(['docker', 'inspect', '-f', '{{.Image}}', container], text=True).strip()
                image = json.loads(subprocess.check_output(['docker', 'image', 'inspect', image_id], text=True))[0]
                identity = runtime_identity(image)
            yield {'MB_AUTH_FIXTURE_IMAGE_ID': identity,
                'MB_AUTH_HOST': '127.0.0.1', 'MB_AUTH_PORT': str(port),
                'MB_AUTH_TLS_CA': str(private/'tls-cert.pem'),
                'MB_AUTH_PAM_PASSWORD': metadata['password'], 'MB_AUTH_PAM_CODE': metadata['code'],
                'MB_AUTH_GSSAPI_PRINCIPAL': metadata['principal'],
                'MB_AUTH_GSSAPI_OTHER_CACHE': 'FILE:'+str(private/'other.ccache'),
                'KRB5CCNAME': 'FILE:'+str(private/'driver.ccache'),
                'KRB5_CONFIG': str(private/'krb5.conf')}
        finally:
            if container:
                # Exact generated name only. Never prune unrelated containers,
                # images, volumes, builder caches or the developer's databases.
                cleanup_container(container)
            if process:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    """Run a command with private fixture variables (use -- before arguments)."""
    import sys
    args = sys.argv[1:]
    if args and args[0] == '--':
        args = args[1:]
    if not args:
        raise SystemExit('usage: python3 validation/auth_fixture.py -- COMMAND [ARGUMENT ...]')
    with environment() as fixture:
        return subprocess.call(args, env={**os.environ, **fixture})


if __name__ == '__main__':
    raise SystemExit(main())
