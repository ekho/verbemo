import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import download_metadata
import release
from test_common_release import FakeGitHub, fixture

class ReadOnlyGitHub(FakeGitHub):
    def api(self, path, method='GET', data=None):
        if path == '' and method == 'GET': return {'full_name': 'ekho/verbemo'}
        return super().api(path, method, data)

class PublicDownloadEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); fixture(self.root)
        release.prepare(self.root, '0.1.0', 'a' * 40, 12)
        self.api = ReadOnlyGitHub()
        release.publish(self.root, self.api)
        self.api.events.clear()

    def read(self):
        with patch.object(download_metadata, 'GitHub', return_value=self.api):
            result = download_metadata.public_downloads()
        self.assertFalse(any(event[0] in ('POST', 'PATCH', 'upload') for event in self.api.events))
        return result

    def test_public_evidence_is_complete_read_only_and_shared(self):
        version, urls = self.read()
        self.assertEqual(version, '0.1.0')
        self.assertIn('/verbemo-v0.1.0/Verbemo-0.1.0-windows-x64-Setup.exe', urls['Windows'])
        self.assertEqual(len([e for e in self.api.events if e[0] == 'public']), 11)

    def test_no_public_release_keeps_releases_page(self):
        self.api.latest_id = None
        self.assertEqual(self.read(), download_metadata.downloads())

    def test_wrong_source_missing_asset_and_corrupt_public_bytes_fail(self):
        self.api.tags['verbemo-v0.1.0'] = 'b' * 40
        with self.assertRaises(ValueError): self.read()
        self.api.tags['verbemo-v0.1.0'] = 'a' * 40
        self.api.break_public = True
        with self.assertRaises(ValueError): self.read()
        self.api.break_public = False
        del self.api.blobs[1, 'windows-build.json']
        with self.assertRaises(ValueError): self.read()

    def test_unsafe_remote_manifest_name_is_rejected_before_public_downloads(self):
        data = json.loads(self.api.blobs[1, 'release-manifest.json'])
        data['files'][0]['name'] = '../outside'
        self.api.blobs[1, 'release-manifest.json'] = json.dumps(data).encode()
        with self.assertRaises(ValueError): self.read()
        self.assertFalse(any(e[0] == 'public' for e in self.api.events))
