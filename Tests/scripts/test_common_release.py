import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import release_manifest as manifest
import test_release_manifest


def fixture(root):
    (root / manifest.dmg_name('0.1.0')).write_bytes(b'final signed dmg')
    manifest.write_appcast(root, '0.1.0', 12, 'c' * 86 + '==', '14.2')
    manifest.write_macos_receipt(root, '0.1.0', 'a' * 40, 12)
    helper = test_release_manifest.WindowsManifestTests()
    helper.module = manifest
    helper.fixture(root)


class CommonValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fixture(self.root)

    def validate(self):
        return manifest.validate_release(self.root, '0.1.0', 'a' * 40, 12)

    def test_both_platforms_required(self):
        (self.root / 'windows-build.json').unlink()
        with self.assertRaises((ValueError, OSError)):
            self.validate()

    def test_same_version_commit_and_build_required(self):
        path = self.root / 'windows-build.json'
        original = json.loads(path.read_text())
        for field, value in [('version', '0.2.0'), ('source_commit', 'b' * 40), ('build_number', 13)]:
            data = dict(original, **{field: value})
            path.write_text(json.dumps(data))
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate()

    def test_feed_packages_must_exist(self):
        (self.root / 'Verbemo-0.1.0-stable-full.nupkg').unlink()
        with self.assertRaises(ValueError):
            self.validate()

    def test_extra_files_and_invalid_platform_signatures_rejected(self):
        (self.root / 'unexpected.exe').write_bytes(b'extra')
        with self.assertRaises(ValueError):
            self.validate()
        (self.root / 'unexpected.exe').unlink()
        path = self.root / 'windows-build.json'
        data = json.loads(path.read_text())
        data['signature']['timestamp'] = 'absent'
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            self.validate()

    def test_appcast_cannot_hide_another_channel_or_enclosure(self):
        import xml.etree.ElementTree as ET
        path = self.root / 'appcast.xml'
        tree = ET.parse(path)
        second = ET.SubElement(tree.getroot(), 'channel')
        ET.SubElement(ET.SubElement(second, 'item'), 'enclosure', url='https://elsewhere.invalid/package')
        tree.write(path)
        receipt_path = self.root / 'macos-build.json'
        receipt = json.loads(receipt_path.read_text())
        receipt['files'] = [manifest.file_record(self.root / item['name']) for item in receipt['files']]
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            self.validate()

    def test_one_shared_tag_and_strict_checksum(self):
        data = self.validate()
        self.assertEqual(data['tag'], 'verbemo-v0.1.0')
        self.assertEqual(len(data['files']), 9)
        self.assertEqual(len({x['name'] for x in data['files']}), 9)

import release
from unittest.mock import patch


class FakeGitHub:
    """Stateful fake API: bytes, publication and latest change separately."""
    def __init__(self):
        self.events = []
        self.items = []
        self.blobs = {}
        self.tags = {}
        self.latest_id = None
        self.break_public = False
        self.fail_upload = None
        self.on_public = None

    def require_repository(self):
        self.events.append(('repository',))

    def releases(self):
        self.events.append(('list',))
        return copy.deepcopy(self.items)

    def latest(self):
        return next((copy.deepcopy(r) for r in self.items if r['id'] == self.latest_id), None)

    def tag_commit(self, tag):
        return self.tags.get(tag)

    def assets(self, item):
        return [dict(id=n, name=n, state='uploaded', size=len(b),
                     browser_download_url=f'https://github.com/ekho/verbemo/releases/download/{item["tag_name"]}/{n}')
                for (rid, n), b in self.blobs.items() if rid == item['id']]

    def download(self, asset, public=False):
        self.events.append(('public' if public else 'download', asset['name']))
        if public and self.on_public:
            action, self.on_public = self.on_public, None
            action()
        if public and self.break_public:
            return b'HTML failure'
        return next(b for (rid, n), b in self.blobs.items() if n == asset['id'])

    def upload(self, item, name, content):
        self.events.append(('upload', name))
        self.blobs[item['id'], name] = content
        if name == self.fail_upload:
            self.fail_upload = None
            raise ValueError('ambiguous upload timeout')

    def api(self, path, method='GET', data=None):
        self.events.append((method, copy.deepcopy(data)))
        if method == 'POST':
            item = dict(data, id=len(self.items) + 1)
            self.items.append(item)
            self.tags[data['tag_name']] = data['target_commitish']
        elif method == 'PATCH':
            item = next(r for r in self.items if r['id'] == int(path.split('/')[-1]))
            item.update(data)
            if data.get('make_latest') == 'true':
                self.latest_id = item['id']
        else:
            raise AssertionError('unexpected API request')
        return copy.deepcopy(item)


class ReleaseStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fixture(self.root)
        self.api = FakeGitHub()

    def prepare(self):
        return release.prepare(self.root, '0.1.0', 'a' * 40, 12)

    def test_dry_run_has_no_writes(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        with patch.object(release, 'GitHub', side_effect=AssertionError('no network')):
            release.prepare(self.root, '0.1.0', 'a' * 40, 12, dry_run=True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.root.iterdir()})

    def test_latest_only_after_all_public_hash_checks(self):
        self.prepare()
        release.publish(self.root, self.api)
        events = self.api.events
        publish = next(i for i, e in enumerate(events) if e == ('PATCH', {'draft': False, 'make_latest': 'false'}))
        promotion = events.index(('PATCH', {'make_latest': 'true'}))
        public = [i for i, e in enumerate(events) if e[0] == 'public']
        self.assertEqual(len(public), 11)
        self.assertTrue(all(publish < i < promotion for i in public))
        self.assertEqual(len([e for e in events if e[0] == 'POST']), 1)
        self.assertEqual(self.api.latest_id, 1)

    def test_release_notes_are_attached_to_the_validated_draft(self):
        self.prepare()
        release.publish(self.root, self.api, notes='## 0.1.0\n\nFix audio preservation.\n')
        self.assertEqual(self.api.items[0]['body'], '## 0.1.0\n\nFix audio preservation.\n')

    def test_public_failure_preserves_latest_and_resume_only_verifies_promotes(self):
        self.prepare()
        self.api.break_public = True
        with self.assertRaisesRegex(ValueError, 'hash/size'):
            release.publish(self.root, self.api)
        self.assertIsNone(self.api.latest_id)
        self.assertFalse(self.api.items[0]['draft'])
        self.api.break_public = False
        self.api.events.clear()
        with patch.object(release.subprocess, 'run', side_effect=AssertionError('no build/git/sign')):
            release.resume('verbemo-v0.1.0', self.api)
        self.assertEqual([e for e in self.api.events if e[0] in ('POST', 'PATCH', 'upload')],
                         [('PATCH', {'make_latest': 'true'})])

    def test_ambiguous_draft_upload_reuses_equal_bytes_and_only_fills_missing(self):
        self.prepare()
        self.api.fail_upload = 'SHA256SUMS'
        with self.assertRaisesRegex(ValueError, 'timeout'):
            release.publish(self.root, self.api)
        self.api.events.clear()
        release.publish(self.root, self.api)
        self.assertNotIn(('upload', 'SHA256SUMS'), self.api.events)
        self.assertFalse(any(e[0] == 'POST' for e in self.api.events))

    def test_conflicting_existing_draft_never_overwrites(self):
        self.prepare()
        self.api.fail_upload = 'SHA256SUMS'
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.api.blobs[1, 'SHA256SUMS'] = b'conflict'
        self.api.events.clear()
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.assertFalse(any(e[0] in ('POST', 'PATCH', 'upload') for e in self.api.events))

    def test_newer_latest_never_rolls_back(self):
        data = self.prepare()
        release.publish(self.root, self.api)
        newer = dict(data, version='0.2.0', tag='verbemo-v0.2.0', build_number=13)
        other = dict(id=2, name='Verbemo 0.2.0', tag_name=newer['tag'], draft=False, prerelease=False)
        self.api.items.append(other)
        self.api.tags[newer['tag']] = newer['source_commit']
        self.api.blobs[2, release.MANIFEST] = json.dumps(newer).encode()
        # Bind downloads by complete URL to distinguish identical asset names.
        original = self.api.download
        def download(asset, public=False):
            if 'verbemo-v0.2.0' in asset['browser_download_url']:
                return self.api.blobs[2, release.MANIFEST]
            return original(asset, public)
        self.api.download = download
        self.api.latest_id = 2
        self.api.events.clear()
        with self.assertRaisesRegex(ValueError, 'rollback'):
            release.resume(data['tag'], self.api)
        self.assertEqual(self.api.latest_id, 2)
        self.assertFalse(any(e[0] in ('POST', 'PATCH', 'upload') for e in self.api.events))

    def test_draft_hash_failure_blocks_publication_and_existing_latest_stays(self):
        self.prepare()
        self.api.items = [dict(id=99, tag_name='v0.0.1', name='Imported release', draft=False, prerelease=False)]
        self.api.latest_id = 99
        original = self.api.upload
        def upload(item, name, content):
            original(item, name, content)
            if name == release.MANIFEST:
                self.api.blobs[item['id'], name] = b'corrupt uploaded bytes'
        self.api.upload = upload
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.assertEqual(self.api.latest_id, 99)
        self.assertTrue(self.api.items[-1]['draft'])
        self.assertFalse(any(e[0] == 'PATCH' for e in self.api.events))

    def test_latest_floor_is_rechecked_after_public_downloads(self):
        self.prepare()
        real_floor = release.floor
        calls = []
        def floor(api, data):
            calls.append(len([e for e in api.events if e[0] == 'public']))
            if calls[-1]:
                raise ValueError('newer release arrived during public checks')
            return real_floor(api, data)
        with patch.object(release, 'floor', side_effect=floor):
            with self.assertRaisesRegex(ValueError, 'newer release'):
                release.publish(self.root, self.api)
        self.assertEqual(calls, [0, 0, 11])
        self.assertIsNone(self.api.latest_id)
        self.assertFalse(self.api.items[0]['draft'])

    def test_tag_conflict_and_invalid_artifacts_prevent_draft(self):
        self.prepare()
        self.api.tags['verbemo-v0.1.0'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'tag commit'):
            release.publish(self.root, self.api)
        self.assertFalse(any(e[0] == 'POST' for e in self.api.events))
        (self.root / manifest.dmg_name('0.1.0')).write_bytes(b'tampered')
        self.api.events.clear()
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.assertEqual(self.api.events, [])

    def test_published_cannot_use_publish_or_reconstruct_missing_manifest(self):
        self.prepare()
        release.publish(self.root, self.api)
        self.api.events.clear()
        with self.assertRaisesRegex(ValueError, 'resume'):
            release.publish(self.root, self.api)
        del self.api.blobs[1, release.MANIFEST]
        with self.assertRaises(ValueError):
            release.resume('verbemo-v0.1.0', self.api)
        self.assertFalse(any(e[0] in ('POST', 'PATCH', 'upload') for e in self.api.events))

    def test_existing_draft_with_missing_tag_must_bind_commit(self):
        self.prepare()
        self.api.items = [dict(id=1, tag_name='verbemo-v0.1.0', name='Verbemo 0.1.0',
                               target_commitish='b' * 40, draft=True, prerelease=False)]
        with self.assertRaises(ValueError):
            release.publish(self.root, self.api)
        self.assertFalse(any(e[0] in ('POST', 'PATCH', 'upload') for e in self.api.events))

