#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_APP="${1:-$ROOT_DIR/dist/SuperDictate.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

say() {
    printf 'SuperDictate: %s\n' "$*"
}

fail() {
    printf 'SuperDictate: %s\n' "$*" >&2
    exit 1
}

validate_output_app_path() {
    local output="$1"
    local parent base

    [[ -n "$output" ]] || fail "Output app path is empty."
    [[ "$output" == *.app ]] || fail "Output app path must end with .app."

    parent="$(dirname "$output")"
    base="$(basename "$output")"

    [[ "$base" != "." && "$base" != ".." ]] || fail "Output app path is not specific enough."
    [[ "$output" != "/" && "$parent" != "/" ]] || fail "Refusing to write directly under /."
    [[ "$output" != "$HOME" && "$parent" != "$HOME" ]] || fail "Refusing to replace the home directory."
    [[ "$output" != "/Applications" && "$parent" != "/Applications" ]] || fail "Refusing to write directly under /Applications."
    [[ "$output" != "$ROOT_DIR" && "$parent" != "$ROOT_DIR" ]] || fail "Refusing to replace the repository root."
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required."
machine="$(/usr/bin/uname -m)"
[[ "$machine" == "arm64" || "$machine" == "x86_64" ]] || fail "An Apple Silicon or Intel Mac is required."
validate_output_app_path "$OUTPUT_APP"
command -v swift >/dev/null 2>&1 || fail "Swift is missing. Run: xcode-select --install"
command -v codesign >/dev/null 2>&1 || fail "codesign is missing. Run: xcode-select --install"

say "Building the release app..."
swift build -c release --package-path "$ROOT_DIR/swift"
BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR/swift" --show-bin-path)"
BIN="$BIN_DIR/Parakey"
[[ -x "$BIN" ]] || fail "The Swift build did not produce $BIN"
# SuperDictateLLMHost (Ветка 1/2: local correction-model host) is a
# SEPARATE product built by the same `swift build` invocation above -- see
# its own comment in Package.swift for why it's never a dependency of
# Parakey. Bundled into Contents/Helpers/ (not Contents/MacOS/, which is
# reserved for the app's own main executable that Launch Services/Dock
# identify the app by) so LLMHostProcess.swift's
# resolvedHelperBinaryURL() finds it at runtime.
LLM_HOST_BIN="$BIN_DIR/SuperDictateLLMHost"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-build.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE_APP="$STAGE_DIR/SuperDictate.app"

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$BIN" "$STAGE_APP/Contents/MacOS/SuperDictate"
if [[ -x "$LLM_HOST_BIN" ]]; then
    mkdir -p "$STAGE_APP/Contents/Helpers"
    cp "$LLM_HOST_BIN" "$STAGE_APP/Contents/Helpers/SuperDictateLLMHost"
else
    echo "build-app.sh: WARNING: $LLM_HOST_BIN not found -- shipping without the local correction-model helper (text-correction mode will be unavailable in this build)" >&2
fi
cp "$ROOT_DIR/swift/Info.plist" "$STAGE_APP/Contents/Info.plist"
cp "$ROOT_DIR/swift/Resources/parakey-menubar.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/swift/Resources/parakey-menubar@2x.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/icon/Parakey.icns" "$STAGE_APP/Contents/Resources/Parakey.icns"
# Phase 5 (Vulkan): the loose, pre-compiled SPIR-V shader corpus (vendored by
# scripts/vendor-parakeet-cpp.sh into swift/Sources/parakeet_cpp/upstream/
# ggml-vulkan/vulkan-shaders/, excluded from SwiftPM compilation/resources —
# see Package.swift's exclude comment) must ship inside the app bundle for
# Vulkan to work at all: ParakeetEngine.swift's
# configureVulkanShaderDirectoryIfPresent() points the C++ runtime loader at
# exactly this Contents/Resources/vulkan-shaders directory. Copied as a
# real directory tree (not through SwiftPM `resources:`, which this project
# never uses — see the Parakey executable target's own `resources:` comment
# in Package.swift) so `codesign --deep` below covers every .spv file.
VULKAN_SHADER_SRC="$ROOT_DIR/swift/Sources/parakeet_cpp/upstream/ggml-vulkan/vulkan-shaders"
if [[ -d "$VULKAN_SHADER_SRC" ]]; then
    cp -R "$VULKAN_SHADER_SRC" "$STAGE_APP/Contents/Resources/vulkan-shaders"
else
    echo "build-app.sh: WARNING: $VULKAN_SHADER_SRC not found -- shipping without a Vulkan shader corpus (Vulkan GPU mode will not be usable in this build; re-run scripts/vendor-parakeet-cpp.sh with cmake+glslc on PATH to generate it)" >&2
fi
chmod 755 "$STAGE_APP/Contents/MacOS/SuperDictate"

SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime
           --entitlements "$ROOT_DIR/entitlements.plist")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi

say "Signing the app..."
codesign "${SIGN_ARGS[@]}" "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
mv "$STAGE_APP" "$OUTPUT_APP"
trap - EXIT
rm -rf "$STAGE_DIR"

say "Built $OUTPUT_APP"
