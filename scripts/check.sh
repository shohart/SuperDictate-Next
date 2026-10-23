#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh uninstall.sh scripts/build-app.sh scripts/build-test-app.sh scripts/build-onnx-host.sh scripts/fetch-onnxruntime.sh scripts/benchmark-asr.sh scripts/check.sh scripts/verify-release.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
installer_version="$(sed -n 's/^RELEASE_VERSION="\([^"]*\)"$/\1/p' install.sh)"
installer_tag="$(sed -n 's/^RELEASE_TAG="\([^"]*\)"$/\1/p' install.sh)"
[[ "$installer_tag" == "mac-v$installer_version" || "$installer_tag" == "v$installer_version" ]] || {
    printf 'install.sh RELEASE_TAG=%s does not name version %s (expected mac-v%s)\n' \
        "$installer_tag" "$installer_version" "$installer_version" >&2
    exit 1
}
installer_sha256="$(sed -n 's/^RELEASE_SHA256="\([^"]*\)"$/\1/p' install.sh)"
manifest_version="$(plutil -extract version raw -o - update.json)"
manifest_sha256="$(plutil -extract sha256 raw -o - update.json)"
[[ -n "$installer_version" && "$app_version" == "$installer_version" ]] || {
    printf 'Version mismatch: Info.plist=%s install.sh=%s\n' "$app_version" "$installer_version" >&2
    exit 1
}
[[ "$manifest_version" == "$app_version" ]] || {
    printf 'Version mismatch: Info.plist=%s update.json=%s\n' "$app_version" "$manifest_version" >&2
    exit 1
}
[[ "$manifest_sha256" == "$installer_sha256" && "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Checksum mismatch: install.sh=%s update.json=%s\n' "$installer_sha256" "$manifest_sha256" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

! grep -q 'shohart/SuperDictate-Intel\|shlgd/SuperDictate' README.md README.ru.md
grep -q 'raw.githubusercontent.com/shohart/SuperDictate-Next/main/install.sh' README.md
grep -q 'raw.githubusercontent.com/shohart/SuperDictate-Next/main/install.sh' README.ru.md
grep -q '^REF="${SUPERDICTATE_REF:-\$SOURCE_COMMIT}"$' install.sh
grep -q '^EXPECTED_SOURCE_COMMIT="${SUPERDICTATE_SOURCE_COMMIT:-\$SOURCE_COMMIT}"$' install.sh
grep -q 'verify_source_ref' install.sh
grep -q 'validate_output_app_path "$OUTPUT_APP"' scripts/build-app.sh

git diff --check
printf 'SuperDictate checks passed (v%s).\n' "$app_version"
