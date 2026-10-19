#include "manifest.h"

#include <fstream>
#include <sstream>

#include "sha256.h"

namespace fs = std::filesystem;

namespace sdasr {

namespace {

constexpr uint64_t kMaxManifestBytes = 1 << 20;

[[noreturn]] void invalid(const std::string &message) {
    throw Error(SD_ASR_INVALID_MODEL, message);
}

std::string required_string(const json &object, const char *key) {
    auto it = object.find(key);
    if (it == object.end() || !it->is_string() || it->get<std::string>().empty()) {
        invalid(std::string("manifest: missing or empty string field '") + key + "'");
    }
    return it->get<std::string>();
}

std::string optional_string(const json &object, const char *key) {
    auto it = object.find(key);
    return (it != object.end() && it->is_string()) ? it->get<std::string>() : std::string();
}

std::vector<std::string> string_array(const json &object, const char *key) {
    std::vector<std::string> out;
    auto it = object.find(key);
    if (it == object.end()) return out;
    if (!it->is_array()) invalid(std::string("manifest: '") + key + "' must be an array");
    for (const auto &value : *it) {
        if (!value.is_string()) invalid(std::string("manifest: '") + key + "' must contain strings");
        out.push_back(value.get<std::string>());
    }
    return out;
}

bool is_lower_hex_sha256(const std::string &value) {
    if (value.size() != 64) return false;
    for (char c : value) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

// A model file must be a regular file reached without following a symlink
// at the final component (symlinks are rejected outright, spec §7).
void require_regular_file(const fs::path &path, const std::string &role) {
    std::error_code ec;
    fs::file_status status = fs::symlink_status(path, ec);
    if (ec || status.type() == fs::file_type::not_found) {
        invalid("manifest: file for '" + role + "' is missing: " + path.u8string());
    }
    if (status.type() == fs::file_type::symlink) {
        invalid("manifest: file for '" + role + "' is a symlink, refusing: " + path.u8string());
    }
    if (status.type() != fs::file_type::regular) {
        invalid("manifest: file for '" + role + "' is not a regular file: " + path.u8string());
    }
}

}  // namespace

const ManifestFile &Manifest::file(const std::string &role) const {
    auto it = files.find(role);
    if (it == files.end()) invalid("manifest: model family '" + family + "' requires file role '" + role + "'");
    return it->second;
}

bool Manifest::has_capability(const std::string &name) const {
    auto it = capabilities.find(name);
    return it != capabilities.end() && it->is_boolean() && it->get<bool>();
}

bool is_supported_family(const std::string &family) {
    return family == "nemo_tdt" || family == "gigaam_rnnt";
}

bool is_safe_file_name(const std::string &name) {
    if (name.empty() || name == "." || name == "..") return false;
    for (char c : name) {
        if (c == '/' || c == '\\' || c == '\0' || c == ':') return false;
    }
    return true;
}

Manifest load_manifest(const fs::path &model_dir, const fs::path &assets_dir, bool verify_checksums) {
    if (model_dir.empty()) invalid("config: model_directory is empty");
    std::error_code ec;
    if (!fs::is_directory(model_dir, ec)) invalid("model directory does not exist: " + model_dir.u8string());

    const fs::path manifest_path = model_dir / "manifest.json";
    require_regular_file(manifest_path, "manifest");
    if (fs::file_size(manifest_path, ec) > kMaxManifestBytes) invalid("manifest.json is unreasonably large");

    json document;
    {
        std::ifstream in(manifest_path, std::ios::binary);
        std::stringstream buffer;
        buffer << in.rdbuf();
        document = json::parse(buffer.str(), nullptr, /*allow_exceptions=*/false);
    }
    if (!document.is_object()) invalid("manifest.json is not a JSON object");

    Manifest manifest;
    auto schema = document.find("schema");
    if (schema == document.end() || !schema->is_number_integer()) invalid("manifest: missing integer 'schema'");
    manifest.schema = schema->get<int>();
    if (manifest.schema != kManifestSchema) {
        invalid("manifest: unsupported schema " + std::to_string(manifest.schema));
    }
    manifest.model_id = required_string(document, "model_id");
    manifest.family = required_string(document, "family");
    if (!is_supported_family(manifest.family)) {
        throw Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY, "unsupported model family '" + manifest.family + "'");
    }
    manifest.revision = optional_string(document, "revision");
    manifest.license = optional_string(document, "license");
    manifest.quantization = optional_string(document, "quantization");
    auto rate = document.find("sample_rate");
    if (rate == document.end() || !rate->is_number_unsigned() || rate->get<uint64_t>() == 0 ||
        rate->get<uint64_t>() > 192000) {
        invalid("manifest: missing or invalid 'sample_rate'");
    }
    manifest.sample_rate = rate->get<uint32_t>();
    manifest.languages = string_array(document, "languages");
    manifest.providers = string_array(document, "providers");
    if (manifest.providers.empty()) manifest.providers.push_back("cpu");
    if (auto caps = document.find("capabilities"); caps != document.end()) {
        if (!caps->is_object()) invalid("manifest: 'capabilities' must be an object");
        manifest.capabilities = *caps;
    }
    if (auto params = document.find("params"); params != document.end()) {
        if (!params->is_object()) invalid("manifest: 'params' must be an object");
        manifest.params = *params;
    }

