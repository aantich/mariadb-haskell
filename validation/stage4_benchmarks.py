#!/usr/bin/env python3
"""Complete reset/restore/prepare requests versus reconnects, plus snapshot cost."""
from pathlib import Path
import feature_benchmarks as features

PROFILES = {**{f'reuse.{transport}.{mode}': 30
              for transport in ('tcp', 'tls', 'socket') for mode in ('reset', 'reconnect')},
            'session.snapshot': 100000}
PAIRS = {transport: (f'reuse.{transport}.reset', f'reuse.{transport}.reconnect')
         for transport in ('tcp', 'tls', 'socket')}
BASELINE_DIRECTORY = Path('baselines/macos-arm64-session-reuse')
WORKLOAD_PATHS = ('validation/hs/Validation/Stage4Bench.hs', 'validation/hs/Validation/Common.hs')


def specification():
    return features.FeatureSpec(marker='STAGE4', command='stage4-bench', label='session reuse',
        profiles=PROFILES, units=PROFILES, checksums=PROFILES, pairs=PAIRS,
        baseline_directory=BASELINE_DIRECTORY, workload_paths=WORKLOAD_PATHS)


def verify_evidence(data, inputs):
    return features.verify_evidence(specification(), data, inputs)


def main():
    return features.main(specification())


if __name__ == '__main__':
    main()
