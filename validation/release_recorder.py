#!/usr/bin/env python3
"""Run the frozen benchmark recorder with the fork's package metadata.

``run.py`` is a checksummed historical measurement input. Keep its workloads,
ordering, sampling, comparison policy and bytes unchanged. This adapter admits
exactly two package-identity substitutions and handles the command-line entry
point itself. Both source and adapter hashes are recorded: matching workload
hashes never assert that this metadata adapter existed in the original run.

The pinned source digest makes an unexpected recorder edit a hard failure,
rather than silently deriving a new benchmark from a changed implementation.
"""
import hashlib as _hashlib
from pathlib import Path as _Path

_FROZEN_PATH = _Path(__file__).with_name('run.py')
_FROZEN_SHA256 = 'e756bc0f593b54bc9207fd88d2a53120a4654832650d0a148555a69ebd413346'
_SUBSTITUTIONS = (
    ('ROOT / "mysql-haskell.cabal"', 'ROOT / "mariadb-haskell.cabal"'),
    ('if p["pkg-name"] != "mysql-haskell"', 'if p["pkg-name"] != "mariadb-haskell"'),
)
_ENTRY_POINT = '\nif __name__ == "__main__":\n    raise SystemExit(main())\n'


def _adapt_source(source):
    """Admit identity changes only; never normalize arbitrary recorder edits."""
    if _hashlib.sha256(source).hexdigest() != _FROZEN_SHA256:
        raise ValueError('frozen recorder changed; package metadata adapter requires review')
    text = source.decode('utf-8')
    for old, new in _SUBSTITUTIONS:
        if text.count(old) != 1:
            raise ValueError('unexpected package metadata site in frozen recorder')
        text = text.replace(old, new)
    if not text.endswith(_ENTRY_POINT):
        raise ValueError('unexpected frozen recorder entry point')
    return text.removesuffix(_ENTRY_POINT)


_ADAPTED_SOURCE = _adapt_source(_FROZEN_PATH.read_bytes())
_ADAPTED_SHA256 = _hashlib.sha256(_ADAPTED_SOURCE.encode()).hexdigest()
# Execute trusted, pinned repository code in this module's namespace. This
# preserves ordinary function globals and mockability; no workload is copied
# into a second implementation that could drift away from the original.
exec(compile(_ADAPTED_SOURCE, str(_FROZEN_PATH), 'exec'), globals())
_frozen_snapshot = snapshot


def recorder_identity():
    """Deterministic provenance, independently verifiable during publication."""
    return {
        'frozen_source_sha256': _FROZEN_SHA256,
        'adapter_sha256': _hashlib.sha256(_Path(__file__).read_bytes()).hexdigest(),
        'adapted_source_sha256': _ADAPTED_SHA256,
        'substitutions': [list(pair) for pair in _SUBSTITUTIONS],
        'entry_point': 'validation/release_recorder.py',
    }


def snapshot():
    """Retain frozen workload identities and record the actual metadata adapter."""
    result = _frozen_snapshot()
    result['recorder_adapter'] = recorder_identity()
    return result


def verify_identity(build, files):
    """Reject missing/forged adapter provenance in a release publication."""
    expected = recorder_identity()
    if (files.get('validation/run.py') != expected['frozen_source_sha256']
            or files.get('validation/release_recorder.py') != expected['adapter_sha256']
            or build.get('recorder_adapter') != expected):
        raise ValueError('recorder metadata adapter does not match the tested inputs')


if __name__ == '__main__':
    raise SystemExit(main())