class TransportTests(unittest.TestCase):
    def test_repository_identity_accepts_app_metadata_without_user_permissions(self):
        from release_github import GitHub
        api = GitHub(token='fixture')
        api.api = lambda path: {'full_name': 'ekho/verbemo'}
        api.require_repository()

    def test_public_download_has_no_authorization_and_redirect_strips_token(self):
        from release_github import GitHub, SafeRedirect
        from urllib.request import Request
        requests = []
        class Response:
            headers = {}
            def read(self): return b'bytes'
            def __enter__(self): return self
            def __exit__(self, *args): pass
        class Opener:
            def open(self, req, timeout):
                requests.append(req)
                return Response()
        api = GitHub(token='fixture-secret', opener=Opener(), sleep=lambda _: None)
        asset = dict(id=1, browser_download_url='https://github.com/ekho/verbemo/releases/download/verbemo-v0.1.0/test')
        api.download(asset, public=True)
        self.assertIsNone(requests[-1].get_header('Authorization'))
        api.download(asset)
        self.assertEqual(requests[-1].get_header('Authorization'), 'Bearer fixture-secret')
        redirected = SafeRedirect().redirect_request(requests[-1], None, 302, 'Found', {}, 'https://cdn.invalid/file')
        self.assertIsNone(redirected.get_header('Authorization'))
        with self.assertRaises(ValueError):
            SafeRedirect().redirect_request(requests[-1], None, 302, 'Found', {}, 'http://cdn.invalid/file')
        with self.assertRaises(ValueError):
            api.request('https://api.github.com/repos/another/project/releases')

    def test_pagination_and_annotated_tags(self):
        from release_github import GitHub, BASE
        api = GitHub(token='fixture')
        pages = {BASE + '/releases?per_page=100': ([{'id': 1}], {'Link': '<' + BASE + '/releases?page=2>; rel="next"'}),
                 BASE + '/releases?page=2': ([{'id': 2}], {})}
        api.request = lambda url: pages[url]
        self.assertEqual(api.releases(), [{'id': 1}, {'id': 2}])
        objects = {'/git/ref/tags/verbemo-v0.1.0': {'object': {'sha': 'tag-sha', 'type': 'tag'}},
                   '/git/tags/tag-sha': {'object': {'sha': 'a' * 40, 'type': 'commit'}}}
        api.api = lambda path: objects[path]
        self.assertEqual(api.tag_commit('verbemo-v0.1.0'), 'a' * 40)

    def test_wrong_repository_rejected_before_mutation(self):
        from release_github import GitHub
        api = GitHub(token='fixture')
        api.api = lambda path: {'full_name': 'other/project', 'permissions': {'push': True}}
        with self.assertRaises(ValueError):
            api.require_repository()


