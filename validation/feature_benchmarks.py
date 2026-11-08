#!/usr/bin/env python3
"""Shared recorder and independent evidence checks for additive feature suites.

Workload-specific units/checksums live in immutable specifications. Both native
and session-reuse recorders use these same completeness and baseline guards.
"""
from dataclasses import dataclass
import argparse
import json
import hashlib
import os
import platform
from pathlib import Path
import random
import statistics

import publish_results as live
import run

@dataclass(frozen=True)
class FeatureSpec:
    """Wire record identity, workloads and independent expected work."""
    marker: str
    command: str
    label: str
    profiles: dict
    units: dict
    checksums: dict
    pairs: dict
    baseline_directory: Path
    workload_paths: tuple


def sample(spec, output, ident):
    """Require one complete record, positive work and the independent checksum."""
    lines = [line for line in output.splitlines() if line.startswith(spec.marker + '\t')]
    if len(lines) != 1:
        raise ValueError(f'expected exactly one {spec.label} benchmark record')
    marker, name, *values = lines[0].split('\t')
    if marker != spec.marker or name != ident or len(values) != 6:
        raise ValueError(f'{spec.label} benchmark record shape/identity mismatch')
    result = dict(zip(('units', 'elapsed_ns', 'allocated_bytes', 'cpu_ns', 'gc_cpu_ns', 'checksum'), map(int, values)))
    if (result['units'] <= 0 or result['elapsed_ns'] <= 0 or result['allocated_bytes'] <= 0
            or any(value < 0 for value in result.values())):
        raise ValueError(f'invalid {spec.label} benchmark counters')
    expected = spec.checksums[ident]
    if result['checksum'] != expected:
        raise ValueError(f'{spec.label} benchmark checksum mismatch')
    expected_units = spec.units[ident]
    if result['units'] != expected_units:
        raise ValueError(f'{spec.label} benchmark unit count mismatch')
    return result


def verify_measurements(spec, data, inputs):
    """Validate samples/units independently of any baseline comparison."""
    if (not data.get('complete') or data.get('repetitions', 0) < 7
            or data.get('inputs', {}).get('sha256') != inputs['sha256']):
        raise ValueError(f'{spec.label} benchmark evidence is incomplete or stale')
    if data['inputs'].get('files') != inputs.get('files'):
        raise ValueError(f'{spec.label} input file evidence disagrees with current inputs')
    if inputs.get('commit') is not None and (data['inputs'].get('commit') != inputs['commit']
            or data.get('build', {}).get('git_commit') != inputs['commit']):
        raise ValueError(f'{spec.label} tested commit disagrees with current inputs')
    if set(data.get('profiles', {})) != set(spec.profiles):
        raise ValueError(f'{spec.label} benchmark profiles are incomplete')
    keys = ('units', 'elapsed_ns', 'allocated_bytes', 'cpu_ns', 'gc_cpu_ns', 'checksum')
    for ident, profile in data['profiles'].items():
        if len(profile.get('samples', [])) != data['repetitions']:
            raise ValueError(f'{spec.label} benchmark repetitions are incomplete')
        for entry in profile['samples']:
            sample(spec, spec.marker + '\t' + ident + '\t' + '\t'.join(str(entry[k]) for k in keys), ident)
        for key in keys[1:-1]:
            expected = statistics.median(s[key] / s['units'] for s in profile['samples'])
            if profile.get('median_' + key + '_per_unit') != expected:
                raise ValueError(f'{spec.label} benchmark summary disagrees with samples')

    if set(data.get('comparisons', {})) != set(spec.pairs):
        raise ValueError(f'{spec.label} comparison profiles are incomplete')
    for name, (candidate, reference) in spec.pairs.items():
        pair = data['comparisons'][name]
        if pair.get('current') != candidate or pair.get('baseline') != reference:
            raise ValueError(f'{spec.label} comparison identity mismatch')
        for key in ('elapsed_ns', 'allocated_bytes'):
            expected = 100 * (data['profiles'][candidate]['median_' + key + '_per_unit'] /
                              data['profiles'][reference]['median_' + key + '_per_unit'] - 1)
            if pair.get('change_percent', {}).get(key) != expected:
                raise ValueError(f'{spec.label} comparison disagrees with samples')


