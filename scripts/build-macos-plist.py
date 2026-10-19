#!/usr/bin/env python3
"""Build bundle metadata; no release credentials are needed for local builds."""
import argparse
import os
from pathlib import Path
import plistlib
from release_manifest import FEED_URL, public_key, validate_version

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('template', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True, type=int)
args = parser.parse_args()
try:
    version = validate_version(args.version)
    if args.build < 1:
        raise ValueError('build must be positive')
    info = plistlib.loads(args.template.read_bytes())
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = str(args.build)
    info['SUFeedURL'] = FEED_URL
    info.pop('SUPublicEDKey', None)
    key = os.environ.get('VERBEMO_SPARKLE_PUBLIC_KEY', '')
    if key:
        public_key(key)
        info['SUPublicEDKey'] = key
    info['SUEnableAutomaticChecks'] = bool(key)
    args.output.write_bytes(plistlib.dumps(info))
except ValueError as error:
    parser.exit(1, f'bundle: {error}\n')
