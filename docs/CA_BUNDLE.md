# Bundled Mozilla trust roots

`MozillaCAStore` uses a static Mozilla CA extract provided by
[curl's CA Extract service](https://curl.se/docs/caextract.html). The current
snapshot is **5 November 2026**, with **118 certificates**. Its exact source URL,
published checksum, retrieval date and certificate count are in `ca-bundle.json`.
The shipped bytes have SHA-256
`427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`.

The extract is distributed under **MPL-2.0**; its notices are preserved in the
PEM file and the full license ships as `LICENSE-MPL-2.0`. The driver's own code
retains its BSD 3-Clause license. The Cabal license expression describes both
components. This is an explicit replacement of the inherited June 2017 bundle.

Runtime connections do not download roots. Package updates carry reviewed
snapshots; OS/custom trust stores remain preferable when applications need a
different or independently managed update policy. The PEM extract does not
contain all Firefox domain/policy constraints, as curl's source page explains.
It is not a copy of every browser's certificate-validation policy.

## Maintenance

Before each release, check the source page for a newer dated extract and review
its published checksum and changes. Update only an explicit dated version:

```sh
python3 tools/update_ca_bundle.py --version 2026-11-05 \
  --sha256 427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285
python3 tools/update_ca_bundle.py --check
```

The updater verifies the requested digest against both downloaded bytes and the
source's checksum, then checks all PEM blocks. Commit the bundle and provenance
together. Re-run installed-data checks, verified TLS rejection/success cases and
the complete validation workflow before publication. Do not silently refresh
trust roots during a benchmark or a connection attempt.
