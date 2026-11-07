# Invalid diagnostic experiment — excluded from conclusions

`decoder-boundary-force.json` accidentally measured the preceding executable after a build failed. Its source fingerprint therefore does not identify the measured executable. The numeric observations are retained for audit only and must not be used in comparisons or acceptance. The focused runner now requires a successful fresh build and stable input fingerprints before measuring. The complete check.py runner already stopped on build failure; no full-suite publication used this invalid experiment.
