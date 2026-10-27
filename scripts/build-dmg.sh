#!/usr/bin/env bash
# Layout only: callers own app signing, notarization and final artifact receipts.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { printf 'DMG: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || die 'usage: build-dmg.sh <app> <volume-name> <output.dmg>'
APP=$1 VOLUME=$2 OUTPUT=$3
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die "output already exists: $OUTPUT"
[ -d "$APP/Contents" ] || die "app bundle is missing: $APP"
[ "$(uname -s)" = Darwin ] || die 'requires macOS'
python3 -c 'import dmgbuild' 2>/dev/null \
    || die 'install build tools: python3 -m pip install --require-hashes -r Packaging/dmg/requirements.txt'
codesign --verify --deep --strict "$APP"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/verbemo-dmg.XXXXXX")
MOUNT=''
cleanup() {
    if [ -n "$MOUNT" ]; then
        hdiutil detach -quiet "$MOUNT" || return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
swift "$ROOT/Packaging/dmg/background.swift" "$WORK/background.tiff"
python3 -m dmgbuild -s "$ROOT/Packaging/dmg/settings.py" \
    -D "app=$APP" -D "icon=$ROOT/Resources/Verbemo.icns" \
    -D "background=$WORK/background.tiff" "$VOLUME" "$WORK/image.dmg"
hdiutil verify "$WORK/image.dmg" >/dev/null
# dmgbuild's ditto invocation does not check its exit status; verify the payload.
mkdir "$WORK/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$WORK/mounted" "$WORK/image.dmg" >/dev/null
MOUNT="$WORK/mounted"
codesign --verify --deep --strict "$MOUNT/Verbemo.app"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || die 'Applications link is missing'
for file in .DS_Store .background.tiff .VolumeIcon.icns; do
    [ -s "$MOUNT/$file" ] || die "missing layout resource: $file"
done
hdiutil detach -quiet "$MOUNT"
MOUNT=''
# Exclusive creation preserves an existing artifact even if another writer raced us.
python3 - "$WORK/image.dmg" "$OUTPUT" <<'PY'
from pathlib import Path
import shutil
import sys
source, destination = map(Path, sys.argv[1:])
created = False
try:
    with destination.open('xb') as target:
        created = True
        with source.open('rb') as stream:
            shutil.copyfileobj(stream, target)
except BaseException:
    if created:
        destination.unlink()
    raise
PY
