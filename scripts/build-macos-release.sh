#!/usr/bin/env bash
# Build one platform's immutable assets. Publication belongs to the common publisher.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION_ARG= SOURCE_COMMIT= OUTPUT=
die() { printf 'macOS release: %s\n' "$*" >&2; exit 1; }
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
# No builds, network access, output directories or Keychain access before this passes.
BUILD=$(python3 scripts/release_manifest.py preflight --root "$ROOT" \
    --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" --output "$OUTPUT")
[ "$(uname -s)" = Darwin ] || die 'requires macOS'
for tool in swift xcrun codesign security hdiutil spctl make; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
IDENTITIES=$(security find-identity -v -p codesigning)
grep -Fq "\"$VERBEMO_SIGN_ID\"" <<<"$IDENTITIES" || die 'configured Developer ID identity is unavailable'
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    swift package resolve
fi
[ -x "$SPARKLE_BIN/sign_update" ] || die 'Sparkle sign_update is unavailable after dependency resolution'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/verbemo-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
printf 'Verbemo release signing preflight\n' > "$WORK/challenge"
# Sparkle diagnostics may include malformed private data; never forward that output.
SIGNATURE=$("$SPARKLE_BIN/sign_update" -p --ed-key-file "$VERBEMO_SPARKLE_PRIVATE_KEY_FILE" \
    "$WORK/challenge" 2>"$WORK/sign-error") || die 'Sparkle signing-key validation failed'
swift scripts/verify-sparkle-signature.swift "$WORK/challenge" "$SIGNATURE"
make app VERSION="$VERSION_ARG" BUILD="$BUILD" SIGN_ID="$VERBEMO_SIGN_ID" RELEASE_SIGNING=1
APP="$ROOT/.build/Verbemo.app"
codesign --verify --deep --strict "$APP"
DETAILS=$(codesign -dvvv "$APP" 2>&1)
REQUIREMENT=$(codesign -d -r- "$APP" 2>&1)
grep -q '^Authority=Developer ID Application:' <<<"$DETAILS" || die 'Developer ID signature missing'
grep -q 'flags=.*runtime' <<<"$DETAILS" || die 'hardened runtime missing'
grep -q 'name.ekho.verbemo' <<<"$REQUIREMENT" || die 'wrong designated requirement'
NAME="Verbemo-$VERSION_ARG-macos-universal.dmg"
bash scripts/build-dmg.sh "$APP" "Verbemo $VERSION_ARG" "$WORK/$NAME"
codesign --force --sign "$VERBEMO_SIGN_ID" --timestamp "$WORK/$NAME"
codesign --verify --strict "$WORK/$NAME"
xcrun notarytool submit "$WORK/$NAME" --key "$VERBEMO_NOTARY_KEY_FILE" \
    --key-id "$VERBEMO_NOTARY_KEY_ID" --issuer "$VERBEMO_NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json > "$WORK/notary.json"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Accepted" else 1)' \
    "$WORK/notary.json" || die 'notarization was not accepted'
xcrun stapler staple "$WORK/$NAME"
xcrun stapler validate "$WORK/$NAME"
spctl --assess --type open --context context:primary-signature "$WORK/$NAME"
# Sign only the final notarized and stapled bytes.
SIGNATURE=$("$SPARKLE_BIN/sign_update" -p --ed-key-file "$VERBEMO_SPARKLE_PRIVATE_KEY_FILE" \
    "$WORK/$NAME" 2>"$WORK/sign-error") || die 'DMG signing failed'
swift scripts/verify-sparkle-signature.swift "$WORK/$NAME" "$SIGNATURE"
python3 scripts/release_manifest.py appcast --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" \
    --build-number "$BUILD" --output "$WORK" --signature "$SIGNATURE"
"$SPARKLE_BIN/sign_update" -p --ed-key-file "$VERBEMO_SPARKLE_PRIVATE_KEY_FILE" \
    "$WORK/appcast.xml" >"$WORK/sign-output" 2>&1 || die 'appcast signing failed'
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$VERBEMO_SPARKLE_PRIVATE_KEY_FILE" \
    "$WORK/appcast.xml" >"$WORK/sign-output" 2>&1 || die 'appcast signature verification failed'
python3 scripts/release_manifest.py receipt --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" \
    --build-number "$BUILD" --output "$WORK"
python3 scripts/release_manifest.py validate-macos --version "$VERSION_ARG" --source-commit "$SOURCE_COMMIT" \
    --build-number "$BUILD" --output "$WORK"
# Ensure the source did not change during the long build/notarization operation.
python3 scripts/release_manifest.py preflight --root "$ROOT" --version "$VERSION_ARG" \
    --source-commit "$SOURCE_COMMIT" --output "$OUTPUT" >/dev/null
# Exclusive file creation also closes the overwrite race with another builder.
python3 - "$WORK" "$OUTPUT" "$NAME" <<'PY'
from pathlib import Path
import shutil
import sys
source, destination, dmg = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
destination.mkdir(parents=True, exist_ok=True)
created = []
try:
    for name in (dmg, 'appcast.xml', 'macos-build.json'):
        with (destination / name).open('xb') as target:
            created.append(destination / name)
            with (source / name).open('rb') as stream:
                shutil.copyfileobj(stream, target)
except BaseException:
    for path in created:
        path.unlink()
    raise
PY
printf 'Prepared macOS assets for Verbemo %s (build %s). Nothing published.\n' "$VERSION_ARG" "$BUILD"
