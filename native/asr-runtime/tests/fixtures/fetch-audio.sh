#!/bin/bash
# Downloads the parity-test audio (not committed) into a directory and
# verifies each file's SHA-256. The *.txt goldens next to this script were
# produced from exactly these bytes by tools/reference_tdt.py with
# onnxruntime 1.23.2 on an AVX2-only x86_64 CPU.
#
# Usage: fetch-audio.sh <dest_dir>   (then copy or symlink the goldens in, or
# point SD_ASR_TEST_GOLDEN_DIR at a directory holding both)
set -euo pipefail

dest="${1:?usage: fetch-audio.sh <dest_dir>}"
mkdir -p "$dest"
here="$(cd "$(dirname "$0")" && pwd)"

fetch() {
    local name="$1" url="$2" sha="$3" actual
    if [[ ! -f "$dest/$name" ]]; then
        curl --fail --location --silent --show-error --retry 3 -o "$dest/$name.tmp" "$url"
        mv "$dest/$name.tmp" "$dest/$name"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$dest/$name" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$dest/$name" | awk '{print $1}')"
    fi
    if [[ "$actual" != "$sha" ]]; then
        echo "fetch-audio: SHA-256 mismatch for $name" >&2
        rm -f "$dest/$name"
        exit 1
    fi
    cp "$here/${name%.wav}.txt" "$dest/"
}

# 16 kHz mono PCM16, English, 11.0 s (whisper.cpp sample, MIT)
fetch en_jfk.wav https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav \
    59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e
# 16 kHz mono PCM16, Russian, 11.3 s and 71.3 s (GigaAM examples, salute-developers)
fetch ru_example.wav https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/example.wav \
    d8aaaa18a5098d7c6de0595ae7ac1e64cacd0d4022af3595213bdaf23be77e69
fetch ru_long_example.wav https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/long_example.wav \
    1868ece0195dfa9fc2394be24865d1133c8452a8292a397db45ba8c3ed9e01e3
echo "fetch-audio: fixtures ready in $dest"
