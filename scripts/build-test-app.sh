#!/bin/bash
# scripts/build-test-app.sh — build a SEPARATE, distinctly-identified test
# app for local dev/testing, so it never touches the real installed
# /Applications/SuperDictate.app or its LaunchAgent (com.local.superdictate.agent).
#
# Why this exists: rebuilding swift/.build/{debug,release}/Parakey in place
# and letting a dev-mode LaunchAgent pick it up caused the real background
# service to run unsigned/differently-signed WIP code, which macOS TCC then
# treated as a different app -- resetting microphone/accessibility
# permissions for the user's daily-use installation. A distinct bundle
# identifier (CFBundleIdentifier) is a SEPARATE identity to TCC, so this
# test app gets its own independent permission grants the first time it's
# run, and can be rebuilt/updated afterwards without ever disturbing the
# real app's permissions or process. Same pattern this project has used
# before for a "devtest" build (com.local.superdictate.devtest).
#
# This script NEVER writes to /Applications and NEVER touches any
# LaunchAgent -- it only produces a standalone .app in dist/ (or wherever
# OUTPUT_APP points) that you run manually with `open`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Override any of these via env vars if you need a different name/id per
# concurrent test build; defaults match this project's prior "devtest" build.
APP_LABEL="${TEST_APP_LABEL:-test}"                 # e.g. "test", "llm-gec", "vocab-test"
APP_NAME="SuperDictate-${APP_LABEL}"
BUNDLE_ID="${TEST_BUNDLE_ID:-com.local.superdictate.${APP_LABEL}}"
BUILD_CONFIG="${TEST_BUILD_CONFIG:-release}"        # debug is ~20-30x slower for CPU-bound inference; default release
OUTPUT_APP="${1:-$ROOT_DIR/dist/${APP_NAME}.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

say() { printf 'build-test-app: %s\n' "$*"; }
fail() { printf 'build-test-app: %s\n' "$*" >&2; exit 1; }

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$OUTPUT_APP" == *.app ]] || fail "Output app path must end with .app."
[[ "$OUTPUT_APP" != /Applications/SuperDictate.app ]] || fail "Refusing to overwrite the real installed app -- use build-app.sh + install-local.sh for that, deliberately, not this script."
[[ "$BUNDLE_ID" != "com.local.superdictate" ]] || fail "Refusing to reuse the real app's bundle identifier -- that would collide with its TCC permissions."

say "Building ($BUILD_CONFIG)..."
swift build -c "$BUILD_CONFIG" --package-path "$ROOT_DIR/swift"
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --package-path "$ROOT_DIR/swift" --show-bin-path)"
BIN="$BIN_DIR/Parakey"
[[ -x "$BIN" ]] || fail "The Swift build did not produce $BIN"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-test-build.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE_APP="$STAGE_DIR/${APP_NAME}.app"

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$BIN" "$STAGE_APP/Contents/MacOS/${APP_NAME}"
cp "$ROOT_DIR/swift/Resources/parakey-menubar.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/swift/Resources/parakey-menubar@2x.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/icon/Parakey.icns" "$STAGE_APP/Contents/Resources/Parakey.icns"
VULKAN_SHADER_SRC="$ROOT_DIR/swift/Sources/parakeet_cpp/upstream/ggml-vulkan/vulkan-shaders"
if [[ -d "$VULKAN_SHADER_SRC" ]]; then
    cp -R "$VULKAN_SHADER_SRC" "$STAGE_APP/Contents/Resources/vulkan-shaders"
fi
# The bundled LLM host helper (Ветка 1), if built -- same relative layout
# build-app.sh will eventually use for the real app.
LLM_HOST_BIN="$BIN_DIR/SuperDictateLLMHost"
if [[ -x "$LLM_HOST_BIN" ]]; then
    mkdir -p "$STAGE_APP/Contents/Helpers"
    cp "$LLM_HOST_BIN" "$STAGE_APP/Contents/Helpers/SuperDictateLLMHost"
fi
chmod 755 "$STAGE_APP/Contents/MacOS/${APP_NAME}"

# Info.plist: same as swift/Info.plist but with the identity fields
# substituted for a distinct bundle identifier/name/executable, using
# PlistBuddy so this stays correct even if swift/Info.plist gains new keys.
cp "$ROOT_DIR/swift/Info.plist" "$STAGE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$STAGE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$STAGE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE_APP/Contents/Info.plist"

SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime
           --entitlements "$ROOT_DIR/entitlements.plist")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi

say "Signing ($BUNDLE_ID, identity=$SIGN_IDENTITY)..."
codesign "${SIGN_ARGS[@]}" "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
mv "$STAGE_APP" "$OUTPUT_APP"
trap - EXIT
rm -rf "$STAGE_DIR"

say "Built $OUTPUT_APP (bundle id: $BUNDLE_ID)"
say "This never touched /Applications/SuperDictate.app or its LaunchAgent."
say "Run it manually: open \"$OUTPUT_APP\" -- first launch will prompt for its OWN separate permissions."
