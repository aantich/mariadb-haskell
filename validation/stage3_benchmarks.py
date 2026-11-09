#!/usr/bin/env python3
"""Native statement workloads; the shared recorder preserves all evidence guards."""
from pathlib import Path
import release_recorder as run
import feature_benchmarks as features

PROFILES = {
    'bulk.native': 5, 'bulk.units': 5, 'bulk.prepared': 5, 'bulk.text-batch': 5,
    'prepared.narrow.cached': 500, 'prepared.narrow.uncached': 500,
    'prepared.wide.cached': 500, 'prepared.wide.uncached': 500,
}
PAIRS = {
    'native_vs_sequential': ('bulk.native', 'bulk.prepared'),
    'native_vs_text_batch': ('bulk.native', 'bulk.text-batch'),
    'unit_vs_aggregate': ('bulk.units', 'bulk.native'),
    'cached_vs_uncached_narrow': ('prepared.narrow.cached', 'prepared.narrow.uncached'),
    'cached_vs_uncached_wide': ('prepared.wide.cached', 'prepared.wide.uncached'),
}
BASELINE_DIRECTORY = Path('baselines/macos-arm64-native-statements')
# Warm-ups and the measured regions live in these Haskell sources. Python
# evidence-policy fixes must not disable comparisons with an unchanged workload.
# The sample checks below separately enforce each profile's units/iterations.
WORKLOAD_PATHS = ('validation/hs/Validation/Stage3Bench.hs', 'validation/hs/Validation/Common.hs')


def specification():
    return features.FeatureSpec(
        marker='STAGE3', command='stage3-bench', label='native',
        profiles=PROFILES,
        units={ident: count * (1000 if ident.startswith('bulk.') else 1) for ident,count in PROFILES.items()},
        checksums={ident: count * (629500 if ident.startswith('bulk.') else 3847 if '.wide.' in ident else 7)
                   for ident,count in PROFILES.items()},
        pairs=PAIRS, baseline_directory=BASELINE_DIRECTORY, workload_paths=WORKLOAD_PATHS)


def sample(output, ident):
    return features.sample(specification(), output, ident)


def verify_measurements(data, inputs):
    return features.verify_measurements(specification(), data, inputs)


def load_native_baseline():
    return features.load_baseline(specification())


def native_baseline_comparison(data):
    return features.baseline_comparison(specification(), data)


def compare_native_baseline(data):
    return features.attach_baseline_comparison(specification(), data)


def verify_evidence(data, inputs):
    return features.verify_evidence(specification(), data, inputs)


def main():
    return features.main(specification())


if __name__ == '__main__':
    main()
