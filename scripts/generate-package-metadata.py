#!/usr/bin/env python3
"""Prepare catalog metadata from actual common release bytes; never publish."""
import argparse
import json
from pathlib import Path
import re

from release import prepared


def generate(artifacts, output, winget_id=None):
    artifacts, output = Path(artifacts).resolve(), Path(output).resolve()
    if output == artifacts or artifacts in output.parents or output.exists():
        raise ValueError('output must be a new directory outside release artifacts')
    if winget_id is not None and (len(winget_id) > 128 or not re.fullmatch(
            r'[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+', winget_id)):
        raise ValueError('WinGet needs an explicitly chosen Publisher.Package catalog identifier')
    data, records = prepared(artifacts)
    version = data['version']
    base = f'https://github.com/ekho/verbemo/releases/download/{data["tag"]}/'
    portable = f'Verbemo-{version}-windows-x64-Portable.zip'
    installer = f'Verbemo-{version}-windows-x64-Setup.exe'
    signature = json.loads((artifacts / 'windows-build.json').read_text())['signature']
    scoop = {'version': version, 'description': 'Local meeting recording, transcription and summaries.',
             'homepage': 'https://github.com/ekho/verbemo', 'license': 'MIT',
             'architecture': {'64bit': {'url': base + portable, 'hash': records[portable]['sha256']}},
             'shortcuts': [['Verbemo.exe', 'Verbemo']],
             'notes': ['Requires Windows 11 24H2 or later on x64.',
                       'Portable copies do not self-update. Quit before upgrading or uninstalling.']}
    files = {'verbemo.json': json.dumps(scoop, indent=2) + '\n'}
    if winget_id:
        # Publisher/locale/version manifests need separately reviewed real catalog metadata.
        files[f'{winget_id}.installer.yaml'] = f'''PackageIdentifier: {json.dumps(winget_id)}
PackageVersion: {json.dumps(version)}
InstallerType: exe
Scope: user
MinimumOSVersion: 10.0.26100.0
InstallModes:
- interactive
- silent
- silentWithProgress
InstallerSwitches:
  Silent: --silent
  SilentWithProgress: --silent
UpgradeBehavior: install
ProductCode: Verbemo
Installers:
- Architecture: x64
  InstallerUrl: {json.dumps(base + installer)}
  InstallerSha256: {json.dumps(records[installer]['sha256'].upper())}
ManifestType: installer
ManifestVersion: 1.12.0
'''
    evidence = {'version': version, 'source_commit': data['source_commit'], 'tag': data['tag'],
                'build_number': data['build_number'], 'manifest_sha256': records['release-manifest.json']['sha256'],
                'signature': signature, 'winget_identifier': winget_id, 'catalog_ready': False,
                'remaining': ['Verify public downloads and actual Windows install/upgrade/uninstall.',
                              'Review own certificate publisher and catalog metadata; complete WinGet locale/version manifests.',
                              'Obtain separate catalog publication approval.']}
    files['preparation-evidence.json'] = json.dumps(evidence, indent=2) + '\n'
    output.mkdir(parents=True)
    for name, content in files.items():
        (output / name).write_text(content)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--winget-id', help='Reviewed catalog identifier; no default publisher is invented')
    args = parser.parse_args()
    try:
        generate(args.artifacts, args.output, args.winget_id)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'packages: {error}\n')
