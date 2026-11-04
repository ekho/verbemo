import base64
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEED_URL = 'https://github.com/ekho/verbemo/releases/latest/download/appcast.xml'


class UpdateFeedLocationTests(unittest.TestCase):
    def build_plist(self, key, *flags, expected_error=None):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'Info.plist'
            env = dict(os.environ, VERBEMO_SPARKLE_PUBLIC_KEY=key)
            result = subprocess.run(['python3', str(ROOT / 'scripts/build-macos-plist.py'),
                                     str(ROOT / 'Packaging/Verbemo-Info.plist'), str(target),
                                     '--version', '0.1.0', '--build', '42', *flags],
                                    env=env, capture_output=True, text=True)
            if expected_error is not None:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(target.exists())
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            return plistlib.loads(target.read_bytes())

    def test_development_bundle_disables_updates_without_key(self):
        info = self.build_plist('')
        self.assertNotIn('VerbemoPreview', info)
        self.assertNotIn('SUPublicEDKey', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])

    def test_keyed_bundle_uses_only_own_feed_and_build(self):
        key = base64.b64encode(bytes(range(32))).decode()
        info = self.build_plist(key)
        self.assertNotIn('VerbemoPreview', info)
        self.assertEqual(info['SUPublicEDKey'], key)
        self.assertEqual(info['SUFeedURL'], FEED_URL)
        self.assertEqual(info['CFBundleVersion'], '42')
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0')

    def test_preview_bundle_marks_preview_without_enabling_sparkle(self):
        info = self.build_plist('', '--preview')
        self.assertIs(info['VerbemoPreview'], True)
        self.assertNotIn('SUPublicEDKey', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])

    def test_preview_bundle_rejects_sparkle_key(self):
        key = base64.b64encode(bytes(range(32))).decode()
        self.build_plist(key, '--preview', expected_error='Preview cannot use a Sparkle key')


if __name__ == '__main__':
    unittest.main()
