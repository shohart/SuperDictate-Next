// Implementation of the runtime SPIR-V loader declared in
// ggml-vulkan-shaders-runtime.h. See that header for the full design
// rationale; this file only has the base-path resolution + the
// load-once-and-cache logic that ggml_vk_shaders_detail::get_data/get_len
// (used by every lazy_data/lazy_len proxy in the generated
// ggml-vulkan-shaders.cpp) call into.
//
// Deliberately plain C++17 stdlib only (<fstream>/<mutex>/...) — no Vulkan,
// no Foundation/AppKit, no Objective-C++. Path resolution is entirely
// string-based, matching this codebase's existing convention of Swift
// resolving bundle paths and handing plain C strings down into the
// parakeet_cpp C API (ParakeetEngine.swift -> modelPath ->
// sd_parakeet_create) rather than having vendored C++ code query
// NSBundle/CFBundle itself. Ported unmodified (only doc-comment paths
// changed) from this fork's proven whisper_cpp Vulkan runtime loader
// (commit b0ab800).
#include "ggml-vulkan-shaders-runtime.h"

#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

// Guards g_configured_dir, g_dir_resolved/g_resolved_dir, and g_cache. Shader
// loading isn't hot-path (each distinct shader loads once, ever, then
// serves from cache), so one coarse mutex is simpler than trying to make
// this lock-free and is not worth optimizing further.
std::mutex g_mutex;

// Set by ggml_vk_shaders_set_directory(); empty means "not configured".
std::string g_configured_dir;

// Resolved lazily on first shader load (see resolve_dir_locked below), not
// eagerly at static-init time: static initializers run before Swift gets a
// chance to call ggml_vk_shaders_set_directory(), so resolving too early
// would always fall through to the source-relative dev fallback even in a
// shipped .app.
bool        g_dir_resolved = false;
std::string g_resolved_dir;

struct loaded_shader {
    std::vector<uint8_t> bytes;
};

std::unordered_map<std::string, loaded_shader> g_cache;

// swift/Sources/parakeet_cpp/upstream/ggml-vulkan/ggml-vulkan-shaders-runtime.cpp
// (this file) sits directly alongside
// swift/Sources/parakeet_cpp/upstream/ggml-vulkan/vulkan-shaders/ in the
// vendored source tree, so deriving the dev-build fallback from this
// translation unit's own __FILE__ (the absolute path on the machine that
// compiled it) finds the real shader corpus without any configuration —
// used by `swift build`/`swift run` before an .app bundle (and therefore a
// Contents/Resources/vulkan-shaders/ to configure via
// ggml_vk_shaders_set_directory) exists.
std::string source_relative_shader_dir() {
    std::string this_file = __FILE__;
    size_t slash = this_file.find_last_of('/');
    if (slash == std::string::npos) {
        // __FILE__ had no directory component at all (a build system that
        // invokes the compiler with a bare relative filename instead of an
        // absolute path — SwiftPM normally does not do this, but fall back
        // to a plain relative lookup rather than giving up outright, in
        // case the process's cwd happens to already be
        // swift/Sources/parakeet_cpp/upstream/ggml-vulkan/).
        return "vulkan-shaders";
    }
    return this_file.substr(0, slash) + "/vulkan-shaders";
}

// Must be called with g_mutex already held.
const std::string & resolve_dir_locked() {
    if (g_dir_resolved) {
        return g_resolved_dir;
    }
    // SUPERDICTATE_VULKAN_SHADER_DIR wins even over an explicitly
    // configured directory: it exists specifically so a developer can
    // redirect a *real, already-configured* shipped app at an alternate
    // shader corpus for debugging (e.g. a locally rebuilt .spv, or a
    // corpus with debug info) without rebuilding — the one scenario where
    // ggml_vk_shaders_set_directory() has already run and a lower-priority
    // env var would otherwise be permanently unreachable for the rest of
    // the process's lifetime.
    if (const char * env = std::getenv("SUPERDICTATE_VULKAN_SHADER_DIR")) {
        g_resolved_dir = env;
    } else if (!g_configured_dir.empty()) {
        g_resolved_dir = g_configured_dir;
    } else {
        g_resolved_dir = source_relative_shader_dir();
    }
    g_dir_resolved = true;
    return g_resolved_dir;
}

// Must be called with g_mutex already held.
const loaded_shader & load_locked(const std::string & name) {
    auto it = g_cache.find(name);
    if (it != g_cache.end()) {
        return it->second;
    }

    loaded_shader shader;
    const std::string & dir = resolve_dir_locked();
    std::string path = dir.empty() ? std::string() : (dir + "/" + name + ".spv");
    bool loaded = false;
    if (!dir.empty()) {
        std::ifstream file(path, std::ios::binary | std::ios::ate);
        if (file) {
            std::streamsize size = file.tellg();
            if (size > 0) {
                file.seekg(0, std::ios::beg);
                shader.bytes.resize(static_cast<size_t>(size));
                if (file.read(reinterpret_cast<char *>(shader.bytes.data()), size)) {
                    loaded = true;
                } else {
                    shader.bytes.clear();
                }
            }
        }
    }
    if (!loaded) {
        // Not just a debugging nicety: a missing/misconfigured shader
        // directory means EVERY shader silently resolves to a null pointer
        // + zero length, which flows straight into
        // vk::ShaderModuleCreateInfo for every shader with no guarantee
        // Vulkan validation layers are even enabled to catch it (they
        // normally aren't in a shipped app) — so this is the only
        // diagnostic standing between "GPU transcription silently falls
        // back to garbage/crashes" and a log line pointing at exactly which
        // path was tried.
        if (dir.empty()) {
            std::fprintf(stderr,
                "ggml-vulkan: failed to load SPIR-V shader '%s.spv' — no shader "
                "directory configured (see ggml_vk_shaders_set_directory) and "
                "no fallback resolved\n", name.c_str());
        } else {
            std::fprintf(stderr, "ggml-vulkan: failed to load SPIR-V shader '%s'\n",
                          path.c_str());
        }
    }

    // emplace + re-lookup (rather than trusting the iterator from a prior
    // find that could have been invalidated) — insertion into
    // unordered_map only invalidates iterators, not references to other
    // elements, but re-finding here keeps this function trivially correct
    // regardless of how it's refactored later.
    auto result = g_cache.emplace(name, std::move(shader));
    return result.first->second;
}

} // namespace

void ggml_vk_shaders_set_directory(const char * dir) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_configured_dir = dir ? dir : "";
    // Re-resolve on next load: a caller invoking this after some shaders
    // already loaded under the old/fallback directory is a misuse (see the
    // header's "must be called before the first Vulkan pipeline is
    // created" contract), but don't compound that mistake by ignoring the
    // update either.
    g_dir_resolved = false;
}

namespace ggml_vk_shaders_detail {

const void * get_data(const char * name) {
    std::lock_guard<std::mutex> lock(g_mutex);
    // Bind the std::string conversion to a named local first: load_locked's
    // returned reference points into g_cache's long-lived storage, not into
    // the converted argument, but binding the conversion directly to the
    // `const loaded_shader &` result trips -Wdangling-reference's (overly
    // conservative here) heuristic.
    std::string key = name;
    const loaded_shader & shader = load_locked(key);
    return shader.bytes.empty() ? nullptr : static_cast<const void *>(shader.bytes.data());
}

uint64_t get_len(const char * name) {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::string key = name;
    const loaded_shader & shader = load_locked(key);
    return static_cast<uint64_t>(shader.bytes.size());
}

} // namespace ggml_vk_shaders_detail
