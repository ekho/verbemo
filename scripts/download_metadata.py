"""Download metadata from complete, validated common release evidence."""
from pathlib import Path
import re
import tempfile

from release import prepared, remote_manifest, asset_map
from release_github import GitHub

RELEASES = 'https://github.com/ekho/verbemo/releases'


def downloads(artifacts=None):
    if artifacts is None:
        return None, {'macOS': RELEASES, 'Windows': RELEASES}
    data, _ = prepared(Path(artifacts))
    if data.get('prerelease', False):
        raise ValueError('stable download links require a signed release')
    return _links(data)


def _links(data):
    base = RELEASES + '/download/' + data['tag'] + '/'
    version = data['version']
    return version, {'macOS': base + f'Verbemo-{version}-macos-universal.dmg',
                     'Windows': base + f'Verbemo-{version}-windows-x64-Setup.exe'}


def public_downloads():
    """Read only: verify all public bytes and the exact source tag before linking."""
    api = GitHub()
    if api.api('').get('full_name') != 'ekho/verbemo':
        raise ValueError('unexpected repository')
    latest = api.latest()
    if latest is None:
        return downloads()
    if latest.get('draft') or latest.get('prerelease'):
        raise ValueError('latest release must be public and stable')
    data = remote_manifest(api, latest)
    # Manifest names are untrusted until the complete set has been validated.
    names = [item['name'] for item in data['files']] + ['release-manifest.json', 'SHA256SUMS']
    if len(names) != len(set(names)) or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name)
                                          or '..' in name for name in names):
        raise ValueError('unsafe release asset names')
    assets = asset_map(api, latest)
    if set(assets) != set(names):
        raise ValueError('public asset set mismatch')
    with tempfile.TemporaryDirectory(prefix='verbemo-downloads-') as tmp:
        directory = Path(tmp)
        for name in names:
            if assets[name].get('browser_download_url') != RELEASES + '/download/' + data['tag'] + '/' + name:
                raise ValueError('unexpected public asset URL')
            (directory / name).write_bytes(api.download(assets[name], public=True))
        checked, records = prepared(directory)
        if checked != data:
            raise ValueError('public manifest differs from authenticated evidence')
        for name, asset in assets.items():
            record = records[name]
            if asset.get('size') != record['size'] or asset.get('digest') not in (None, 'sha256:' + record['sha256']):
                raise ValueError('public asset metadata mismatch')
        return _links(checked)
