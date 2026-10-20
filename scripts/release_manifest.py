#!/usr/bin/env python3
"""Release metadata and validation. Python standard library only; never publishes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

FEED_URL = 'https://github.com/ekho/verbemo/releases/latest/download/appcast.xml'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def validate_version(version: str) -> str:
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('VERSION must be stable three-component SemVer')
    return version


def validate_source(root: Path, version: str, source_commit: str) -> int:
    validate_version(version)
    def git(*args):
        result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)
        if result.returncode:
            raise ValueError('cannot inspect release source commit or repository')
        return result.stdout.strip()
    if git('remote', 'get-url', 'origin') not in (
        'git@github.com:ekho/verbemo.git', 'https://github.com/ekho/verbemo.git',
        'https://github.com/ekho/verbemo', 'ssh://git@github.com/ekho/verbemo.git'):
        raise ValueError('origin must be ekho/verbemo')
    if git('rev-parse', '--is-shallow-repository') != 'false':
        raise ValueError('shallow history cannot produce a release build number')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('working tree is dirty')
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit) or git('rev-parse', 'HEAD') != source_commit:
        raise ValueError('source commit must be the full current HEAD SHA')
    if (root / 'VERSION').read_text().strip() != version or git('show', f'{source_commit}:VERSION') != version:
        raise ValueError('VERSION does not match release version')
    return int(git('rev-list', '--count', source_commit))


def public_key(value: str) -> bytes:
    try:
        key = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError('invalid VERBEMO_SPARKLE_PUBLIC_KEY') from error
    if len(key) != 32:
        raise ValueError('invalid VERBEMO_SPARKLE_PUBLIC_KEY length')
    return key


def validate_credentials(env) -> None:
    required = ('VERBEMO_SIGN_ID', 'VERBEMO_SPARKLE_PUBLIC_KEY', 'VERBEMO_SPARKLE_PRIVATE_KEY_FILE',
                'VERBEMO_NOTARY_KEY_FILE', 'VERBEMO_NOTARY_KEY_ID', 'VERBEMO_NOTARY_ISSUER_ID')
    for name in required:
        if not env.get(name):
            raise ValueError(f'missing {name}; signed releases require your own credentials')
    if not env['VERBEMO_SIGN_ID'].startswith('Developer ID Application: '):
        raise ValueError('VERBEMO_SIGN_ID must explicitly name a Developer ID Application identity')
    public_key(env['VERBEMO_SPARKLE_PUBLIC_KEY'])
    for name in ('VERBEMO_SPARKLE_PRIVATE_KEY_FILE', 'VERBEMO_NOTARY_KEY_FILE'):
        if not Path(env[name]).is_file() or not os.access(env[name], os.R_OK):
            raise ValueError(f'{name} must name a readable private key file')
    try:
        secret = base64.b64decode(Path(env['VERBEMO_SPARKLE_PRIVATE_KEY_FILE']).read_text().strip(), validate=True)
    except (ValueError, OSError, UnicodeError) as error:
        raise ValueError('invalid Sparkle private key file') from error
    if len(secret) not in (32, 96):
        raise ValueError('Sparkle private key must be a 32-byte seed or 96-byte legacy key')
    if len(secret) == 96 and secret[64:] != public_key(env['VERBEMO_SPARKLE_PUBLIC_KEY']):
        raise ValueError('Sparkle public/private key mismatch')


def file_record(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'missing or unsafe release file: {path.name}')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return {'name': path.name, 'sha256': digest.hexdigest(), 'size': path.stat().st_size}


def dmg_name(version):
    return f'Verbemo-{validate_version(version)}-macos-universal.dmg'


def write_appcast(directory: Path, version: str, build_number: int, signature: str, minimum: str) -> Path:
    dmg = directory / dmg_name(version)
    if build_number < 1 or len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('invalid build number or DMG signature')
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Verbemo'
    ET.SubElement(channel, 'link').text = FEED_URL
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Verbemo {version}'
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = minimum
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/ekho/verbemo/releases/download/verbemo-v{version}/{dmg.name}',
        f'{{{SPARKLE}}}version': str(build_number), f'{{{SPARKLE}}}shortVersionString': version,
        f'{{{SPARKLE}}}edSignature': signature, 'length': str(dmg.stat().st_size),
        'type': 'application/octet-stream'})
    target = directory / 'appcast.xml'
    with target.open('xb') as stream:
        ET.ElementTree(rss).write(stream, encoding='utf-8', xml_declaration=True)
    return target


def write_macos_receipt(directory: Path, version: str, source_commit: str, build_number: int, prerelease=False) -> Path:
    signature = ({'code_signing': 'ad-hoc', 'notarization': 'not-performed', 'sparkle': 'disabled'} if prerelease else
                 {'developer_id': 'verified', 'notarization': 'accepted', 'staple': 'verified',
                  'gatekeeper': 'accepted', 'sparkle_dmg': 'verified', 'sparkle_appcast': 'verified'})
    names = (dmg_name(version),) if prerelease else (dmg_name(version), 'appcast.xml')
    receipt = {'platform': 'macos', 'version': version, 'source_commit': source_commit,
               'build_number': build_number, 'signature': signature,
               'files': [file_record(directory / name) for name in names]}
    path = directory / 'macos-build.json'
    with path.open('x') as stream:
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    return path


def validate_macos_release(directory: Path, version: str, source_commit: str, build_number: int, prerelease=False) -> dict:
    """Validate the standalone macOS receipt and feed."""
    validate_version(version)
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit) or type(build_number) is not int or build_number < 1:
        raise ValueError('invalid source commit or build number')
    receipt = json.loads((directory / 'macos-build.json').read_text())
    for key, value in {'platform': 'macos', 'version': version, 'source_commit': source_commit,
                       'build_number': build_number}.items():
        if receipt.get(key) != value:
            raise ValueError(f'macOS receipt {key} mismatch')
    expected = {dmg_name(version)} if prerelease else {dmg_name(version), 'appcast.xml'}
    files = receipt.get('files', [])
    if len(files) != len(expected) or {item.get('name') for item in files} != expected:
        raise ValueError('macOS receipt files mismatch')
    for item in files:
        if file_record(directory / item['name']) != item:
            raise ValueError(f'release file hash/size mismatch: {item["name"]}')
    required = ({'code_signing': 'ad-hoc', 'notarization': 'not-performed', 'sparkle': 'disabled'} if prerelease else
                {'developer_id': 'verified', 'notarization': 'accepted', 'staple': 'verified',
                 'gatekeeper': 'accepted', 'sparkle_dmg': 'verified', 'sparkle_appcast': 'verified'})
    if receipt.get('signature') != required:
        raise ValueError('macOS signature validation missing')
    if prerelease:
        return receipt
    rss = ET.parse(directory / 'appcast.xml').getroot()
    channel = rss.find('channel')
    if (rss.tag != 'rss' or len(rss.findall('channel')) != 1 or len(rss.findall('.//enclosure')) != 1
            or channel is None or channel.findtext('link') != FEED_URL or len(channel.findall('item')) != 1):
        raise ValueError('appcast channel mismatch')
    enclosure = channel.find('item/enclosure')
    if enclosure is None or len(channel.findall('.//enclosure')) != 1:
        raise ValueError('appcast enclosure missing')
    for key, value in {'url': f'https://github.com/ekho/verbemo/releases/download/verbemo-v{version}/{dmg_name(version)}',
                       f'{{{SPARKLE}}}version': str(build_number),
                       f'{{{SPARKLE}}}shortVersionString': version,
                       'length': str((directory / dmg_name(version)).stat().st_size)}.items():
        if enclosure.get(key) != value:
            raise ValueError(f'appcast {key} mismatch')
    try:
        signature = base64.b64decode(enclosure.get(f'{{{SPARKLE}}}edSignature', ''), validate=True)
    except ValueError as error:
        raise ValueError('invalid appcast DMG signature') from error
    if len(signature) != 64:
        raise ValueError('invalid appcast DMG signature')
    return receipt


def validate_windows_release(directory: Path, version: str, source_commit: str, build_number: int, prerelease=False) -> dict:
    """Validate the Windows receipt without weakening the macOS-only API."""
    validate_version(version)
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit) or type(build_number) is not int or build_number < 1:
        raise ValueError('invalid source commit or build number')
    receipt = json.loads((directory / 'windows-build.json').read_text())
    for key, value in {'platform': 'windows', 'version': version, 'source_commit': source_commit,
                       'build_number': build_number, 'publishable': not prerelease}.items():
        if receipt.get(key) != value:
            raise ValueError(f'Windows receipt {key} mismatch')
    signature = receipt.get('signature', {})
    if prerelease:
        if signature != {'authenticode': 'unsigned-development', 'timestamp': 'unverified', 'certificate_thumbprint': None}:
            raise ValueError('Windows unsigned receipt validation missing')
    elif (signature.get('authenticode') != 'verified' or signature.get('timestamp') != 'verified'
          or not re.fullmatch(r'[A-F0-9]{40}', signature.get('certificate_thumbprint', ''))):
        raise ValueError('Windows signature validation missing')
    installer = f'Verbemo-{version}-windows-x64-Setup.exe'
    portable = f'Verbemo-{version}-windows-x64-Portable.zip'
    package = f'Verbemo-{version}-stable-full.nupkg'
    expected = {installer, portable, package, 'assets.stable.json', 'releases.stable.json'}
    files = receipt.get('files', [])
    if len(files) != len(expected) or {item.get('name') for item in files} != expected:
        raise ValueError('Windows receipt files mismatch')
    for item in files:
        if file_record(directory / item['name']) != item:
            raise ValueError(f'release file hash/size mismatch: {item["name"]}')
    inventory = json.loads((directory / 'assets.stable.json').read_text())
    if (not isinstance(inventory, list) or len(inventory) != 3 or
            {(item.get('RelativeFileName'), item.get('Type')) for item in inventory} !=
            {(installer, 'Installer'), (portable, 'Portable'), (package, 'Full')}):
        raise ValueError('Windows inventory mismatch')
    feed = json.loads((directory / 'releases.stable.json').read_text())
    assets = feed.get('Assets', [])
    if len(assets) != 1:
        raise ValueError('Windows feed must contain only the current full package')
    asset = assets[0]
    package_record = file_record(directory / package)
    for key, value in {'PackageId': 'Verbemo', 'Version': version, 'Type': 'Full',
                       'FileName': package, 'SHA256': package_record['sha256'].upper(),
                       'Size': package_record['size']}.items():
        actual = asset.get(key)
        if key == 'SHA256' and isinstance(actual, str):
            actual = actual.upper()
        if actual != value:
            raise ValueError(f'Windows feed {key} mismatch')
    return receipt


def validate_release(directory: Path, version: str, source_commit: str, build_number: int, prerelease=False, macos_only=False) -> dict:
    """The common set is closed: no unvalidated sidecars or extra platforms."""
    if type(prerelease) is not bool:
        raise ValueError('prerelease must be a boolean')
    if type(macos_only) is not bool:
        raise ValueError('macos_only must be a boolean')
    if macos_only and not prerelease:
        raise ValueError('macOS-only releases require prerelease mode')
    receipts = [validate_macos_release(directory, version, source_commit, build_number, prerelease)]
    if not macos_only:
        receipts.append(validate_windows_release(directory, version, source_commit, build_number, prerelease))
    names = [item['name'] for receipt in receipts for item in receipt['files']]
    names += [f'{receipt["platform"]}-build.json' for receipt in receipts]
    if len(names) != len(set(names)):
        raise ValueError('duplicate release filename')
    if {p.name for p in directory.iterdir()} - set(names) - {'release-manifest.json', 'SHA256SUMS'}:
        raise ValueError('unexpected release files')
    result = {'schema': 1, 'repository': 'ekho/verbemo', 'tag': f'verbemo-v{version}',
            'version': version, 'source_commit': source_commit, 'build_number': build_number,
            'files': [file_record(directory / name) for name in sorted(names)]}
    if prerelease:
        result['prerelease'] = True
    if macos_only:
        result['platforms'] = ['macos']
    return result


def checksum_bytes(directory: Path, names) -> bytes:
    names = list(names)
    if len(names) != len(set(names)) or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', n)
                                          or '..' in n or n == 'SHA256SUMS' for n in names):
        raise ValueError('unsafe or duplicate checksum filename')
    return ''.join(f'{file_record(directory / name)["sha256"]}  {name}\n'
                   for name in sorted(names)).encode()


def write_checksums(directory: Path, names) -> Path:
    target = directory / 'SHA256SUMS'
    target.write_bytes(checksum_bytes(directory, names))
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('preflight', 'appcast', 'receipt', 'validate', 'validate-macos'))
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--version', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-number', type=int)
    parser.add_argument('--signature')
    parser.add_argument('--minimum', default='14.2')
    parser.add_argument('--prerelease', action='store_true')
    parser.add_argument('--macos-only', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'preflight':
            build = validate_source(args.root, args.version, args.source_commit)
            for name in (dmg_name(args.version), 'appcast.xml', 'macos-build.json'):
                if (args.output / name).exists():
                    raise ValueError(f'release output already exists: {name}')
            if not args.prerelease:
                validate_credentials(os.environ)
            print(build)
        elif args.command == 'appcast':
            write_appcast(args.output, args.version, args.build_number, args.signature, args.minimum)
        elif args.command == 'receipt':
            write_macos_receipt(args.output, args.version, args.source_commit, args.build_number, args.prerelease)
        elif args.command == 'validate-macos':
            validate_macos_release(args.output, args.version, args.source_commit, args.build_number, args.prerelease)
        else:
            validate_release(args.output, args.version, args.source_commit, args.build_number, args.prerelease, args.macos_only)
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f'release: {error}\n')


if __name__ == '__main__':
    main()
