#!/usr/bin/env python3
"""Prepare or explicitly publish a single immutable Verbemo release."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

import release_manifest as manifest
from release_github import GitHub, REPOSITORY

MANIFEST = 'release-manifest.json'
CHECKSUMS = 'SHA256SUMS'


def prepare(directory, version, source_commit, build_number, dry_run=False):
    data = manifest.validate_release(directory, version, source_commit, build_number)
    content = (json.dumps(data, indent=2, sort_keys=True) + '\n').encode()
    names = [x['name'] for x in data['files']] + [MANIFEST]
    records = data['files'] + [{'name': MANIFEST, 'size': len(content),
                                'sha256': hashlib.sha256(content).hexdigest()}]
    expected = ''.join(f'{x["sha256"]}  {x["name"]}\n' for x in sorted(records, key=lambda x: x['name'])).encode()
    for name, wanted in ((MANIFEST, content), (CHECKSUMS, expected)):
        path = directory / name
        if path.exists() or path.is_symlink():
            manifest.file_record(path)  # Reject symlinks, directories and broken links.
            if path.read_bytes() != wanted:
                raise ValueError(f'existing {name} conflicts with validated artifacts')
    if not dry_run:
        (directory / MANIFEST).write_bytes(content)
        manifest.write_checksums(directory, names)
    return data


def prepared(directory):
    data = json.loads((directory / MANIFEST).read_bytes())
    checked = manifest.validate_release(directory, data['version'], data['source_commit'], data['build_number'])
    if data != checked:
        raise ValueError('manifest differs from validated platform receipts')
    expected = manifest.checksum_bytes(directory, [x['name'] for x in data['files']] + [MANIFEST])
    if (directory / CHECKSUMS).read_bytes() != expected:
        raise ValueError('SHA256SUMS differs from validated files')
    records = data['files'] + [manifest.file_record(directory / MANIFEST), manifest.file_record(directory / CHECKSUMS)]
    return data, {x['name']: x for x in records}


def identity(release, data):
    if (release.get('tag_name') != data['tag'] or release.get('name') != f'Verbemo {data["version"]}'
            or release.get('prerelease') is not False):
        raise ValueError('release identity mismatch')


def check_bytes(content, record):
    if len(content) != record['size'] or hashlib.sha256(content).hexdigest() != record['sha256']:
        raise ValueError('downloaded asset hash/size mismatch')


def asset_map(api, release):
    assets = api.assets(release)
    names = [a['name'] for a in assets]
    if len(set(names)) != len(names) or any(a.get('state') != 'uploaded' for a in assets):
        raise ValueError('duplicate or incomplete remote asset')
    return {a['name']: a for a in assets}


def verify_assets(api, release, records, public=False, allow_missing=False):
    assets = asset_map(api, release)
    if set(assets) - set(records) or (not allow_missing and set(assets) != set(records)):
        raise ValueError('remote asset set mismatch')
    for name, asset in assets.items():
        record = records[name]
        if asset.get('size') != record['size'] or asset.get('digest') not in (None, 'sha256:' + record['sha256']):
            raise ValueError('remote asset metadata mismatch')
        expected_url = f'https://github.com/{REPOSITORY}/releases/download/{release["tag_name"]}/{name}'
        if public and asset.get('browser_download_url') != expected_url:
            raise ValueError('unexpected public asset URL')
        check_bytes(api.download(asset, public=public), record)
    return assets


def remote_manifest(api, release):
    assets = asset_map(api, release)
    if MANIFEST not in assets:
        raise ValueError('stable Verbemo release has no manifest evidence')
    data = json.loads(api.download(assets[MANIFEST]))
    manifest.validate_version(data['version'])
    if (data.get('repository') != REPOSITORY or data.get('schema') != 1
            or data.get('tag') != f'verbemo-v{data["version"]}'
            or not re.fullmatch(r'[a-f0-9]{40}', data.get('source_commit', ''))
            or type(data.get('build_number')) is not int or data['build_number'] < 1):
        raise ValueError('invalid stable release identity evidence')
    identity(release, data)
    if api.tag_commit(data['tag']) != data['source_commit']:
        raise ValueError('stable release tag commit mismatch')
    return data


def floor(api, data):
    """Inspect every stable product release, not timestamps or API ordering."""
    releases = api.releases()
    latest = api.latest()
    if latest and all(r['id'] != latest['id'] for r in releases):
        releases.append(latest)
    target = tuple(map(int, data['version'].split('.')))
    for release in releases:
        if release['draft'] or release['prerelease'] or not release['tag_name'].startswith('verbemo-v'):
            continue
        other = remote_manifest(api, release)
        version = tuple(map(int, other['version'].split('.')))
        if version > target or (version != target and other['build_number'] >= data['build_number']):
            raise ValueError('newer stable version/build prevents latest rollback')
        if version == target and other != data:
            raise ValueError('same version has conflicting commit or artifacts')
    return latest


def check_tag(api, data, required=False):
    actual = api.tag_commit(data['tag'])
    if actual != data['source_commit'] and (required or actual is not None):
        raise ValueError('tag commit mismatch')


def promote(api, release, data, records):
    check_tag(api, data, required=True)
    verify_assets(api, release, records, public=True)
    latest = floor(api, data)  # Fresh check immediately before latest mutation.
    if not latest or latest['id'] != release['id']:
        api.api(f'/releases/{release["id"]}', 'PATCH', {'make_latest': 'true'})
    latest = api.latest()
    if not latest or latest['id'] != release['id']:
        raise ValueError('latest promotion not confirmed; inspect and resume')


def publish(directory, api):
    data, records = prepared(directory)  # No network until complete local validation.
    api.require_repository()
    floor(api, data)
    check_tag(api, data)
    matches = [r for r in api.releases() if r['tag_name'] == data['tag']]
    if len(matches) > 1:
        raise ValueError('multiple releases for this tag')
    if matches:
        release = matches[0]
        identity(release, data)
        if not release['draft']:
            raise ValueError('published releases require resume')
        if api.tag_commit(data['tag']) is None and release.get('target_commitish') != data['source_commit']:
            raise ValueError('existing draft has no matching tag or exact target commit')
    else:
        release = api.api('/releases', 'POST', {'tag_name': data['tag'],
            'target_commitish': data['source_commit'], 'name': f'Verbemo {data["version"]}',
            'draft': True, 'prerelease': False, 'make_latest': 'false'})
        identity(release, data)
    assets = verify_assets(api, release, records, allow_missing=True)
    for name in sorted(set(records) - set(assets)):
        # No clobber, retries, deletion or tag write. Ambiguous errors end this
        # invocation; rerun reads/validates remote bytes before another mutation.
        content = (directory / name).read_bytes()
        check_bytes(content, records[name])
        api.upload(release, name, content)
    verify_assets(api, release, records)
    floor(api, data)
    check_tag(api, data)
    release = api.api(f'/releases/{release["id"]}', 'PATCH', {'draft': False, 'make_latest': 'false'})
    identity(release, data)
    if release['draft']:
        raise ValueError('release publication not confirmed')
    promote(api, release, data, records)


def resume(tag, api):
    if not tag.startswith('verbemo-v'):
        raise ValueError('resume requires a Verbemo tag')
    manifest.validate_version(tag[len('verbemo-v'):])
    api.require_repository()
    matches = [r for r in api.releases() if r['tag_name'] == tag]
    if len(matches) != 1 or matches[0]['draft']:
        raise ValueError('resume requires exactly one published release')
    release = matches[0]
    data = remote_manifest(api, release)
    assets = asset_map(api, release)
    names = [x['name'] for x in data['files']] + [MANIFEST, CHECKSUMS]
    if (len(names) != len(set(names)) or set(names) != set(assets)
            or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', n) or '..' in n for n in names)):
        raise ValueError('invalid published asset set')
    with tempfile.TemporaryDirectory(prefix='verbemo-resume-') as tmp:
        directory = Path(tmp)
        for name in names:
            asset = assets[name]
            if asset.get('browser_download_url') != f'https://github.com/{REPOSITORY}/releases/download/{tag}/{name}':
                raise ValueError('unexpected public asset URL')
            (directory / name).write_bytes(api.download(asset, public=True))
        actual, records = prepared(directory)
        if actual != data:
            raise ValueError('public manifest differs from authenticated manifest')
        promote(api, release, data, records)


def preflight(root, ref, version):
    if not ref or ref.startswith('-') or any(c.isspace() for c in ref):
        raise ValueError('invalid source ref')
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}'],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError('source ref cannot be resolved')
    sha = result.stdout.strip()
    build = manifest.validate_source(root, version, sha)
    return {'source_commit': sha, 'build_number': build, 'version': version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    pre = commands.add_parser('preflight')
    pre.add_argument('--root', type=Path, default=Path.cwd())
    pre.add_argument('--ref', required=True)
    pre.add_argument('--version', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('--artifacts', type=Path, required=True)
    prep.add_argument('--version', required=True)
    prep.add_argument('--source-commit', required=True)
    prep.add_argument('--build-number', type=int, required=True)
    prep.add_argument('--dry-run', action='store_true')
    commands.add_parser('publish').add_argument('--artifacts', type=Path, required=True)
    commands.add_parser('resume').add_argument('--tag', required=True)
    args = parser.parse_args()
    try:
        if args.operation == 'preflight':
            print(json.dumps(preflight(args.root, args.ref, args.version)))
        elif args.operation == 'prepare':
            print(json.dumps(prepare(args.artifacts, args.version, args.source_commit, args.build_number, args.dry_run)))
        elif args.operation == 'publish':
            publish(args.artifacts, GitHub())
        else:
            resume(args.tag, GitHub())
    except (ValueError, OSError, KeyError, TypeError) as error:
        # Structural failures never print remote bodies or credential contents.
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else 'invalid or unavailable release evidence'
        parser.exit(1, f'release: {message}\n')


if __name__ == '__main__':
    main()
