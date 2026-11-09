#!/usr/bin/env python3
"""Build the actual Hackage source archive, independently of the checkout.

No upload or database mutation occurs. --build adds archive-only compilation,
installed-data lookup, existing unit/property tests, example compilation and
Hackage Haddock generation. Keep the output directory as reviewable evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ('mariadb-haskell.cabal', 'README.md', 'ChangeLog.md', 'LICENSE', 'LICENSE-MPL-2.0',
            'docs/USER_GUIDE.md', 'docs/BENCHMARKS.md', 'docs/MIGRATION.md',
            'docs/RELEASING.md', 'docs/CA_BUNDLE.md', 'ca-bundle.json',
            'examples/Quickstart.hs', 'examples/GuideExamples.hs',
            'cbits/gssapi.c', 'mozillaCAStore.pem', 'tools/update_ca_bundle.py')


def command(args, cwd, log, env=None):
    with log.open('w') as output:
        subprocess.run(list(map(str, args)), cwd=cwd, stdout=output,
                       stderr=subprocess.STDOUT, check=True, env=env)


def unpack(archive, destination, identity):
    """Accept only the expected single package tree of regular source files."""
    names = set()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            path = Path(member.name)
            if not path.parts or path.is_absolute() or '..' in path.parts or path.parts[0] != identity:
                raise ValueError('unexpected source archive path: ' + member.name)
            if not (member.isdir() or member.isfile()):
                raise ValueError('unexpected special file in source archive: ' + member.name)
            relative = path.relative_to(identity)
            if (relative.name.startswith('cabal.project') or '.local' in relative.parts
                    or '.git' in relative.parts or 'dist-newstyle' in relative.parts):
                raise ValueError('developer/private file leaked into source archive: ' + str(relative))
            names.add(str(relative))
            target = destination / path
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as data, target.open('wb') as output:
                    shutil.copyfileobj(data, output)
    missing = set(REQUIRED) - names
    if missing:
        raise ValueError('required source-package files absent: ' + ', '.join(sorted(missing)))
    return destination / identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='new evidence directory')
    parser.add_argument('--build', action='store_true', help='compile/test/document the unpacked archive')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = (ROOT / 'mariadb-haskell.cabal').read_text()
    version = re.search(r'^version:\s*(\S+)', manifest, re.M).group(1)
    identity = 'mariadb-haskell-' + version
    artifacts = output / 'artifacts'
    artifacts.mkdir()
    status = {'package': identity, 'complete': False, 'checks': []}

    def run(label, argv, cwd=ROOT, env=None):
        command(argv, cwd, output / (label + '.log'), env=env)
        status['checks'].append(label)
        print('PASS ' + label, flush=True)

    try:
        run('cabal-check', ['cabal', 'check'])
        run('ca-bundle', ['python3', 'tools/update_ca_bundle.py', '--check'])
        run('sdist', ['cabal', 'sdist', '--output-directory=' + str(artifacts)])
        archive = artifacts / (identity + '.tar.gz')
        package = unpack(archive, output / 'source', identity)
        run('archive-ca', ['python3', 'tools/update_ca_bundle.py', '--check'], package)
        if args.build:
            target = 'lib:mariadb-haskell'
            run('archive-build', ['cabal', 'build', target, 'test:test', '--enable-tests', '-O2'], package)
            plan = json.loads((package / 'dist-newstyle/cache/plan.json').read_text())
            local = [entry for entry in plan['install-plan'] if entry['pkg-name'] == 'mariadb-haskell']
            if not local or any(entry.get('flags', {}).get('validation') is not False for entry in local):
                raise ValueError('source archive unexpectedly enables the developer validation component')
            setups = list((package / 'dist-newstyle/build').glob('*/ghc-*/mariadb-haskell-*/opt/setup-config'))
            if len(setups) != 1:
                raise ValueError('expected exactly one archive library installation configuration')
            run('archive-install-data', ['cabal', 'v1-copy', target, '--builddir=' + str(setups[0].parent)], package)
            # Compile inside Cabal, then run outside both Cabal and the package
            # directory. A local data override must not mask a broken install.
            probe = output / 'InstalledCA.hs'
            probe.write_text('module Main where\nimport Data.TLSSetting\n'
                             'main :: IO ()\nmain = makeClientParams MozillaCAStore >> putStrLn "Installed CA store loaded"\n')
            run('installed-ca-build', ['cabal', 'exec', '--', 'ghc', '-threaded', '-package',
                                      'mariadb-haskell', probe, '-outputdir', output / 'ca-objects',
                                      '-o', output / 'installed-ca'], package)
            clean = {key: value for key, value in os.environ.items() if key != 'mariadb_haskell_datadir'}
            run('installed-ca', [output / 'installed-ca'], output, env=clean)
            run('archive-unit', ['cabal', 'test', 'test', '--enable-tests', '-O2',
                                '--test-options=--quickcheck-replay=730208 --quickcheck-tests=100'], package)
            run('guide-examples', ['cabal', 'exec', '--', 'ghc', '-fno-code', '-Wall',
                                  '-package', 'mariadb-haskell', 'examples/GuideExamples.hs'], package)
            run('quickstart', ['cabal', 'exec', '--', 'ghc', '-threaded', '-Wall',
                              '-package', 'mariadb-haskell', 'examples/Quickstart.hs',
                              '-outputdir', output / 'objects', '-o', output / 'quickstart'], package)
            run('haddock', ['cabal', 'haddock', target, '--haddock-for-hackage', '-O2'], package)
            shutil.copy2(package / 'dist-newstyle' / (identity + '-docs.tar.gz'), artifacts)
        status['artifacts'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted(artifacts.glob('*.tar.gz'))}
        (artifacts / 'SHA256SUMS').write_text(''.join(digest + '  ' + name + '\n'
                                                   for name, digest in status['artifacts'].items()))
        status['complete'] = True
    finally:
        (output / 'checks.json').write_text(json.dumps(status, indent=2) + '\n')


if __name__ == '__main__':
    main()
