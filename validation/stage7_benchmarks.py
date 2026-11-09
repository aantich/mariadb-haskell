#!/usr/bin/env python3
"""Independent PAM/Kerberos establishment costs; existing workloads stay frozen."""
from pathlib import Path
import hashlib
import json
import re
import feature_benchmarks as features
import auth_fixture
import release_recorder as run

PROFILES = {'auth.pam.password': 10, 'auth.pam.multiple': 10,
            'auth.gssapi.cached-ticket': 10}
WORKLOAD_PATHS = ('validation/hs/Validation/Stage7Bench.hs',
                  'validation/hs/Validation/ExternalAuthFixture.hs',
                  'validation/hs/Validation/Common.hs',
                  'validation/auth_fixture/Dockerfile',
                  'validation/auth_fixture/serve.py',
                  'validation/auth_fixture/pam_fixture.c')


def legacy_runtime_aliases():
    """Bind the exact first provenance index to its verified runtime only.

    The frozen measurements are untouched. Both build logs identify the same
    configuration blob; its cryptographic digest and complete filesystem/config
    prove this historical equivalence. All other unknown indexes stay distinct.
    """
    folder = run.HERE/'results/experiments'
    proof = json.loads((folder/'stage7-runtime-equivalence.json').read_text())
    raw = (folder/'stage7-authentication-image-config.json').read_bytes()
    expected = 'sha256:'+hashlib.sha256(raw).hexdigest()
    if expected != proof['first_and_verified_runtime_config_digest']:
        raise ValueError('authentication runtime configuration digest mismatch')
    logs = [('stage7-first-authentication.log', 'first_build_log_sha256'),
            ('stage7-runtime-identity-build.log', 'verification_build_log_sha256')]
    for filename, key in logs:
        content = (folder/filename).read_bytes()
        if hashlib.sha256(content).hexdigest() != proof[key]:
            raise ValueError('authentication runtime proof log mismatch')
        if re.findall(r'exporting config (sha256:[0-9a-f]{64})', content.decode()) != [expected]:
            raise ValueError('authentication build did not use the verified configuration')
    original = 'sha256:065d10313899e7a007821c2c052b87608b26a82629e4db273b72987e3cddd12f'
    if proof['first_capture_index'] != original or original not in (folder/logs[0][0]).read_text():
        raise ValueError('authentication initial provenance index mismatch')
    blob = json.loads(raw)
    image = {'Architecture': blob['architecture'], 'Os': blob['os'], 'Variant': blob.get('variant'),
             'RootFS': {'Type': blob['rootfs']['type'], 'Layers': blob['rootfs']['diff_ids']},
             'Config': blob['config']}
    identity = auth_fixture.runtime_identity(image)
    if identity != proof['runtime_identity'] or identity != auth_fixture.runtime_identity(proof['runtime_fields']):
        raise ValueError('authentication runtime fingerprint mismatch')
    return {'MB_AUTH_FIXTURE_IMAGE_ID': {original: identity}}


def specification():
    return features.FeatureSpec(marker='STAGE7', command='stage7-bench',
        label='External authentication', profiles=PROFILES, units=PROFILES,
        checksums=PROFILES, pairs={},
        baseline_directory=Path('baselines/macos-arm64-external-authentication'),
        workload_paths=WORKLOAD_PATHS,
        environment_profile=('MB_AUTH_FIXTURE_IMAGE_ID',),
        environment_profile_aliases=legacy_runtime_aliases())


def verify_evidence(data, inputs):
    features.verify_evidence(specification(), data, inputs)


if __name__ == '__main__':
    features.main(specification())