    auto files = document.find("files");
    if (files == document.end() || !files->is_object() || files->empty()) invalid("manifest: missing 'files'");
    for (auto it = files->begin(); it != files->end(); ++it) {
        const std::string role = it.key();
        const json &entry = it.value();
        if (!entry.is_object()) invalid("manifest: file entry '" + role + "' must be an object");

        ManifestFile file;
        file.role = role;
        const std::string bundled = optional_string(entry, "bundled");
        const std::string relative = optional_string(entry, "path");
        if (bundled.empty() == relative.empty()) {
            invalid("manifest: file entry '" + role + "' needs exactly one of 'path' or 'bundled'");
        }
        const std::string &name = bundled.empty() ? relative : bundled;
        if (!is_safe_file_name(name)) invalid("manifest: unsafe file name for '" + role + "': " + name);

        file.sha256 = optional_string(entry, "sha256");
        if (!file.sha256.empty() && !is_lower_hex_sha256(file.sha256)) {
            invalid("manifest: malformed sha256 for '" + role + "'");
        }
        if (auto size = entry.find("size"); size != entry.end()) {
            if (!size->is_number_unsigned()) invalid("manifest: 'size' for '" + role + "' must be unsigned");
            file.size = size->get<uint64_t>();
        }

        if (!bundled.empty()) {
            if (assets_dir.empty()) invalid("manifest: '" + role + "' is bundled but no assets_directory was configured");
            file.bundled = true;
            file.path = assets_dir / fs::u8path(name);
        } else {
            if (file.size == 0) invalid("manifest: model file '" + role + "' must declare its size");
            if (file.sha256.empty()) invalid("manifest: model file '" + role + "' must declare its sha256");
            file.path = model_dir / fs::u8path(name);
        }

        require_regular_file(file.path, role);
        const uint64_t actual_size = fs::file_size(file.path, ec);
        if (ec) invalid("manifest: cannot stat '" + role + "'");
        if (file.size != 0 && actual_size != file.size) {
            invalid("manifest: size mismatch for '" + role + "' (expected " + std::to_string(file.size) +
                    ", found " + std::to_string(actual_size) + ")");
        }
        if (!file.sha256.empty() && (verify_checksums || file.bundled)) {
            std::string actual;
            try {
                actual = sha256_file(file.path);
            } catch (const std::exception &e) {
                invalid(std::string("manifest: cannot hash '") + role + "': " + e.what());
            }
            if (actual != file.sha256) invalid("manifest: sha256 mismatch for '" + role + "'");
        }
        manifest.total_bytes += actual_size;
        manifest.files.emplace(role, std::move(file));
    }
    return manifest;
}

}  // namespace sdasr
