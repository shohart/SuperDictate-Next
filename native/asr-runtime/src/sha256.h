// Minimal streaming SHA-256 (FIPS 180-4), used to verify model files when
// `verify_checksums` is requested and to verify bundled assets.
#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>

namespace sdasr {

class Sha256 {
public:
    Sha256();
    void update(const void *data, size_t length);
    std::string hex_digest();  // finalizes; the object must not be reused

private:
    void transform(const uint8_t block[64]);
    uint32_t state_[8];
    uint8_t buffer_[64];
    uint64_t total_bytes_ = 0;
    size_t buffered_ = 0;
};

// Lowercase hex SHA-256 of a file's contents. Throws std::runtime_error on
// I/O failure.
std::string sha256_file(const std::filesystem::path &path);

}  // namespace sdasr
