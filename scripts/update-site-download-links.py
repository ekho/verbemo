#!/usr/bin/env python3
"""Update the marked platform links on both static pages; never publish."""
import argparse
from pathlib import Path
import re
from download_metadata import downloads, public_downloads


def update_pages(site, evidence):
    _, links = evidence
    pending = []
    for relative in ('index.html', 'ru/index.html'):
        path = site / relative
        text = path.read_text()
        for platform, url in links.items():
            text, count = re.subn(r'(data-download="' + platform + r'" href=")[^"]+',
                                  lambda match: match[1] + url, text)
            if count != 2:
                raise ValueError(f'{relative}: expected exactly two {platform} links')
        pending.append((path, text))
    for path, text in pending:
        path.write_text(text)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('site', type=Path)
    evidence = parser.add_mutually_exclusive_group()
    evidence.add_argument('--artifacts', type=Path)
    evidence.add_argument('--public', action='store_true')
    args = parser.parse_args()
    try:
        update_pages(args.site, public_downloads() if args.public else downloads(args.artifacts))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'downloads: {error}\n')
