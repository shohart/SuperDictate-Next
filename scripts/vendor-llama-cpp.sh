#!/bin/bash
# scripts/vendor-llama-cpp.sh — deterministically vendor a pinned llama.cpp
# (its own in-tree ggml, CPU+BLAS+Vulkan backends only, plus the subset of
# common/ needed for chat-template-aware single-turn text generation) into
# swift/Sources/llama_cpp_host/upstream/. Re-run this and commit the result
# to update the pin; never hand-edit files under
# swift/Sources/llama_cpp_host/upstream/ — this script wipes and regenerates
# that whole directory.
#
# This is a DELIBERATELY MINIMAL slice of llama.cpp, not a vendor of
# tools/server: no mtmd (multimodal), no llama-ui (bundled web UI), no
# download/http/hf-cache/preset/console/subproc/arg (CLI flag parsing and
# model auto-download machinery this app never uses — the model path is
# always supplied locally by Swift, same policy as the Parakeet ASR model:
# downloaded on demand by the app, never fetched by this helper itself).
# SuperDictate's own hand-authored HTTP entrypoint
# (swift/Sources/llama_cpp_host/bridge/superdictate_llm_host_main.cpp, NOT
# touched by this script) links against the vendored llama core + the
# common/ subset below (model loading, sampling, chat-template rendering)
# and implements a minimal OpenAI-compatible /v1/chat/completions + /health
# surface directly, using vendored cpp-httplib + nlohmann/json.
#
# This is a SEPARATE, independent ggml vendor tree from
# swift/Sources/parakeet_cpp/upstream/ (see that script's own header for
# why: two independently vendored copies of ggml's C symbols cannot be
# statically linked into the same executable). This target
# (SuperDictateLLMHost) is its own SPM executableTarget, never a dependency
# of the Parakey executable — the two processes never share an address
# space, so the duplicate ggml symbols never collide at link time.
set -euo pipefail

LLAMA_CPP_COMMIT="d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd"
LLAMA_CPP_REMOTE="https://github.com/ggml-org/llama.cpp.git"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/swift/Sources/llama_cpp_host"
UPSTREAM_DEST="$DEST/upstream"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "vendor-llama-cpp.sh: cloning llama.cpp @ $LLAMA_CPP_COMMIT ..."
git clone --quiet "$LLAMA_CPP_REMOTE" "$WORK_DIR/src"
git -C "$WORK_DIR/src" checkout --quiet "$LLAMA_CPP_COMMIT"

ACTUAL_COMMIT="$(git -C "$WORK_DIR/src" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$LLAMA_CPP_COMMIT" ]]; then
    echo "vendor-llama-cpp.sh: FATAL: checked out $ACTUAL_COMMIT, expected $LLAMA_CPP_COMMIT" >&2
    exit 1
fi

SRC="$WORK_DIR/src"
GGML_SRC="$SRC/ggml"

rm -rf "$UPSTREAM_DEST"
mkdir -p "$UPSTREAM_DEST/include" "$UPSTREAM_DEST/src/models" "$UPSTREAM_DEST/common/jinja" \
         "$UPSTREAM_DEST/ggml-cpu" "$UPSTREAM_DEST/vendor/nlohmann" "$UPSTREAM_DEST/vendor/cpp-httplib"

# --- public headers (llama.cpp's own + ggml's own, merged flat like this
#     fork's existing parakeet_cpp/upstream/include/ convention) ---
cp "$SRC/include/"*.h "$UPSTREAM_DEST/include/"
cp "$GGML_SRC/include/"*.h "$UPSTREAM_DEST/include/"

