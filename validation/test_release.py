"""Release identity must preserve measurements, credentials and package boundaries."""
import hashlib
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

import release_recorder as recorder
import run as frozen

ROOT = Path(__file__).resolve().parents[1]


def tool(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecorderIdentity(unittest.TestCase):
    def test_original_recorder_stays_exact(self):
        source = (ROOT / 'validation/run.py').read_bytes()
        self.assertEqual(recorder._FROZEN_SHA256, hashlib.sha256(source).hexdigest())
        original = source.decode().removesuffix(recorder._ENTRY_POINT)
        adapted = recorder._adapt_source(source)
        for old, new in recorder._SUBSTITUTIONS:
            adapted = adapted.replace(new, old)
        self.assertEqual(original, adapted)

    def test_workload_or_policy_edits_are_never_admitted(self):
        source = (ROOT / 'validation/run.py').read_bytes()
        for old, new in [(b'range(args.repetitions)', b'range(1)'),
                         (b'* 1.20', b'* 2.0'), (b'mysql-haskell.cabal', b'other.cabal')]:
            self.assertIn(old, source)
            with self.assertRaisesRegex(ValueError, 'frozen recorder changed'):
                recorder._adapt_source(source.replace(old, new))

    def test_frozen_measurement_functions_are_identical(self):
        # The functions keep their original code objects apart from module
        # metadata sites. A package rename cannot alter percentile calculations.
        self.assertEqual(frozen.percentile.__code__.co_code, recorder.percentile.__code__.co_code)
        self.assertEqual(frozen.compare.__code__.co_code, recorder.compare.__code__.co_code)

    def test_adapter_provenance_is_required_and_verified(self):
        proof = recorder.recorder_identity()
        files = {'validation/run.py': proof['frozen_source_sha256'],
                 'validation/release_recorder.py': proof['adapter_sha256']}
        recorder.verify_identity({'recorder_adapter': proof}, files)
        for build in [{}, {'recorder_adapter': {**proof, 'adapter_sha256': 'forged'}}]:
            with self.assertRaisesRegex(ValueError, 'metadata adapter'):
                recorder.verify_identity(build, files)
        with self.assertRaisesRegex(ValueError, 'metadata adapter'):
            recorder.verify_identity({'recorder_adapter': proof}, {**files, 'validation/run.py': 'changed'})


class ReleaseSources(unittest.TestCase):
    def test_current_utf8_ca_names_and_checksum(self):
        updater = tool('update_ca_bundle')
        source = (ROOT / 'mozillaCAStore.pem').read_bytes()
        self.assertEqual(118, updater.validate(source, hashlib.sha256(source).hexdigest()))
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            updater.validate(source + b'changed', hashlib.sha256(source).hexdigest())

    def test_incomplete_or_empty_ca_bundle_is_rejected(self):
        updater = tool('update_ca_bundle')
        for source in [b'', b'-----BEGIN CERTIFICATE-----\ntruncated']:
            with self.assertRaisesRegex(ValueError, 'empty or incomplete'):
                updater.validate(source, hashlib.sha256(source).hexdigest())

    def test_private_traversal_and_special_archive_entries_are_rejected(self):
        checker = tool('check_release')
        for name, kind in [('package/../escape', tarfile.DIRTYPE),
                           ('package/.local', tarfile.DIRTYPE),
                           ('package/cabal.project', tarfile.REGTYPE),
                           ('package/cabal.project.local', tarfile.REGTYPE),
                           ('package/link', tarfile.SYMTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                archive = Path(folder) / 'package.tar.gz'
                with tarfile.open(archive, 'w:gz') as output:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    output.addfile(entry)
                with self.assertRaises(ValueError):
                    checker.unpack(archive, Path(folder) / 'unpacked', 'package')


if __name__ == '__main__':
    unittest.main()