def load_baseline(spec):
    """Require the immutable capture, including both checksummed artifacts.

    The baseline is versioned with this runner. A missing file is a damaged
    validation checkout, rather than permission to skip regression detection.
    Publication repeats this check so deleting/changing it after a run cannot
    leave an apparently valid report pointing to absent or different evidence.
    """
    directory = run.HERE / spec.baseline_directory
    try:
        entries = {}
        for line in (directory / 'SHA256SUMS').read_text().splitlines():
            parts = line.split()
            if len(parts) != 2:
                raise ValueError(f'invalid {spec.label} baseline checksum manifest')
            digest, name = parts
            if name in entries:
                raise ValueError(f'duplicate {spec.label} baseline checksum entry')
            entries[name] = digest
        contents = {name: (directory / name).read_bytes() for name in ('results.json', 'SUMMARY.md')}
    except OSError as error:
        raise ValueError(f'required {spec.label} baseline is missing or unreadable') from error
    if set(entries) != set(contents):
        raise ValueError(f'{spec.label} baseline checksum manifest is incomplete')
    for name, raw in contents.items():
        if hashlib.sha256(raw).hexdigest() != entries[name]:
            raise ValueError(f'{spec.label} baseline checksum mismatch: ' + name)
    baseline = json.loads(contents['results.json'])
    verify_measurements(spec, baseline, baseline['inputs'])
    return baseline, entries['results.json']


def baseline_comparison(spec, data):
    """Recalculate all deltas and alarms from the verified immutable capture."""
    baseline, expected_hash = load_baseline(spec)
    # json round-trips tuples as lists. Compare dependency identities in a
    # canonical form, both before saving a run and during later publication.
    same_dependencies = sorted(map(tuple, data['dependencies'])) == sorted(map(tuple, baseline['dependencies']))
    same = (same_dependencies
            and all(data[key] == baseline[key] for key in ('server', 'machine', 'haskell_benchmark_rts'))
            and all(data['build'][key] == baseline['build'][key] for key in ('ghc', 'cabal'))
            and all(data['inputs']['files'][key] == baseline['inputs']['files'][key] for key in spec.workload_paths))
    comparison = {'reference': live.relative(run.HERE / spec.baseline_directory / 'results.json'),
                  'sha256': expected_hash, 'comparable': same,
                  'timing_investigations': [], 'allocation_investigations': [], 'profiles': {}}
    if same:
        for ident, profile in data['profiles'].items():
            old = baseline['profiles'][ident]
            changes = {key: 100 * (profile['median_' + key + '_per_unit'] / old['median_' + key + '_per_unit'] - 1)
                       for key in ('elapsed_ns', 'allocated_bytes')}
            comparison['profiles'][ident] = changes
            for metric, category in [('elapsed_ns', 'timing_investigations'), ('allocated_bytes', 'allocation_investigations')]:
                if changes[metric] > 5:
                    comparison[category].append({'id': ident, 'percent': changes[metric]})
    return comparison


def attach_baseline_comparison(spec, data):
    """Attach the required baseline comparison after all measurements complete."""
    data['baseline_comparison'] = baseline_comparison(spec, data)


def verify_evidence(spec, data, inputs):
    """Require current measurements and independently verified baseline deltas."""
    verify_measurements(spec, data, inputs)
    if data.get('baseline_comparison') != baseline_comparison(spec, data):
        raise ValueError(f'{spec.label} baseline comparison is missing or disagrees with verified evidence')


