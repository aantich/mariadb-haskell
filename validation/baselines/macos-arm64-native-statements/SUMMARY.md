# First native MariaDB statement benchmark baseline

Immutable first complete native-feature capture from Stage 3; separate from the unchanged-driver baseline.
Uncommitted source fingerprint: `395006f8cb9f59985e50182acbe91e507f3597c8f8b2f6be36098822d3e44d91`. Seven process repetitions per profile, with two in-process warmups. Same-build comparisons retain their original baselines and all raw samples. This capture does not advance the accepted performance reference.

| Profile | Baseline ns/unit | Baseline allocated bytes/unit |
| --- | ---: | ---: |
| `bulk.native` | 1,873.40 | 2,361.50 |
| `bulk.units` | 2,151.60 | 3,520.85 |
| `bulk.prepared` | 41,574.80 | 26,584.72 |
| `bulk.text-batch` | 11,052.40 | 10,809.32 |
| `prepared.narrow.cached` | 37,894.00 | 27,015.94 |
| `prepared.narrow.uncached` | 40,872.00 | 32,064.82 |
| `prepared.wide.cached` | 55,918.00 | 47,966.10 |
| `prepared.wide.uncached` | 75,112.00 | 181,114.27 |
