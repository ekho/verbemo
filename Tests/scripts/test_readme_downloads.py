import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import release
from test_common_release import fixture
spec = importlib.util.spec_from_file_location('readme_downloads', ROOT / 'scripts/update-readme-downloads.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReadmeDownloadsTests(unittest.TestCase):
    def source(self):
        return ('# Custom intro\n[Download for macOS](https://example.invalid/mac)\n'
                '[Download for Windows](https://example.invalid/win)\n'
                '<!-- public-download-versions:start -->\nold\n<!-- public-download-versions:end -->\nKeep me.\n')

    def test_default_never_assumes_a_public_release(self):
        updated = module.updated_readme(self.source(), module.downloads(None))
        self.assertEqual(updated.count('(https://github.com/ekho/verbemo/releases)'), 2)
        self.assertIn('No Verbemo installer release has been verified', updated)
        self.assertTrue(updated.endswith('Keep me.\n'))

    def test_verified_common_artifacts_produce_one_version_and_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifacts = Path(tmp)
            fixture(artifacts)
            release.prepare(artifacts, '0.1.0', 'a' * 40, 12)
            text = module.updated_readme(self.source(), module.downloads(artifacts))
            self.assertIn('verbemo-v0.1.0/Verbemo-0.1.0-macos-universal.dmg', text)
            self.assertIn('verbemo-v0.1.0/Verbemo-0.1.0-windows-x64-Setup.exe', text)
            self.assertIn('**0.1.0**', text)
            (artifacts / 'Verbemo-0.1.0-windows-x64-Setup.exe').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                module.downloads(artifacts)

    def test_missing_duplicate_links_and_blocks_fail(self):
        for source in (self.source().replace('Download for Windows', 'Missing'),
                       self.source() + '[Download for Windows](x)',
                       self.source().replace('public-download-versions:end', 'missing')):
            with self.subTest(source=source), self.assertRaises(ValueError):
                module.updated_readme(source, module.downloads(None))
