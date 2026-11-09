#!/usr/bin/env python3
"""Streamed parameters, cursor batches and optional wire feature costs."""
from pathlib import Path
import sys
import feature_benchmarks as features
import release_recorder as run

PROFILES = {'upload.buffered': 4, 'upload.streamed': 4, 'upload.retention': 67108864,
            'cursor.stream': 1, 'cursor.batch32': 1, 'cursor.batch512': 1, 'cursor.batch4096': 1,
            'transport.narrow.plain': 2, 'transport.narrow.zlib': 2,
            'transport.wide.plain': 2, 'transport.wide.zlib': 2,
            'progress.disabled': 500, 'progress.enabled': 500}
BASELINE_DIRECTORY = Path('baselines/macos-arm64-wire-features')
WORKLOAD_PATHS = ('validation/hs/Validation/Stage6Bench.hs', 'validation/hs/Validation/Common.hs')


def specification():
    units, checksums = {}, {}
    for name, count in PROFILES.items():
        if name == 'upload.retention':
            units[name] = checksums[name] = count
        elif name.startswith('upload.'):
            units[name] = checksums[name] = count * 1048576
        elif name.startswith('cursor.'):
            units[name], checksums[name] = count * 10000, count * 51285000
        elif name.startswith('transport.'):
            width = 2048 if '.wide.' in name else 32
            units[name], checksums[name] = count * 1000, count * (500500 + 1000 * width)
        else:
            units[name], checksums[name] = count, count * 937
    return features.FeatureSpec(marker='STAGE6', command='stage6-bench', label='Wire features',
        profiles=PROFILES, units=units, checksums=checksums,
        pairs={'streamed upload': ('upload.streamed', 'upload.buffered'),
               **{f'cursor batch {size}': (f'cursor.batch{size}', 'cursor.stream') for size in (32, 512, 4096)},
               **{f'{width} compression': (f'transport.{width}.zlib', f'transport.{width}.plain') for width in ('narrow','wide')},
               'progress negotiation': ('progress.enabled', 'progress.disabled')},
        baseline_directory=BASELINE_DIRECTORY, workload_paths=WORKLOAD_PATHS,
        heap_profiles={'upload.retention': (65536, 1048576, 16777216, 67108864)})


def verify_evidence(data, inputs):
    features.verify_evidence(specification(), data, inputs)


def verify_buffering_control(binary):
    """The real retained-heap guard must reject a whole-source consumer."""
    result = run.command([binary, 'stage6-heap-control', '+RTS', '-N4', '-T', '-RTS'], timeout=30)
    entries = [list(map(int, line.split('\t')[1:])) for line in result.stdout.splitlines()
               if line.startswith('STAGE6_HEAP\t')]
    try:
        features.verify_heap(specification(), 'upload.retention', entries)
    except ValueError as error:
        if 'grows beyond' not in str(error):
            raise
    else:
        raise ValueError('whole-source buffering escaped the retained-heap guard')
    print('Whole-source buffering rejected by the retained-heap guard; all checkpoints retained.')
    print(result.stdout, end='')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--verify-heap-control':
        verify_buffering_control(sys.argv[2])
    else:
        features.main(specification())