# --- llama core (src/), flat + its own models/ subdir, exactly mirroring
#     upstream's own directory shape so sibling quote-includes (e.g.
#     common/fit.cpp's `#include "../src/llama-ext.h"`) resolve unchanged ---
for f in "$SRC"/src/*.cpp "$SRC"/src/*.h; do
    cp "$f" "$UPSTREAM_DEST/src/$(basename "$f")"
done
cp "$SRC"/src/models/*.cpp "$SRC"/src/models/*.h "$UPSTREAM_DEST/src/models/"

# --- common/ subset: model loading + sampling + chat-template rendering
#     ONLY. Deliberately excludes arg.cpp, download.cpp, http.h, hf-cache.cpp,
#     preset.cpp, console.cpp, subproc.cpp, debug.cpp, imatrix-loader.cpp,
#     llguidance.cpp -- none of those are reachable from the minimal surface
#     this app's own main.cpp actually calls (model load, tokenize, sample,
#     apply chat template, detokenize). build-info.h/.cpp are hand-authored
#     below instead of upstream's CMake-`configure_file`'d versions.
for f in common.cpp common.h sampling.cpp sampling.h chat.cpp chat.h \
         chat-auto-parser.h chat-auto-parser-helpers.cpp chat-auto-parser-helpers.h \
         chat-auto-parser-generator.cpp chat-diff-analyzer.cpp \
         chat-peg-parser.cpp chat-peg-parser.h peg-parser.cpp peg-parser.h \
         json-schema-to-grammar.cpp json-schema-to-grammar.h \
         log.cpp log.h fit.cpp fit.h speculative.cpp speculative.h \
         ngram-cache.cpp ngram-cache.h ngram-map.cpp ngram-map.h ngram-mod.cpp ngram-mod.h \
         trie.cpp trie.h unicode.cpp unicode.h reasoning-budget.cpp reasoning-budget.h \
         base64.hpp; do
    cp "$SRC/common/$f" "$UPSTREAM_DEST/common/$f"
done
cp "$SRC"/common/jinja/*.cpp "$SRC"/common/jinja/*.h "$UPSTREAM_DEST/common/jinja/"

cat > "$UPSTREAM_DEST/common/build-info.h" <<'EOF'
// Hand-authored replacement for upstream's CMake `configure_file`'d
// build-info.h/.cpp -- SwiftPM has no configure_file step, so this fixes
// the values instead of stamping them at build time. See
// scripts/vendor-llama-cpp.sh for the pinned commit these correspond to.
#pragma once
int          llama_build_number(void);
const char * llama_commit(void);
const char * llama_compiler(void);
const char * llama_build_target(void);
EOF
cat > "$UPSTREAM_DEST/common/build-info.cpp" <<EOF
// Hand-authored: see build-info.h.
#include "build-info.h"
#include <string>

int llama_build_number(void)   { return 0; }
const char * llama_commit(void)       { return "$ACTUAL_COMMIT"; }
const char * llama_compiler(void)     { return "SuperDictateLLMHost"; }
const char * llama_build_target(void) { return "x86_64-apple-macosx"; }
const char * llama_build_info(void) {
    static std::string s = std::string("SuperDictateLLMHost-") + "$ACTUAL_COMMIT";
    return s.c_str();
}
EOF

# --- vendored third-party deps (both MIT-licensed). nlohmann/json is
#     genuinely header-only; cpp-httplib ships pre-split into httplib.h +
#     httplib.cpp (a plain `#include "httplib.h"` translation unit, not a
#     macro-gated single-header mode) so both are vendored. ---
cp "$SRC/vendor/nlohmann/json.hpp" "$SRC/vendor/nlohmann/json_fwd.hpp" "$UPSTREAM_DEST/vendor/nlohmann/"
cp "$SRC/vendor/cpp-httplib/httplib.h" "$SRC/vendor/cpp-httplib/httplib.cpp" "$UPSTREAM_DEST/vendor/cpp-httplib/"

# --- ggml core (backend-agnostic) -- same file set this fork's
#     scripts/vendor-parakeet-cpp.sh already established as sufficient to
#     link a CPU+Accelerate/BLAS ggml build, from llama.cpp's own (separately
#     pinned, NOT shared with parakeet_cpp/upstream) in-tree ggml/ copy ---
for f in ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-reg.cpp \
         ggml-backend-impl.h ggml-backend-dl.h ggml-backend-dl.cpp \
         ggml-backend-meta.cpp ggml-common.h ggml-impl.h ggml-opt.cpp \
         ggml-quants.c ggml-quants.h ggml-threading.cpp ggml-threading.h \
         gguf.cpp; do
    cp "$GGML_SRC/src/$f" "$UPSTREAM_DEST/$f"
done

# --- ggml BLAS backend (Accelerate cblas_sgemm acceleration on macOS) ---
cp "$GGML_SRC/src/ggml-blas/ggml-blas.cpp" "$UPSTREAM_DEST/ggml-blas.cpp"

# --- ggml CPU backend only (no cuda/metal/etc; same exclusion set as
#     scripts/vendor-parakeet-cpp.sh) ---
cp -R "$GGML_SRC/src/ggml-cpu/." "$UPSTREAM_DEST/ggml-cpu/"
rm -rf \
    "$UPSTREAM_DEST/ggml-cpu/arch/arm" \
    "$UPSTREAM_DEST/ggml-cpu/arch/riscv" \
    "$UPSTREAM_DEST/ggml-cpu/arch/powerpc" \
    "$UPSTREAM_DEST/ggml-cpu/arch/s390" \
    "$UPSTREAM_DEST/ggml-cpu/arch/wasm" \
    "$UPSTREAM_DEST/ggml-cpu/arch/loongarch" \
    "$UPSTREAM_DEST/ggml-cpu/spacemit" \
    "$UPSTREAM_DEST/ggml-cpu/kleidiai" \
    "$UPSTREAM_DEST/ggml-cpu/cmake" \
    "$UPSTREAM_DEST/ggml-cpu/CMakeLists.txt"

# --- provenance metadata (generated, never hand-edited) ---
cat > "$UPSTREAM_DEST/PROVENANCE.md" <<EOF
# Vendored upstream provenance (generated by scripts/vendor-llama-cpp.sh)

Do not hand-edit anything under this directory -- re-run the vendor script.

- llama.cpp: https://github.com/ggml-org/llama.cpp
  commit: $ACTUAL_COMMIT
- ggml: llama.cpp's own in-tree copy at the same commit (ggml/ -- NOT
  shared with swift/Sources/parakeet_cpp/upstream/'s independently pinned
  ggml v0.13.0; deliberately two separate vendor trees, see this script's
  header comment for why).
- Vendored: CPU backend (Accelerate/BLAS on macOS) plus the Vulkan backend,
  and a deliberately minimal common/ subset (model loading, sampling,
  chat-template rendering via common/jinja/) -- NOT tools/server, NOT mtmd,
  NOT llama-ui, NOT arg/download/http/hf-cache/preset/console/subproc. No
  CUDA, HIP, Metal, or CoreML sources are included.
- Third-party single-header deps also vendored here (both MIT): vendor/nlohmann
  (nlohmann/json), vendor/cpp-httplib (yhirose/cpp-httplib).
- License: both llama.cpp and its in-tree ggml are MIT-licensed. See
  LICENSE-llama-cpp.txt in this directory for the exact upstream notice at
  the pinned commit above.
- Vendored on: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cp "$SRC/LICENSE" "$UPSTREAM_DEST/LICENSE-llama-cpp.txt"

# --- Vulkan backend ---
#
# Same mechanism scripts/vendor-parakeet-cpp.sh already proved for this
# fork (see that script's own header comment for the full rationale):
# copies the device-agnostic ggml-vulkan.cpp/.h sources unconditionally,
# and -- only if cmake+glslc are on PATH -- (re)builds the real SPIR-V
# corpus plus runtime-loader glue (scripts/gen-vulkan-shader-runtime.py,
# ggml-version-independent) so the corpus ships as loose `.spv` files
# instead of ~230MB of compiled-in C-array source. `-DGGML_VULKAN=ON` is
# llama.cpp/ggml's own CMake option (parakeet.cpp's fork used
# `-DPARAKEET_GGML_VULKAN=ON`, a project-specific alias for the same
# underlying option -- llama.cpp itself doesn't have that alias).
# GGML_METAL defaults ON via GGML_METAL_DEFAULT on Apple platforms and
# must be forced off to keep this CPU+BLAS+Vulkan only, matching
# parakeet_cpp's own backend set (no Metal/CoreML anywhere in this fork).
vendor_vulkan_backend() {
    local vk_src="$GGML_SRC/src/ggml-vulkan"
    local vk_dest="$UPSTREAM_DEST/ggml-vulkan"
    mkdir -p "$vk_dest"

    cp "$vk_src/ggml-vulkan.cpp" "$vk_dest/ggml-vulkan.cpp"
    # ggml-vulkan.h itself is already vendored by the blanket
    # `cp "$GGML_SRC/include/"*.h "$UPSTREAM_DEST/include/"` copy above.

    cp "$ROOT_DIR/scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.h" \
       "$vk_dest/ggml-vulkan-shaders-runtime.h"
    cp "$ROOT_DIR/scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.cpp" \
       "$vk_dest/ggml-vulkan-shaders-runtime.cpp"

    if ! command -v cmake >/dev/null 2>&1 || ! command -v glslc >/dev/null 2>&1; then
        echo "vendor-llama-cpp.sh: cmake and/or glslc not found on PATH -- skipping Vulkan shader (re)generation." >&2
        echo "vendor-llama-cpp.sh: ggml-vulkan.cpp/.h + the runtime-loader glue were still (re)vendored above;" >&2
        echo "vendor-llama-cpp.sh: any already-committed $vk_dest/vulkan-shaders/ + generated" >&2
        echo "vendor-llama-cpp.sh: ggml-vulkan-shaders.hpp/.cpp are left untouched." >&2
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "vendor-llama-cpp.sh: FATAL: cmake+glslc found but python3 is required for scripts/gen-vulkan-shader-runtime.py and was not found on PATH" >&2
        exit 1
    fi

    echo "vendor-llama-cpp.sh: cmake+glslc found -- (re)building the Vulkan SPIR-V shader corpus (this runs llama.cpp's own upstream CMake build; can take a few minutes) ..."
    local vk_build="$WORK_DIR/vk-build"
    cmake -S "$SRC" -B "$vk_build" \
        -DGGML_VULKAN=ON -DGGML_METAL=OFF -DGGML_CUDA=OFF -DGGML_HIP=OFF \
        -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$vk_build" --target ggml-vulkan -j

    local gen_dir="$vk_build/ggml/src/ggml-vulkan"
    local spv_dir="$gen_dir/vulkan-shaders.spv"
    if [[ ! -d "$spv_dir" ]]; then
        echo "vendor-llama-cpp.sh: FATAL: expected compiled .spv directory not found at $spv_dir -- upstream's CMake output layout may have changed" >&2
        exit 1
    fi
    rm -rf "$vk_dest/vulkan-shaders"
    mkdir -p "$vk_dest/vulkan-shaders"
    local spv_count=0
    for f in "$spv_dir"/*.spv; do
        [[ -e "$f" ]] || continue
        cp "$f" "$vk_dest/vulkan-shaders/$(basename "$f")"
        spv_count=$((spv_count + 1))
    done
    if [[ "$spv_count" -eq 0 ]]; then
        echo "vendor-llama-cpp.sh: FATAL: no compiled .spv files found under $spv_dir -- upstream's CMake output layout may have changed" >&2
        exit 1
    fi

    local gen_bin
    gen_bin="$(find "$vk_build" -type f -name 'vulkan-shaders-gen' -perm -u+x 2>/dev/null | head -1)"
    if [[ -z "$gen_bin" ]]; then
        echo "vendor-llama-cpp.sh: FATAL: could not locate the built vulkan-shaders-gen tool binary under $vk_build" >&2
        exit 1
    fi
    local ground_truth_hpp="$WORK_DIR/ground-truth-ggml-vulkan-shaders.hpp"
    local scratch_spv_dir="$WORK_DIR/ground-truth-spv-scratch"
    mkdir -p "$scratch_spv_dir"
    "$gen_bin" --output-dir "$scratch_spv_dir" --target-hpp "$ground_truth_hpp"
    if [[ ! -s "$ground_truth_hpp" ]]; then
        echo "vendor-llama-cpp.sh: FATAL: aggregate-mode vulkan-shaders-gen invocation produced an empty/missing header at $ground_truth_hpp" >&2
        exit 1
    fi

    python3 "$ROOT_DIR/scripts/gen-vulkan-shader-runtime.py" \
        "$ground_truth_hpp" \
        "$vk_dest/ggml-vulkan-shaders.hpp" \
        "$vk_dest/ggml-vulkan-shaders.cpp"

    echo "vendor-llama-cpp.sh: vendored $spv_count compiled .spv shaders into $vk_dest/vulkan-shaders/, plus the generated runtime-loader header/cpp"
}
vendor_vulkan_backend

upstream_file_count=$(find "$UPSTREAM_DEST" -type f | wc -l | tr -d ' ')
upstream_size=$(du -sh "$UPSTREAM_DEST" | cut -f1)
echo "vendor-llama-cpp.sh: vendored $upstream_file_count files ($upstream_size) into $UPSTREAM_DEST"
echo "vendor-llama-cpp.sh: llama.cpp @ $ACTUAL_COMMIT"
