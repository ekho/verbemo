#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT="$ROOT/.build/localvqe"
SOURCE="$OUT/source"
MODEL_NAME="localvqe-v1.4-aec-200K-f32.gguf"
MODEL_REV="29ca38495cba9d6393a92a4dd890f28dd81f758d"
MODEL_URL="https://huggingface.co/LocalAI-io/LocalVQE/resolve/$MODEL_REV/$MODEL_NAME"
MODEL_SHA="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"
SOURCE_REV="f53063c9eb2a85f96479867d1dd911dc3bf6319b"
GGML_REV="c044a8eeae2591faa0950c8b5e514cbc4bbfc4ca"
# SHA-256 of approved diffs with full object IDs (not Git's variable abbreviations).
MACOS_PATCH_SHA="0e8dc01c74faa8a014f2782546d6b58631abecc32b747cc10efa7b6121cfd3cf"
GGML_GRU_PATCH_SHA="4d8b39b91707d984f6ba6a529b821effe4844730a6f0571f42a21c5b0c5b11c7"
MINIMUM_MACOS=${VERBEMO_MINIMUM_MACOS:-14.2}
if [ -n "${VERBEMO_CMAKE:-}" ]; then
    CMAKE=$VERBEMO_CMAKE
elif command -v cmake >/dev/null; then
    CMAKE=$(command -v cmake)
elif [ -x "$ROOT/.build/echo-research-2026-09-06/venv/bin/cmake" ]; then
    CMAKE="$ROOT/.build/echo-research-2026-09-06/venv/bin/cmake"
else
    echo "cmake is required to build LocalVQE" >&2
    exit 1
fi
command -v lipo >/dev/null || { echo "lipo is required to build LocalVQE" >&2; exit 1; }

mkdir -p "$OUT"
if [ ! -d "$SOURCE/.git" ]; then
    if [ -n "${VERBEMO_LOCALVQE_SOURCE:-}" ]; then
        test -d "$VERBEMO_LOCALVQE_SOURCE/.git" \
            || { echo "VERBEMO_LOCALVQE_SOURCE is not a git checkout" >&2; exit 1; }
        ditto "$VERBEMO_LOCALVQE_SOURCE" "$SOURCE"
    else
        git clone --no-checkout https://github.com/localai-org/LocalVQE.git "$SOURCE"
        git -C "$SOURCE" checkout --detach "$SOURCE_REV"
        git -C "$SOURCE" submodule update --init --recursive
    fi
fi

test "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REV" \
    || { echo "LocalVQE source is not pinned at $SOURCE_REV" >&2; exit 1; }
test "$(git -C "$SOURCE/ggml/vendor/ggml" rev-parse HEAD)" = "$GGML_REV" \
    || { echo "ggml source is not pinned at $GGML_REV" >&2; exit 1; }

if git -C "$SOURCE" apply --check "$ROOT/scripts/localvqe-macos.patch" 2>/dev/null; then
    git -C "$SOURCE" apply "$ROOT/scripts/localvqe-macos.patch"
elif ! git -C "$SOURCE" apply --reverse --check "$ROOT/scripts/localvqe-macos.patch" 2>/dev/null; then
    echo "LocalVQE macOS patch does not apply to the pinned revision" >&2
    exit 1
fi

"$ROOT/scripts/verify-localvqe-source.sh" \
    "$SOURCE" "$SOURCE_REV" "$GGML_REV" \
    "$MACOS_PATCH_SHA" "$GGML_GRU_PATCH_SHA" \
    --allow-unpatched-ggml

mkdir -p "$OUT/model" "$OUT/lib" "$OUT/licenses"
MODEL="$OUT/model/$MODEL_NAME"
if [ -n "${VERBEMO_LOCALVQE_MODEL:-}" ]; then
    cp "$VERBEMO_LOCALVQE_MODEL" "$MODEL"
elif [ ! -f "$MODEL" ]; then
    curl -fL --retry 3 --output "$MODEL.tmp" "$MODEL_URL"
    mv "$MODEL.tmp" "$MODEL"
