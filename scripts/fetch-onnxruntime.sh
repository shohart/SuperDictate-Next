#!/bin/bash
# scripts/fetch-onnxruntime.sh — download the pinned ONNX Runtime SDK for one
# platform, verify its SHA-256, and extract it to
# native/asr-runtime/third_party/onnxruntime/<platform>/ (git-ignored).
#
# Pinned to 1.23.2 on every platform: 1.24.x no longer publishes an
# osx-x86_64 build, and one version everywhere means one C ABI everywhere
# (docs/specs/cross-platform-onnx-asr-spec.md §2.1). Bumping the pin means
# bumping ORT_VERSION and every hash below together.
#
# Usage: scripts/fetch-onnxruntime.sh [linux-x64|osx-x86_64|osx-arm64|win-x64]
# With no argument, the host platform is detected.
set -euo pipefail

ORT_VERSION="1.23.2"

platform="${1:-}"
if [[ -z "$platform" ]]; then
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) platform="linux-x64" ;;
        Darwin-x86_64) platform="osx-x86_64" ;;
        Darwin-arm64) platform="osx-arm64" ;;
        MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) platform="win-x64" ;;
        *) echo "fetch-onnxruntime: unsupported host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
    esac
fi

case "$platform" in
    linux-x64)  ext="tgz"; sha="1fa4dcaef22f6f7d5cd81b28c2800414350c10116f5fdd46a2160082551c5f9b" ;;
    osx-x86_64) ext="tgz"; sha="d10359e16347b57d9959f7e80a225a5b4a66ed7d7e007274a15cae86836485a6" ;;
    osx-arm64)  ext="tgz"; sha="b4d513ab2b26f088c66891dbbc1408166708773d7cc4163de7bdca0e9bbb7856" ;;
    win-x64)    ext="zip"; sha="0b38df9af21834e41e73d602d90db5cb06dbd1ca618948b8f1d66d607ac9f3cd" ;;
    *) echo "fetch-onnxruntime: unknown platform '$platform'" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/native/asr-runtime/third_party/onnxruntime/$platform"
name="onnxruntime-$platform-$ORT_VERSION"
url="https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/$name.$ext"

if [[ -f "$dest/.sd-ort-version" ]] && [[ "$(cat "$dest/.sd-ort-version")" == "$ORT_VERSION $sha" ]]; then
    echo "fetch-onnxruntime: $platform $ORT_VERSION already present at $dest"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetch-onnxruntime: downloading $url"
curl --fail --location --silent --show-error --retry 3 -o "$work/archive.$ext" "$url"

if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/archive.$ext" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "$work/archive.$ext" | awk '{print $1}')"
fi
if [[ "$actual" != "$sha" ]]; then
    echo "fetch-onnxruntime: SHA-256 mismatch for $name.$ext" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

mkdir -p "$work/x"
if [[ "$ext" == "zip" ]]; then
    unzip -q "$work/archive.$ext" -d "$work/x"
else
    tar -xzf "$work/archive.$ext" -C "$work/x"
fi
test -d "$work/x/$name/include" || { echo "fetch-onnxruntime: unexpected archive layout" >&2; exit 1; }

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$work/x/$name" "$dest"
echo "$ORT_VERSION $sha" > "$dest/.sd-ort-version"
echo "fetch-onnxruntime: $platform $ORT_VERSION -> $dest"
