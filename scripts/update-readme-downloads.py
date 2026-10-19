#!/usr/bin/env python3
"""Use own Releases until complete common release evidence is supplied."""
import argparse
from pathlib import Path
import re
import sys
from download_metadata import downloads, public_downloads

VERSION_BLOCK = re.compile(r'(<!-- public-download-versions:start -->\n).*?(\n<!-- public-download-versions:end -->)', re.S)


def updated_readme(source, evidence):
    version, links = evidence
    updated = source
    for platform, url in links.items():
        updated, count = re.subn(r'\[Download for ' + re.escape(platform) + r'\]\([^\s)]+\)',
                                 f'[Download for {platform}]({url})', updated)
        if count != 1:
            raise ValueError(f'Expected exactly one {platform} download link')
    if any(updated.count(f'<!-- public-download-versions:{marker} -->') != 1 for marker in ('start', 'end')):
        raise ValueError('Expected one download versions block')
    status = (f'Verified common artifact version: **{version}** for macOS and Windows.' if version else
              'No Verbemo installer release has been verified here yet. Check Releases for availability.')
    updated, count = VERSION_BLOCK.subn(lambda match: match[1] + status + match[2], updated)
    if count != 1:
        raise ValueError('Malformed download versions block')
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--readme', type=Path, default=Path('README.md'))
    evidence = parser.add_mutually_exclusive_group()
    evidence.add_argument('--artifacts', type=Path, help='Complete prepared common release directory; use after verified publication')
    evidence.add_argument('--public', action='store_true', help='Verify latest own public release, all bytes and source tag')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    source = args.readme.read_text()
    updated = updated_readme(source, public_downloads() if args.public else downloads(args.artifacts))
    if args.check and source != updated:
        raise ValueError('README downloads are stale for the supplied release evidence')
    if args.write and source != updated:
        args.readme.write_text(updated)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'downloads: {error}', file=sys.stderr)
        sys.exit(1)