def main(spec):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--config', type=Path, default=run.HERE / '.local/environment.json')
    parser.add_argument('--repetitions', type=int, default=7)
    parser.add_argument('--freeze', action='store_true', help='capture this suite’s first immutable baseline; refuses replacement')
    args = parser.parse_args()
    if args.repetitions < 7:
        parser.error('native confirmation requires at least seven process repetitions')
    if args.output.exists():
        parser.error('output directory exists; previous evidence must be retained')
    env = os.environ.copy()
    env.update(json.loads(args.config.read_text()))
    env['TZ'] = 'UTC'
    version = run.sql_client(env, 'SELECT VERSION()')
    if 'MariaDB' not in version:
        raise RuntimeError('expected MariaDB before build')
    baseline_directory = run.HERE / spec.baseline_directory
    if args.freeze:
        if baseline_directory.exists():
            raise ValueError('refusing to replace an immutable feature baseline')
    else:
        load_baseline(spec)
    inputs = live.input_snapshot()
    run.command(['cabal', 'build', 'exe:mariadb-validation', '-O2', '--enable-tests'], timeout=300)
    if any(live.input_snapshot()[key] != inputs[key] for key in ('files', 'commit')):
        raise RuntimeError(f'inputs changed during {spec.label} benchmark build')
    binary = run.executable('exe:mariadb-validation')
    args.output.mkdir(parents=True)
    plan = json.loads((run.ROOT / 'dist-newstyle/cache/plan.json').read_text())
    dependencies = sorted({(p['pkg-name'], p['pkg-version']) for p in plan['install-plan'] if p['pkg-name'] != 'mysql-haskell'})
    data = {'schema': 1, 'recorded_at': live.now(), 'inputs': inputs,
            'server': run.server_metadata(env), 'repetitions': args.repetitions,
            'build': run.snapshot(), 'haskell_benchmark_rts': ['-N4', '-T'],
            'dependencies': dependencies,
            'dependency_plan_sha256': hashlib.sha256(json.dumps(dependencies).encode()).hexdigest(),
            'machine': {'system': platform.system(), 'release': platform.release(),
                        'machine': platform.machine(), 'processor': platform.processor(), 'cpu_count': os.cpu_count()},
            'policy': 'two in-process warmups; shuffled independent processes; same-build alternatives; all samples retained',
            'profiles': {ident: {'samples': []} for ident in spec.profiles}, 'complete': False}
    destination = args.output / 'results.json'
    try:
        for repetition in range(args.repetitions):
            order = list(spec.profiles)
            random.Random(20261107 + repetition).shuffle(order)
            for ident in order:
                output = run.command([binary, spec.command, ident, str(spec.profiles[ident]),
                                      '+RTS', '-N4', '-T', '-RTS'], env=env, timeout=180, check=False)
                (args.output / f'{ident}.{repetition}.log').write_text(output.stdout + output.stderr)
                if output.returncode:
                    raise RuntimeError(f'{spec.label} benchmark process failed: ' + ident)
                data['profiles'][ident]['samples'].append(sample(spec, output.stdout, ident))
                print(spec.marker, repetition + 1, ident, flush=True)
        for profile in data['profiles'].values():
            for key in ('elapsed_ns', 'allocated_bytes', 'cpu_ns', 'gc_cpu_ns'):
                profile['median_' + key + '_per_unit'] = statistics.median(s[key] / s['units'] for s in profile['samples'])
        data['comparisons'] = {}
        for name, (candidate, reference) in spec.pairs.items():
            data['comparisons'][name] = {'current': candidate, 'baseline': reference,
                'change_percent': {key: 100 * (data['profiles'][candidate]['median_' + key + '_per_unit'] /
                    data['profiles'][reference]['median_' + key + '_per_unit'] - 1)
                    for key in ('elapsed_ns', 'allocated_bytes')}}
        if any(live.input_snapshot()[key] != inputs[key] for key in ('files', 'commit')):
            raise RuntimeError(f'inputs changed during {spec.label} benchmark measurement')
        data['complete'] = True
        if args.freeze:
            verify_measurements(spec, data, inputs)
            baseline_directory.mkdir(parents=True, exist_ok=False)
            artifacts = {'results.json': (json.dumps(data, indent=2) + '\n').encode(),
                'SUMMARY.md': (f'# Immutable {spec.label} feature baseline\n\n'
                    f'First complete capture: {data["recorded_at"]}.\n\n'
                    f'Input fingerprint: `{inputs["sha256"]}`.\n\n'
                    f'{args.repetitions} independent process repetitions per profile; '
                    'two warmups per process. All samples and checksums are retained.\n').encode()}
            for name, raw in artifacts.items():
                (baseline_directory / name).write_bytes(raw)
            (baseline_directory / 'SHA256SUMS').write_text(''.join(
                hashlib.sha256(raw).hexdigest() + '  ' + name + '\n' for name, raw in artifacts.items()))
        else:
            attach_baseline_comparison(spec, data)
            verify_evidence(spec, data, inputs)
    except Exception as error:
        data['complete'] = False
        data['error'] = str(error)
        raise
    finally:
        destination.write_text(json.dumps(data, indent=2) + '\n')
