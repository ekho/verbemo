import json
import importlib.util
from pathlib import Path
import tempfile
import unittest

from test_common_release import FakeGitHub
import test_release_manifest
import release
import release_manifest as manifest
import download_metadata


def preview_fixture(root):
    (root / manifest.dmg_name('0.1.0')).write_bytes(b'ad-hoc app disk image')
    manifest.write_macos_receipt(root, '0.1.0', 'a' * 40, 12, prerelease=True)
    helper = test_release_manifest.WindowsManifestTests()
    helper.module = manifest
    receipt = helper.fixture(root)
    receipt['publishable'] = False
    receipt['signature'] = {'authenticode': 'unsigned-development', 'timestamp': 'unverified',
                            'certificate_thumbprint': None}
    (root / 'windows-build.json').write_text(json.dumps(receipt))


class PreviewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        preview_fixture(self.root)
        self.api = FakeGitHub()

    def prepare(self):
        return release.prepare(self.root, '0.1.0', 'a' * 40, 12, prerelease=True)

    def test_unsigned_receipts_require_explicit_prerelease_preparation(self):
        with self.assertRaises(ValueError):
            release.prepare(self.root, '0.1.0', 'a' * 40, 12)
        data = self.prepare()
        self.assertIs(data['prerelease'], True)
        self.assertEqual(data['tag'], 'verbemo-v0.1.0')
        self.assertNotIn('appcast.xml', [record['name'] for record in data['files']])
        self.assertEqual(len(data['files']), 8)

    def test_prerelease_never_promotes_latest_and_has_an_explicit_unsigned_notice(self):
        self.prepare()
        release.publish(self.root, self.api, notes='Feature notes.')
        published = self.api.items[0]
        self.assertIs(published['prerelease'], True)
        self.assertFalse(published['draft'])
        self.assertEqual(published['make_latest'], 'false')
        self.assertIn('unsigned', published['body'].lower())
        self.assertIn('Feature notes.', published['body'])
        self.assertIsNone(self.api.latest_id)
        self.assertNotIn(('PATCH', {'make_latest': 'true'}), self.api.events)
        self.assertEqual(len([event for event in self.api.events if event[0] == 'public']), 10)

    def test_resuming_a_published_prerelease_only_verifies_bytes(self):
        self.prepare()
        release.publish(self.root, self.api)
        self.api.events.clear()
        release.resume('verbemo-v0.1.0', self.api)
        self.assertFalse(any(event[0] in ('POST', 'PATCH', 'upload') for event in self.api.events))
        self.assertIsNone(self.api.latest_id)

    def test_latest_promotion_itself_refuses_prerelease_evidence(self):
        data = self.prepare()
        release.publish(self.root, self.api)
        self.api.events.clear()
        _, records = release.prepared(self.root)
        with self.assertRaisesRegex(ValueError, 'prerelease'):
            release.promote(self.api, self.api.items[0], data, records)
        self.assertEqual(self.api.events, [])

    def test_a_partial_draft_reuses_matching_original_artifacts(self):
        self.prepare()
        self.api.fail_upload = 'SHA256SUMS'
        with self.assertRaisesRegex(ValueError, 'timeout'):
            release.publish(self.root, self.api)
        self.api.events.clear()
        release.publish(self.root, self.api)
        self.assertNotIn(('upload', 'SHA256SUMS'), self.api.events)
        self.assertFalse(any(event[0] == 'POST' for event in self.api.events))
        self.assertIsNone(self.api.latest_id)

    def test_manifest_flag_cannot_disguise_unsigned_artifacts_as_stable(self):
        self.prepare()
        path = self.root / release.MANIFEST
        data = json.loads(path.read_text())
        del data['prerelease']
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.assertEqual(self.api.events, [])

    def test_stable_appcast_is_not_accepted_in_a_prerelease_set(self):
        (self.root / 'appcast.xml').write_text('<rss/>')
        with self.assertRaisesRegex(ValueError, 'unexpected release files'):
            self.prepare()

    def test_both_platforms_and_exact_bytes_are_still_required(self):
        for mutation in ('missing', 'hash', 'source', 'build'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                preview_fixture(root)
                if mutation == 'missing':
                    (root / 'windows-build.json').unlink()
                elif mutation == 'hash':
                    (root / manifest.dmg_name('0.1.0')).write_bytes(b'changed')
                else:
                    path = root / 'windows-build.json'
                    data = json.loads(path.read_text())
                    data['source_commit' if mutation == 'source' else 'build_number'] = 'b' * 40 if mutation == 'source' else 13
                    path.write_text(json.dumps(data))
                with self.assertRaises((ValueError, OSError)):
                    release.prepare(root, '0.1.0', 'a' * 40, 12, prerelease=True)

    def test_invalid_signature_metadata_is_not_accepted_as_unsigned(self):
        for platform in ('macos', 'windows'):
            path = self.root / f'{platform}-build.json'
            original = path.read_text()
            data = json.loads(original)
            data['signature'] = {}
            path.write_text(json.dumps(data))
            with self.subTest(platform=platform), self.assertRaises(ValueError):
                self.prepare()
            path.write_text(original)

    def test_preview_cannot_supply_stable_readme_or_site_download_links(self):
        self.prepare()
        with self.assertRaisesRegex(ValueError, 'stable'):
            download_metadata.downloads(self.root)

    def test_preview_cannot_supply_package_catalog_metadata(self):
        self.prepare()
        script = Path(__file__).resolve().parents[2] / 'scripts/generate-package-metadata.py'
        spec = importlib.util.spec_from_file_location('preview_catalog', script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'catalog'
            with self.assertRaisesRegex(ValueError, 'stable'):
                module.generate(self.root, output)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
