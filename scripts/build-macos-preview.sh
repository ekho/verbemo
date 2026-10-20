#!/usr/bin/env bash
# Ad-hoc distributable for manual installation; no stable update feed is produced.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION_ARG='' SOURCE_COMMIT='' OUTPUT=''
die() { printf 'macOS preview: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die 'expected --version, --source-commit and --output values'
    case "$1" in
        --version) VERSION_ARG=$2;;
        --source-commit) SOURCE_COMMIT=$2;;
        --output) OUTPUT=$2;;
        *) die "unknown argument: $1";;
    esac
    shift 2
done
[ -n "$VERSION_ARG" ] && [ -n "$SOURCE_COMMIT" ] && [ -n "$OUTPUT" ] \
    || die 'required: --version <VERSION> --source-commit <full SHA> --output <dir>'
BUILD=$(python3 scripts/release_manifest.py preflight --root "$ROOT" --version "$VERSION_ARG" \
    --source-commit "$SOURCE_COMMIT" --output "$OUTPUT" --prerelease)
[ "$(uname -s)" = Darwin ] || die 'requires macOS'
for tool in make swift codesign hdiutil ditto; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/verbemo-preview.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
VERBEMO_SPARKLE_PUBLIC_KEY='' make app VERSION="$VERSION_ARG" BUILD="$BUILD" SIGN_ID=- RELEASE_SIGNING=0
APP="$ROOT/.build/Verbemo.app"
codesign --verify --deep --strict "$APP"
DETAILS=$(codesign -dvv "$APP" 2>&1)
grep -q '^Signature=adhoc$' <<<"$DETAILS" || die 'expected ad-hoc app signature'
python3 - "$APP/Contents/Info.plist" "$VERSION_ARG" "$BUILD" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
if (info.get('CFBundleShortVersionString') != sys.argv[2] or info.get('CFBundleVersion') != sys.argv[3]
        or info.get('SUEnableAutomaticChecks') is not False or 'SUPublicEDKey' in info):
    sys.exit('Preview bundle identity or disabled updater validation failed')
PY
mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/Verbemo.app"
ln -s /Applications "$WORK/stage/Applications"
NAME="Verbemo-$VERSION_ARG-macos-universal.dmg"
hdiutil create -volname "Verbemo $VERSION_ARG Preview" -srcfolder "$WORK/stage" -format UDZO -quiet "$WORK/$NAME"
hdiutil verify "$WORK/$NAME" >/dev/null
python3 scripts/release_manifest.py receipt --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" \
    --build-number "$BUILD" --output "$WORK" --prerelease
python3 scripts/release_manifest.py validate-macos --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" \
    --build-number "$BUILD" --output "$WORK" --prerelease
python3 scripts/release_manifest.py preflight --root "$ROOT" --version "$VERSION_ARG" \
    --source-commit "$SOURCE_COMMIT" --output "$OUTPUT" --prerelease >/dev/null
python3 - "$WORK" "$OUTPUT" "$NAME" <<'PY'
from pathlib import Path
import shutil, sys
source, destination, dmg = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
destination.mkdir(parents=True, exist_ok=True)
created = []
try:
    for name in (dmg, 'macos-build.json'):
        with (destination / name).open('xb') as target:
            created.append(destination / name)
            with (source / name).open('rb') as stream:
                shutil.copyfileobj(stream, target)
except BaseException:
    for path in created:
        path.unlink()
    raise
PY
printf 'Prepared unsigned preview assets for Verbemo %s (build %s). Nothing published.\n' "$VERSION_ARG" "$BUILD"
