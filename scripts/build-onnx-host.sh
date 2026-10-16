#!/bin/bash
# scripts/build-onnx-host.sh — build SuperDictateOnnxHost (native/asr-runtime)
# and stage it into an UNSIGNED .app bundle, for build-app.sh and
# build-test-app.sh (docs/specs/cross-platform-onnx-asr-spec.md §10):
#
#   Contents/Helpers/SuperDictateOnnxHost          rpath @executable_path/../Frameworks
#   Contents/Frameworks/libonnxruntime.1.23.2.dylib
#   Contents/Resources/onnx-asr/onnx-models.json   pinned model catalog
#   Contents/Resources/onnx-asr/nemo128.onnx       bundled feature graph
#   Contents/Resources/onnx-asr/ThirdPartyNotices.txt, onnxruntime-LICENSE.txt
#
# The host comes from a separate CMake tree built with
# CMAKE_BUILD_WITH_INSTALL_RPATH, so it never carries the SDK's build rpath.
# Signing is the caller's job (codesign --deep over the whole bundle).
#
# Usage: scripts/build-onnx-host.sh <staged.app>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: build-onnx-host.sh <staged.app>}"
ORT_VERSION="1.23.2"
RUNTIME_DIR="$ROOT_DIR/native/asr-runtime"
BUILD_DIR="$RUNTIME_DIR/build-bundle"

say() { printf 'build-onnx-host: %s\n' "$*"; }
fail() { printf 'build-onnx-host: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP/Contents" ]] || fail "$APP is not a staged .app bundle"
# Non-interactive shells on the Intel Mac lack Homebrew's cmake/ninja on PATH.
export PATH="$PATH:/usr/local/opt/cmake/bin:/usr/local/bin:/opt/homebrew/bin"
command -v cmake >/dev/null 2>&1 || fail "cmake is missing (brew install cmake)"

case "$(/usr/bin/uname -m)" in
    x86_64) platform="osx-x86_64" ;;
    arm64) platform="osx-arm64" ;;
    *) fail "unsupported architecture $(/usr/bin/uname -m)" ;;
esac
ORT_ROOT="$RUNTIME_DIR/third_party/onnxruntime/$platform"
"$ROOT_DIR/scripts/fetch-onnxruntime.sh" "$platform"

generator=()
command -v ninja >/dev/null 2>&1 && generator=(-G Ninja)
say "building SuperDictateOnnxHost ($platform)..."
cmake -S "$RUNTIME_DIR" -B "$BUILD_DIR" "${generator[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build "$BUILD_DIR" --target SuperDictateOnnxHost >/dev/null
HOST="$BUILD_DIR/SuperDictateOnnxHost"
[[ -x "$HOST" ]] || fail "the CMake build did not produce $HOST"

DYLIB="$ORT_ROOT/lib/libonnxruntime.$ORT_VERSION.dylib"
[[ -f "$DYLIB" && ! -L "$DYLIB" ]] || fail "missing $DYLIB"

mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/onnx-asr"
cp "$HOST" "$APP/Contents/Helpers/SuperDictateOnnxHost"
chmod 755 "$APP/Contents/Helpers/SuperDictateOnnxHost"
cp "$DYLIB" "$APP/Contents/Frameworks/"
chmod 644 "$APP/Contents/Frameworks/libonnxruntime.$ORT_VERSION.dylib"
cp "$RUNTIME_DIR/catalog/onnx-models.json" "$APP/Contents/Resources/onnx-asr/onnx-models.json"
cp "$RUNTIME_DIR/assets/nemo128.onnx" "$APP/Contents/Resources/onnx-asr/nemo128.onnx"
cp "$ORT_ROOT/ThirdPartyNotices.txt" "$APP/Contents/Resources/onnx-asr/ThirdPartyNotices.txt"
cp "$ORT_ROOT/LICENSE" "$APP/Contents/Resources/onnx-asr/onnxruntime-LICENSE.txt"

# Packaging checks (spec §10): no Homebrew/SDK paths, the bundle rpath only.
staged_host="$APP/Contents/Helpers/SuperDictateOnnxHost"
if otool -L "$staged_host" | tail -n +2 | grep -Eq '/usr/local/|/opt/homebrew/|Cellar|third_party'; then
    otool -L "$staged_host" >&2
    fail "SuperDictateOnnxHost links a non-system path"
fi
otool -L "$staged_host" | grep -q "@rpath/libonnxruntime.$ORT_VERSION.dylib" \
    || fail "SuperDictateOnnxHost does not load ONNX Runtime via @rpath"
rpaths="$(otool -l "$staged_host" | awk '/LC_RPATH/ {getline; getline; print $2}')"
[[ "$rpaths" == "@executable_path/../Frameworks" ]] \
    || fail "unexpected SuperDictateOnnxHost rpath(s): $rpaths"
say "staged host, ONNX Runtime $ORT_VERSION and onnx-asr resources into $APP"
