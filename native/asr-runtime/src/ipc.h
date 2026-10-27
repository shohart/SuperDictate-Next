// Framed IPC v1 between the app and SuperDictateOnnxHost (spec §8).
// All integers little-endian.
//
//   request : "SDAQ" | u16 version | u16 type | u64 request_id | u32 json_len | u64 pcm_bytes | json | pcm f32
//   response: "SDAR" | u16 version | u16 status | u64 request_id | u32 json_len | json
//
// Deliberately NOT the unversioned Whisper helper framing.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace sdasr::ipc {

inline constexpr uint16_t kVersion = 1;
inline constexpr size_t kRequestHeaderSize = 28;
inline constexpr size_t kResponseHeaderSize = 20;
inline constexpr uint32_t kMaxJsonBytes = 1u << 20;
inline constexpr uint64_t kMaxPcmBytes = 30ull * 60ull * 16000ull * 4ull;

enum class MessageType : uint16_t {
    Create = 1,
    Transcribe = 2,
    Status = 3,
    Cancel = 4,
    Shutdown = 5,
    Punctuate = 6,  // body {"text": "..."}, no PCM
};

struct RequestHeader {
    uint16_t version = kVersion;
    MessageType type = MessageType::Status;
    uint64_t request_id = 0;
    uint32_t json_len = 0;
    uint64_t pcm_bytes = 0;
};

struct ResponseHeader {
    uint16_t version = kVersion;
    uint16_t status = 0;  // sd_asr_status
    uint64_t request_id = 0;
    uint32_t json_len = 0;
};

enum class DecodeError {
    None,
    BadMagic,
    BadVersion,
    BadType,
    JsonTooLarge,
    PcmTooLarge,
    PcmMisaligned,
    PcmNotAllowed,
};

const char *describe(DecodeError error);

std::array<uint8_t, kRequestHeaderSize> encode_request_header(const RequestHeader &header);
std::array<uint8_t, kResponseHeaderSize> encode_response_header(const ResponseHeader &header);

// `bytes` must hold exactly kRequestHeaderSize / kResponseHeaderSize bytes.
// request_id is decoded even when validation fails, so the error response
// can echo it.
DecodeError decode_request_header(const uint8_t *bytes, RequestHeader &out);
DecodeError decode_response_header(const uint8_t *bytes, ResponseHeader &out);

// Exact-length stream I/O. read_exact returns false on EOF or error
// (including a short read); write_all returns false on error.
bool read_exact(std::FILE *stream, void *buffer, size_t length);
bool write_all(std::FILE *stream, const void *buffer, size_t length);

}  // namespace sdasr::ipc
