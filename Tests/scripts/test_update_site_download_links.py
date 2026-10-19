import contextlib
import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from download_metadata import downloads
import release
from test_common_release import fixture
spec = importlib.util.spec_from_file_location('site_downloads', ROOT / 'scripts/update-site-download-links.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

checker_spec = importlib.util.spec_from_file_location('landing_check', ROOT / 'landing/tests/check.py')
checker = importlib.util.module_from_spec(checker_spec)
checker_spec.loader.exec_module(checker)


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

    def test_landing_gate_accepts_default_and_updater_prepared_release_then_rejects_inconsistent_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            site = root / 'site'
            shutil.copytree(ROOT / 'landing', site)
            artifacts = root / 'artifacts'
            artifacts.mkdir()
            fixture(artifacts)
            release.prepare(artifacts, '0.1.0', 'a' * 40, 12)

            def gate():
                with patch.object(checker, 'LANDING', site), patch.object(checker, 'failures', []), contextlib.redirect_stdout(io.StringIO()) as output:
                    status = checker.main()
                return status, output.getvalue()

            self.assertEqual(gate()[0], 0, 'default Releases policy must remain valid')
            module.update_pages(site, downloads(artifacts))
            status, output = gate()
            self.assertEqual(status, 0, output)
            original = (site / 'ru/index.html').read_text()
            mac_url = downloads(artifacts)[1]['macOS']
            invalid = {
                'mixed language versions': original.replace('0.1.0', '0.2.0'),
                'wrong repository': original.replace('/ekho/verbemo/releases/', '/other/verbemo/releases/'),
                'wrong tag': original.replace('verbemo-v0.1.0', 'v0.1.0'),
                'tag and filename mismatch': original.replace('verbemo-v0.1.0', 'verbemo-v0.2.0'),
                'wrong platform asset': original.replace('windows-x64-Setup.exe', 'windows-arm64-Setup.exe'),
                'mixed release phase': original.replace(mac_url, 'https://github.com/ekho/verbemo/releases'),
                'one inconsistent duplicate': original.replace(mac_url, mac_url + '?download=1', 1),
            }
            for name, text in invalid.items():
                with self.subTest(case=name):
                    (site / 'ru/index.html').write_text(text)
                    self.assertNotEqual(gate()[0], 0, name)
            (site / 'ru/index.html').write_text(original)
            module.update_pages(site, downloads())
            self.assertEqual(gate()[0], 0, 'restoring both languages to Releases must pass')
