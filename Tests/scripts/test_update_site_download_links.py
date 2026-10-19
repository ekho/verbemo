import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from download_metadata import downloads
import release
from test_common_release import fixture
spec = importlib.util.spec_from_file_location('site_downloads', ROOT / 'scripts/update-site-download-links.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class UpdateSiteDownloadLinksTests(unittest.TestCase):
    def test_both_languages_and_platforms_use_same_verified_common_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); artifacts = root / 'artifacts'; artifacts.mkdir()
            fixture(artifacts); release.prepare(artifacts, '0.1.0', 'a' * 40, 12)
            site = root / 'site'; (site / 'ru').mkdir(parents=True)
            for relative in ('index.html', 'ru/index.html'):
                (site / relative).write_text((ROOT / 'landing' / relative).read_text())
            module.update_pages(site, downloads(artifacts))
            for relative in ('index.html', 'ru/index.html'):
                text = (site / relative).read_text()
                self.assertEqual(text.count('/verbemo-v0.1.0/Verbemo-0.1.0-macos-universal.dmg'), 2)
                self.assertEqual(text.count('/verbemo-v0.1.0/Verbemo-0.1.0-windows-x64-Setup.exe'), 2)
                self.assertIn('href="https://github.com/ekho/verbemo"', text)
            module.update_pages(site, downloads())
            self.assertNotIn('/releases/download/', (site / 'index.html').read_text())
            before = (site / 'index.html').read_text()
            (site / 'ru/index.html').write_text('malformed')
            with self.assertRaises(ValueError): module.update_pages(site, downloads())
            self.assertEqual((site / 'index.html').read_text(), before)