fi
printf '%s  %s\n' "$MODEL_SHA" "$MODEL" | shasum -a 256 -c -

JOBS=${VERBEMO_LOCALVQE_JOBS:-2}
for ARCH in arm64 x86_64; do
    BUILD="$OUT/build-$ARCH"
    "$CMAKE" -S "$SOURCE/ggml" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS" \
        -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
        -DLOCALVQE_BUILD_SHARED=ON \
        -DGGML_METAL=OFF \
        -DGGML_BLAS=OFF
done

# LocalVQE's configure step adds the pinned GRU implementation when upstream
# ggml does not contain it. Validate every tracked file before compiling.
"$ROOT/scripts/verify-localvqe-source.sh" \
    "$SOURCE" "$SOURCE_REV" "$GGML_REV" \
    "$MACOS_PATCH_SHA" "$GGML_GRU_PATCH_SHA"

for ARCH in arm64 x86_64; do
    BUILD="$OUT/build-$ARCH"
    "$CMAKE" --build "$BUILD" --target localvqe_shared -j "$JOBS"
done

"$ROOT/scripts/verify-localvqe-source.sh" \
    "$SOURCE" "$SOURCE_REV" "$GGML_REV" \
    "$MACOS_PATCH_SHA" "$GGML_GRU_PATCH_SHA"

ARM_LIBRARY="$OUT/build-arm64/liblocalvqe.0.1.0.dylib"
X86_LIBRARY="$OUT/build-x86_64/liblocalvqe.0.1.0.dylib"
test -f "$ARM_LIBRARY" || { echo "arm64 LocalVQE library is missing" >&2; exit 1; }
test -f "$X86_LIBRARY" || { echo "x86_64 LocalVQE library is missing" >&2; exit 1; }
lipo -create "$ARM_LIBRARY" "$X86_LIBRARY" -output "$OUT/lib/liblocalvqe.dylib"
install_name_tool -id @rpath/liblocalvqe.dylib "$OUT/lib/liblocalvqe.dylib"

ARCHES=$(lipo -archs "$OUT/lib/liblocalvqe.dylib")
case " $ARCHES " in *" arm64 "*) ;; *) echo "LocalVQE has no arm64 slice" >&2; exit 1;; esac
case " $ARCHES " in *" x86_64 "*) ;; *) echo "LocalVQE has no x86_64 slice" >&2; exit 1;; esac
if otool -L "$OUT/lib/liblocalvqe.dylib" \
    | awk '/^\t/{print $1}' \
    | grep -Ev '^(@rpath/liblocalvqe\.dylib|/usr/lib/|/System/Library/)' >/dev/null; then
    echo "LocalVQE has a non-system runtime dependency:" >&2
    otool -L "$OUT/lib/liblocalvqe.dylib" >&2
    exit 1
fi

cp "$SOURCE/LICENSE" "$OUT/licenses/LocalVQE-LICENSE"
cp "$SOURCE/ggml/vendor/ggml/LICENSE" "$OUT/licenses/ggml-LICENSE"
LIBRARY_SHA=$(shasum -a 256 "$OUT/lib/liblocalvqe.dylib" | awk '{print $1}')
printf '{\n  "localvqe_revision": "%s",\n  "macos_patch_sha256": "%s",\n  "ggml_revision": "%s",\n  "ggml_gru_patch_sha256": "%s",\n  "model_revision": "%s",\n  "model": "%s",\n  "model_sha256": "%s",\n  "unsigned_library_sha256": "%s",\n  "architectures": ["arm64", "x86_64"]\n}\n' \
    "$SOURCE_REV" "$MACOS_PATCH_SHA" "$GGML_REV" "$GGML_GRU_PATCH_SHA" \
    "$MODEL_REV" "$MODEL_NAME" "$MODEL_SHA" "$LIBRARY_SHA" \
    > "$OUT/verification.json"

echo "LocalVQE ready → $OUT ($ARCHES)"
