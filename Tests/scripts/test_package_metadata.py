import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import release
from test_common_release import fixture

class PackageMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.artifacts = self.root / 'release'; self.artifacts.mkdir()
        fixture(self.artifacts); release.prepare(self.artifacts, '0.1.0', 'a' * 40, 12)
        spec = importlib.util.spec_from_file_location('packages', ROOT / 'scripts/generate-package-metadata.py')
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)

    def test_generated_metadata_uses_actual_common_hashes_and_signing_receipt(self):
        out = self.root / 'catalog'
        self.module.generate(self.artifacts, out, 'TestPublisher.Verbemo')
        scoop = json.loads((out / 'verbemo.json').read_text())
        import hashlib
        portable = self.artifacts / 'Verbemo-0.1.0-windows-x64-Portable.zip'
        self.assertEqual(scoop['architecture']['64bit']['hash'], hashlib.sha256(portable.read_bytes()).hexdigest())
        self.assertTrue(scoop['architecture']['64bit']['url'].startswith('https://github.com/ekho/verbemo/releases/download/verbemo-v0.1.0/'))
        installer = (out / 'TestPublisher.Verbemo.installer.yaml').read_text()
        self.assertIn('PackageIdentifier: "TestPublisher.Verbemo"', installer)
        self.assertIn('Verbemo-0.1.0-windows-x64-Setup.exe', installer)
        self.assertNotIn('Fands', installer)
        evidence = json.loads((out / 'preparation-evidence.json').read_text())
        self.assertEqual(evidence['source_commit'], 'a' * 40)
        self.assertEqual(evidence['signature']['authenticode'], 'verified')
        self.assertEqual(evidence['signature']['certificate_thumbprint'], 'A' * 40)
        self.assertFalse(evidence['catalog_ready'])

    def test_tampered_missing_or_unsigned_set_does_not_create_output(self):
        for mutation in ('tamper', 'missing', 'unsigned'):
            path = self.artifacts / 'windows-build.json'; old = path.read_bytes()
            installer = self.artifacts / 'Verbemo-0.1.0-windows-x64-Setup.exe'; original = installer.read_bytes()
            if mutation == 'tamper': installer.write_bytes(b'wrong')
            elif mutation == 'missing': path.unlink()
            else:
                receipt = json.loads(old); receipt['publishable'] = False; path.write_text(json.dumps(receipt))
            output = self.root / mutation
            with self.subTest(mutation=mutation), self.assertRaises((ValueError, OSError)):
                self.module.generate(self.artifacts, output)
            self.assertFalse(output.exists())
            path.write_bytes(old); installer.write_bytes(original)

    def test_output_must_be_new_outside_artifacts_and_identifier_explicit_valid(self):
        for out, identifier in ((self.artifacts / 'nested', None), (self.artifacts, None),
                                (self.root / 'bad-id', 'Verbemo'), (self.root / 'too-long', 'Publisher.' + 'V' * 129), (self.root / 'bad-path', '../Publisher.Verbemo')):
            with self.subTest(out=out), self.assertRaises(ValueError): self.module.generate(self.artifacts, out, identifier)
        output = self.root / 'scoop-only'; self.module.generate(self.artifacts, output)
        self.assertEqual(len(list(output.glob('*.yaml'))), 0)
        with self.assertRaises(ValueError): self.module.generate(self.artifacts, output)