class PreflightTests(unittest.TestCase):
    def test_full_clean_git_source_and_wrong_repository(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout.strip()
            git('init')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'user.name', 'Fixture')
            git('remote', 'add', 'origin', 'https://github.com/ekho/verbemo.git')
            (root / 'VERSION').write_text('0.1.0\n')
            git('add', 'VERSION')
            git('commit', '-m', 'fixture')
            actual = release.preflight(root, 'HEAD', '0.1.0')
            self.assertEqual(actual, dict(version='0.1.0', source_commit=git('rev-parse', 'HEAD'), build_number=1))
            git('remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
            with self.assertRaisesRegex(ValueError, 'origin'):
                release.preflight(root, 'HEAD', '0.1.0')


class PreparedBoundaryTests(unittest.TestCase):
    def test_symlink_metadata_cannot_escape_prepared_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'artifacts'
            root.mkdir()
            fixture(root)
            outside = Path(tmp) / 'outside'
            outside.write_text('keep')
            (root / release.CHECKSUMS).symlink_to(outside)
            with self.assertRaises(ValueError):
                release.prepare(root, '0.1.0', 'a' * 40, 12)
            self.assertEqual(outside.read_text(), 'keep')

    def test_dry_run_rejects_conflicting_existing_checksums(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            release.prepare(root, '0.1.0', 'a' * 40, 12)
            (root / release.CHECKSUMS).write_bytes(b'wrong')
            with self.assertRaises(ValueError):
                release.prepare(root, '0.1.0', 'a' * 40, 12, dry_run=True)


if __name__ == '__main__':
    unittest.main()
