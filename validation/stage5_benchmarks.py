#!/usr/bin/env python3
"""CDC decoding, checked framing, live delivery and retained streaming heap."""
from pathlib import Path
import feature_benchmarks as features

PROFILES = {'cdc.decode.single-table': 10000, 'cdc.decode.interleaved': 10000,
            'cdc.decode.sparse-update': 10000, 'cdc.decode.compressed': 2000, 'cdc.framing.crc32': 20000,
            'cdc.live.rows': 1000, 'cdc.live.checkpoints': 100, 'cdc.retention': 1000000}
BASELINE_DIRECTORY = Path('baselines/macos-arm64-cdc')
WORKLOAD_PATHS = ('validation/hs/Validation/Stage5Bench.hs', 'validation/hs/Validation/Common.hs')


def specification():
    return features.FeatureSpec(marker='STAGE5', command='stage5-bench', label='CDC',
        profiles=PROFILES, units=PROFILES,
        checksums={name: n*(n+1)//2 if name.startswith('cdc.decode.') or name=='cdc.retention' else n
                   for name,n in PROFILES.items()}, pairs={},
        baseline_directory=BASELINE_DIRECTORY, workload_paths=WORKLOAD_PATHS,
        heap_profiles={'cdc.retention': (1000,10000,100000,1000000)})


def verify_evidence(data, inputs):
    features.verify_evidence(specification(), data, inputs)


if __name__ == '__main__':
    features.main(specification())
