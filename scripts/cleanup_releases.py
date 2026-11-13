#!/usr/bin/env python3
"""Keep the ten newest published releases and latest; preserve drafts and Git tags."""
import argparse
from datetime import datetime
import json

from release_github import GitHub, REPOSITORY

KEEP = 10


def deletion_candidates(releases, latest):
    published = []
    ids = set()
    for item in releases:
        release_id = item['id']
        if type(release_id) is not int or release_id <= 0 or release_id in ids:
            raise ValueError('invalid or duplicate release ID')
        ids.add(release_id)
        if type(item['draft']) is not bool:
            raise ValueError('invalid release draft status')
        if item['draft']:
            continue
        if not isinstance(item['tag_name'], str) or not item['tag_name']:
            raise ValueError('missing release tag')
        date = datetime.fromisoformat(item['published_at'].replace('Z', '+00:00'))
        if date.tzinfo is None:
            raise ValueError('release publication time must include a timezone')
        published.append((date, release_id, {key: item[key] for key in ('id', 'tag_name', 'published_at')}))
    published.sort(key=lambda entry: entry[:2], reverse=True)
    latest_id = latest['id'] if latest is not None else None
    if latest is not None and (type(latest_id) is not int or
                              latest_id not in {entry[1] for entry in published}):
        raise ValueError('latest is absent from published releases; inspect GitHub state')
    return [item for _, release_id, item in published[KEEP:] if release_id != latest_id]


def cleanup(api, *, apply=False):
    api.require_repository()
    candidates = deletion_candidates(api.releases(), api.latest())
    print(json.dumps({'repository': REPOSITORY, 'mode': 'apply' if apply else 'dry-run',
                      'keep': KEEP, 'delete': candidates}, indent=2), flush=True)
    if apply:
        for item in candidates:
            # Recheck retention and latest before each irreversible deletion.
            if item not in deletion_candidates(api.releases(), api.latest()):
                raise ValueError('release retention changed; inspect GitHub state before retrying')
            api.api(f'/releases/{item["id"]}', 'DELETE')
            print(json.dumps({'deleted': item}), flush=True)
    return candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='delete releases and attached assets (default: dry-run)')
    args = parser.parse_args()
    try:
        cleanup(GitHub(), apply=args.apply)
    except (ValueError, OSError, KeyError, TypeError, AttributeError):
        parser.exit(1, 'release cleanup stopped; inspect GitHub state and the log before retrying\n')


if __name__ == '__main__':
    main()
