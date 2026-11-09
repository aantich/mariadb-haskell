#!/usr/bin/env python3
"""Verify the installed CA snapshot or explicitly update a pinned curl extract.

Updates require a dated release and its independently reviewed SHA-256. The
published checksum must also agree. Runtime connections never fetch trust roots;
the reviewed file, notices and provenance ship together in the source package.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import ssl
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'mozillaCAStore.pem'
MANIFEST = ROOT / 'ca-bundle.json'


def validate(data, expected):
    """Check exact identity and every complete PEM block before installation."""
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected:
        raise ValueError('CA bundle SHA-256 does not match the reviewed checksum')
    # PEM payloads are ASCII, but Mozilla's human-readable CA names are UTF-8.
    text = data.decode('utf-8')
    certificates = re.findall(r'-----BEGIN CERTIFICATE-----\s.*?-----END CERTIFICATE-----', text, re.S)
    if not certificates or len(certificates) != text.count('-----BEGIN CERTIFICATE-----'):
        raise ValueError('empty or incomplete CA certificate bundle')
    for certificate in certificates:
        ssl.PEM_cert_to_DER_cert(certificate)
    return len(certificates)


def check():
    metadata = json.loads(MANIFEST.read_text())
    count = validate(BUNDLE.read_bytes(), metadata['sha256'])
    if count != metadata['certificate_count']:
        raise ValueError('CA certificate count disagrees with the provenance manifest')
    if not (ROOT / 'LICENSE-MPL-2.0').is_file():
        raise ValueError('bundled CA license is missing')
    print(f"Verified Mozilla extract {metadata['version']}: {count} certificates, {metadata['sha256']}")


def download(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read(2 * 1024 * 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--version', help='dated curl extract, YYYY-MM-DD')
    parser.add_argument('--sha256', help='reviewed checksum from the curl CA extract page')
    args = parser.parse_args()
    if args.check:
        if args.version or args.sha256:
            parser.error('--check cannot update a bundle')
        check()
        return
    if not args.version or not args.sha256 or not re.fullmatch('[0-9a-f]{64}', args.sha256):
        parser.error('an update requires --version YYYY-MM-DD and --sha256 HEX')
    datetime.date.fromisoformat(args.version)
    url = f'https://curl.se/ca/cacert-{args.version}.pem'
    data = download(url)
    published = download(url + '.sha256').decode('ascii').split()[0]
    if published != args.sha256:
        raise ValueError('published checksum differs from the reviewed checksum')
    count = validate(data, args.sha256)
    metadata = {'version': args.version, 'source': url, 'checksum_source': url + '.sha256',
                'sha256': args.sha256, 'certificate_count': count, 'license': 'MPL-2.0',
                'source_information': 'https://curl.se/docs/caextract.html',
                'retrieved_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    BUNDLE.write_bytes(data)
    MANIFEST.write_text(json.dumps(metadata, indent=2) + '\n')
    check()


if __name__ == '__main__':
    main()
