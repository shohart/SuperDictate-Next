// Model manifest (spec §7): the data-driven description of one installed
// ONNX model directory. The loader is deliberately strict — a model
// directory that does not exactly match its manifest is refused rather than
// half-loaded.
#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

#include "common.h"

namespace sdasr {

struct ManifestFile {
    std::string role;              // "encoder", "decoder", "joiner", "tokens", "preprocessor", ...
    std::filesystem::path path;    // resolved absolute path
    uint64_t size = 0;             // 0 = not declared (bundled assets)
    std::string sha256;            // lowercase hex, may be empty for bundled assets
    bool bundled = false;          // resolved against the assets directory
};

struct Manifest {
    int schema = 0;
    std::string model_id;
    std::string family;
    std::string revision;
    std::string license;
    std::string quantization;
    uint32_t sample_rate = 0;
    std::vector<std::string> languages;
    std::vector<std::string> providers;  // validated execution providers
    json capabilities = json::object();
    json params = json::object();
    std::map<std::string, ManifestFile> files;
    uint64_t total_bytes = 0;

    const ManifestFile &file(const std::string &role) const;
    bool has_capability(const std::string &name) const;
};

inline constexpr int kManifestSchema = 1;

// Known model families. A manifest naming anything else is refused with
// SD_ASR_UNSUPPORTED_MODEL_FAMILY.
bool is_supported_family(const std::string &family);
// Families that take text instead of audio (no sample_rate).
bool is_text_family(const std::string &family);

// Bundled roles a model works without ("hotword_tokenizer", spec
// asr-hotwords §5): when the asset is missing the role is left out of
// Manifest::files instead of refusing the manifest.
bool is_optional_bundled_role(const std::string &role);

// True for a plain file name: non-empty, no path separators, not "." or
// "..", no NUL, not absolute, no drive letter.
bool is_safe_file_name(const std::string &name);

// Parses and validates `<model_dir>/manifest.json`. Bundled assets are
// resolved in `assets_dir` (may be empty if the manifest has none).
// `verify_checksums` re-hashes every model file; bundled assets with a
// declared sha256 are always hashed (they are small).
Manifest load_manifest(const std::filesystem::path &model_dir,
                       const std::filesystem::path &assets_dir,
                       bool verify_checksums);

}  // namespace sdasr
