import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReleaseManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('release_manifest', ROOT / 'scripts/release_manifest.py')
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_stable_three_component_versions_only(self):
        for version in ('0.1.0', '1.20.300'):
            self.assertEqual(self.module.validate_version(version), version)
        for version in ('v0.1.0', '01.2.3', '1.2', '1.2.3-beta', '1.2.3+build', '1.2.3\n', '../1.2.3'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.module.validate_version(version)

    def test_receipt_and_appcast_validate_final_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version, commit, build = '0.1.0', 'a' * 40, 12
            dmg = root / 'Verbemo-0.1.0-macos-universal.dmg'
            dmg.write_bytes(b'final stapled bytes')
            signature = 'c' * 86 + '=='
            self.module.write_appcast(root, version, build, signature, '14.2')
            self.module.write_macos_receipt(root, version, commit, build)
            result = self.module.validate_macos_release(root, version, commit, build)
            self.assertEqual(result['source_commit'], commit)
            checksum = self.module.write_checksums(root, [p.name for p in root.iterdir()])
            self.assertIn('macos-build.json', checksum.read_text())
            self.assertNotIn('SHA256SUMS', checksum.read_text())
            dmg.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                self.module.validate_macos_release(root, version, commit, build)

    def test_receipt_rejects_mismatched_metadata_and_unsafe_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Verbemo-0.1.0-macos-universal.dmg').write_bytes(b'bytes')
            self.module.write_appcast(root, '0.1.0', 12, 'c' * 86 + '==', '14.2')
            self.module.write_macos_receipt(root, '0.1.0', 'a' * 40, 12)
            for version, commit, build in [('0.2.0', 'a' * 40, 12), ('0.1.0', 'b' * 40, 12), ('0.1.0', 'a' * 40, 13)]:
                with self.assertRaises(ValueError):
                    self.module.validate_macos_release(root, version, commit, build)
            receipt = root / 'macos-build.json'
            data = json.loads(receipt.read_text())
            data['files'][0]['name'] = '../outside'
            receipt.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                self.module.validate_macos_release(root, '0.1.0', 'a' * 40, 12)


class WindowsManifestTests(unittest.TestCase):
    setUpClass = classmethod(ReleaseManifestTests.setUpClass.__func__)

    def fixture(self, root, version='0.1.0', commit='a' * 40, build=12):
        names = [f'Verbemo-{version}-windows-x64-Setup.exe', f'Verbemo-{version}-windows-x64-Portable.zip',
                 f'Verbemo-{version}-stable-full.nupkg', 'assets.stable.json', 'releases.stable.json']
        for name in names:
            (root / name).write_bytes(b'fixture final bytes')
        package = self.module.file_record(root / names[2])
        (root / 'releases.stable.json').write_text(json.dumps({'Assets': [{
            'PackageId': 'Verbemo', 'Version': version, 'Type': 'Full', 'FileName': names[2],
            'SHA256': package['sha256'], 'Size': package['size']}]}))
        (root / 'assets.stable.json').write_text(json.dumps([
            {'RelativeFileName': name, 'Type': kind}
            for name, kind in zip(names, ['Installer', 'Portable', 'Full'])]))
        receipt = {'platform': 'windows', 'version': version, 'source_commit': commit,
                   'build_number': build, 'publishable': True,
                   'signature': {'authenticode': 'verified', 'timestamp': 'verified',
                                 'certificate_thumbprint': 'A' * 40},
                   'files': [self.module.file_record(root / name) for name in names]}
        (root / 'windows-build.json').write_text(json.dumps(receipt))
        return receipt

    def test_windows_receipt_feed_inventory_and_bytes_agree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.module.validate_windows_release(root, '0.1.0', 'a' * 40, 12)
            (root / 'Verbemo-0.1.0-stable-full.nupkg').unlink()
            with self.assertRaises(ValueError):
                self.module.validate_windows_release(root, '0.1.0', 'a' * 40, 12)

    def test_windows_rejects_unsigned_mismatch_and_external_or_old_packages(self):
        for mutation in ('development', 'version', 'source', 'build', 'external', 'old', 'hash', 'inventory'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                receipt = self.fixture(root)
                if mutation == 'development': receipt['publishable'] = False
                if mutation == 'version': receipt['version'] = '0.2.0'
                if mutation == 'source': receipt['source_commit'] = 'b' * 40
                if mutation == 'build': receipt['build_number'] = 13
                if mutation in ('external', 'old', 'hash'):
                    feed = json.loads((root / 'releases.stable.json').read_text())
                    asset = feed['Assets'][0]
                    if mutation == 'external': asset['FileName'] = 'https://elsewhere.invalid/full.nupkg'
                    if mutation == 'old': asset['Version'] = '0.0.1'
                    if mutation == 'hash': asset['SHA256'] = '0' * 64
                    (root / 'releases.stable.json').write_text(json.dumps(feed))
                if mutation == 'inventory':
                    (root / 'assets.stable.json').write_text('[]')
                # Refresh receipt hashes so feed/inventory policy, not stale bytes, rejects it.
                receipt['files'] = [self.module.file_record(root / item['name']) for item in receipt['files']]
                (root / 'windows-build.json').write_text(json.dumps(receipt))
                with self.assertRaises(ValueError):
                    self.module.validate_windows_release(root, '0.1.0', 'a' * 40, 12)


class SparkleSignatureTests(unittest.TestCase):
    def test_cryptokit_verifies_rfc8032_vector_and_rejects_other_public_key(self):
        import base64
        import os
        import subprocess
        import sys
        if sys.platform != 'darwin':
            self.skipTest('CryptoKit verification requires macOS')
        # RFC 8032 test vector 1: public information only, no key generation.
        key = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
                                  'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        with tempfile.TemporaryDirectory() as directory:
            message = Path(directory) / 'message'
            message.write_bytes(b'')
            for public, expected in [(key, 0), (bytes(32), 1)]:
                env = dict(os.environ, VERBEMO_SPARKLE_PUBLIC_KEY=base64.b64encode(public).decode())
                result = subprocess.run(['swift', str(ROOT / 'scripts/verify-sparkle-signature.swift'),
                                         str(message), base64.b64encode(signature).decode()],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertIn('public/private key mismatch', result.stderr)


class CredentialValidationTests(unittest.TestCase):
    setUpClass = classmethod(ReleaseManifestTests.setUpClass.__func__)
    def test_malformed_and_mismatched_keys_fail_without_disclosing_key(self):
        import base64
        with tempfile.TemporaryDirectory() as directory:
            private = Path(directory) / 'fixture-private'
            notary = Path(directory) / 'fixture-notary'
            notary.write_text('fixture')
            env = {'VERBEMO_SIGN_ID': 'Developer ID Application: Fixture (FIXTURE)',
                   'VERBEMO_SPARKLE_PUBLIC_KEY': base64.b64encode(bytes(32)).decode(),
                   'VERBEMO_SPARKLE_PRIVATE_KEY_FILE': str(private),
                   'VERBEMO_NOTARY_KEY_FILE': str(notary), 'VERBEMO_NOTARY_KEY_ID': 'fixture',
                   'VERBEMO_NOTARY_ISSUER_ID': 'fixture'}
            private.write_text('not-a-valid-private-secret')
            with self.assertRaisesRegex(ValueError, '^invalid Sparkle private key file$'):
                self.module.validate_credentials(env)
            private.write_text(base64.b64encode(bytes(64) + bytes([1]) * 32).decode())
            with self.assertRaisesRegex(ValueError, 'public/private key mismatch'):
                self.module.validate_credentials(env)
            env['VERBEMO_SIGN_ID'] = '-'
            with self.assertRaisesRegex(ValueError, 'Developer ID Application'):
                self.module.validate_credentials(env)


if __name__ == "__main__":
    unittest.main()
