import copy
from contextlib import redirect_stdout
from io import BytesIO, StringIO
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.response import addinfourl

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import cleanup_releases
from release_github import ApiError, BASE, GitHub


def release(number, **changes):
    item = dict(id=number, tag_name=f'verbemo-v0.1.{number}', draft=False,
                prerelease=number % 2 == 0, created_at='2026-01-01T00:00:00Z',
                published_at=f'2026-11-{number:02d}T00:00:00Z')
    item.update(changes)
    return item


class FakeGitHub:
    def __init__(self, releases, latest=None):
        self.items = copy.deepcopy(releases)
        self.latest_id = latest
        self.deleted = []

    def require_repository(self):
        pass

    def releases(self):
        return copy.deepcopy(self.items)

    def latest(self):
        return next((copy.deepcopy(r) for r in self.items if r['id'] == self.latest_id), None)

    def api(self, path, method='GET', data=None):
        if method != 'DELETE' or data is not None:
            raise AssertionError('only release deletion is allowed')
        item = next(r for r in self.items if path == f'/releases/{r["id"]}')
        self.deleted.append(item['id'])
        self.items.remove(item)


class CleanupTests(unittest.TestCase):
    def run_cleanup(self, api, apply=False):
        with redirect_stdout(StringIO()):
            return cleanup_releases.cleanup(api, apply=apply)

    def test_keeps_ten_newest_publications_across_stable_and_preview(self):
        api = FakeGitHub([release(n) for n in (3, 1, 11, 4, 8, 12, 5, 2, 6, 9, 7, 10)])
        self.run_cleanup(api, apply=True)
        self.assertEqual(set(api.deleted), {1, 2})
        self.assertEqual({r['id'] for r in api.items}, set(range(3, 13)))

    def test_latest_outside_the_ten_and_all_drafts_are_preserved(self):
        api = FakeGitHub([release(n) for n in range(1, 13)] +
                         [release(13, draft=True, published_at=None)], latest=1)
        self.run_cleanup(api, apply=True)
        self.assertEqual(api.deleted, [2])
        self.assertEqual({r['id'] for r in api.items}, {1, 13, *range(3, 13)})

    def test_empty_and_short_histories_do_not_delete_anything(self):
        for count in (0, 1, 10):
            with self.subTest(count=count):
                api = FakeGitHub([release(n) for n in range(1, count + 1)])
                self.assertEqual(self.run_cleanup(api, apply=True), [])
                self.assertEqual(api.deleted, [])

    def test_dry_run_lists_candidates_without_mutations(self):
        api = FakeGitHub([release(n) for n in range(1, 13)])
        before = copy.deepcopy(api.items)
        plan = self.run_cleanup(api)
        self.assertEqual({item['id'] for item in plan}, {1, 2})
        self.assertEqual(api.items, before)
        self.assertEqual(api.deleted, [])

    def test_publication_time_uses_timezones_and_ignores_creation_order(self):
        items = [release(n) for n in range(1, 13)]
        items[0].update(published_at='2026-11-01T01:00:00+02:00', created_at='2026-12-01T00:00:00Z')
        items[1]['published_at'] = '2026-11-01T00:30:00Z'
        items[2]['published_at'] = '2026-10-31T23:30:00Z'
        api = FakeGitHub(items)
        self.run_cleanup(api, apply=True)
        self.assertEqual(set(api.deleted), {1, 3})

    def test_equal_publication_times_have_a_stable_tiebreaker(self):
        api = FakeGitHub([release(n, published_at='2026-11-01T00:00:00Z') for n in range(1, 13)])
        self.run_cleanup(api, apply=True)
        self.assertEqual(set(api.deleted), {1, 2})

    def test_invalid_metadata_blocks_every_deletion(self):
        for changes in ({'published_at': None}, {'published_at': 'bad'},
                        {'published_at': '2026-11-01'}, {'draft': 'false'},
                        {'id': '../git/refs/tags/keep'}, {'id': True}, {'tag_name': ''}, {'id': 2}):
            with self.subTest(changes=changes):
                api = FakeGitHub([release(1, **changes)] + [release(n) for n in range(2, 13)])
                with self.assertRaises((ValueError, TypeError, AttributeError)):
                    self.run_cleanup(api, apply=True)
                self.assertEqual(api.deleted, [])

    def test_unlisted_latest_blocks_deletion(self):
        api = FakeGitHub([release(n) for n in range(1, 13)])
        for latest_id in (20, None, True, -1):
            with self.subTest(latest_id=latest_id), patch.object(api, 'latest', return_value={'id': latest_id}):
                with self.assertRaisesRegex(ValueError, 'latest'):
                    self.run_cleanup(api, apply=True)
            self.assertEqual(api.deleted, [])

    def test_rechecks_latest_before_each_delete(self):
        api = FakeGitHub([release(n) for n in range(1, 13)])
        with patch.object(api, 'latest', side_effect=[None, None, release(1)]):
            with self.assertRaisesRegex(ValueError, 'retention changed'):
                self.run_cleanup(api, apply=True)
        self.assertEqual(api.deleted, [2])
        self.assertIn(1, {r['id'] for r in api.items})

    def test_changed_publication_or_retained_set_stops_deletion(self):
        items = [release(n) for n in range(1, 13)]
        for change in ('republished', 'draft', 'removed-newest'):
            with self.subTest(change=change):
                fresh = copy.deepcopy(items)
                if change == 'republished':
                    fresh[1]['published_at'] = '2026-12-01T00:00:00Z'
                elif change == 'draft':
                    fresh[1]['draft'] = True
                else:
                    fresh = fresh[:10]
                api = FakeGitHub(items)
                with patch.object(api, 'releases', side_effect=[items, fresh]):
                    with self.assertRaisesRegex(ValueError, 'retention changed'):
                        self.run_cleanup(api, apply=True)
                self.assertEqual(api.deleted, [])

    def test_api_failures_stop_without_retry_or_further_deletions(self):
        for method in ('require_repository', 'releases', 'latest', 'api'):
            with self.subTest(method=method):
                api = FakeGitHub([release(n) for n in range(1, 13)])
                with patch.object(api, method, side_effect=ApiError(403)) as failing:
                    with self.assertRaises(ApiError):
                        self.run_cleanup(api, apply=True)
                    self.assertEqual(failing.call_count, 1)
                self.assertEqual(api.deleted, [])

    def test_paginated_api_no_stable_latest_and_empty_delete_responses(self):
        items = [release(n) for n in range(1, 13)]
        requests = []
        class Opener:
            def open(self, req, timeout):
                requests.append((req.method, req.full_url))
                headers, status = {}, 200
                if req.full_url == BASE:
                    data = {'full_name': 'ekho/verbemo'}
                elif req.full_url == BASE + '/releases?per_page=100':
                    data = items[:6]
                    headers['Link'] = f'<{BASE}/releases?page=2>; rel="next"'
                elif req.full_url == BASE + '/releases?page=2':
                    data = items[6:]
                elif req.full_url == BASE + '/releases/latest':
                    raise HTTPError(req.full_url, 404, 'Not Found', {}, None)
                elif req.method == 'DELETE':
                    item = next(r for r in items if req.full_url == BASE + f'/releases/{r["id"]}')
                    items.remove(item)
                    data, status = None, 204
                else:
                    raise AssertionError('unexpected API endpoint')
                body = b'' if status == 204 else json.dumps(data).encode()
                return addinfourl(BytesIO(body), headers, req.full_url, code=status)
        api = GitHub(token='fixture', opener=Opener(), sleep=lambda _: None)
        self.run_cleanup(api, apply=True)
        self.assertEqual({r['id'] for r in items}, set(range(3, 13)))
        self.assertEqual([request for request in requests if request[0] != 'GET'],
                         [('DELETE', BASE + '/releases/2'), ('DELETE', BASE + '/releases/1')])


if __name__ == '__main__':
    unittest.main()
