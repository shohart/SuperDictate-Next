#include "ipc.h"

#include <cstring>

namespace sdasr::ipc {

namespace {

constexpr char kRequestMagic[4] = {'S', 'D', 'A', 'Q'};
constexpr char kResponseMagic[4] = {'S', 'D', 'A', 'R'};

template <typename T>
void put(uint8_t *&cursor, T value) {
    for (size_t i = 0; i < sizeof(T); ++i) *cursor++ = uint8_t(uint64_t(value) >> (8 * i));
}

template <typename T>
T get(const uint8_t *&cursor) {
    uint64_t value = 0;
    for (size_t i = 0; i < sizeof(T); ++i) value |= uint64_t(*cursor++) << (8 * i);
    return T(value);
}

}  // namespace

const char *describe(DecodeError error) {
    switch (error) {
        case DecodeError::None: return "ok";
        case DecodeError::BadMagic: return "bad frame magic";
        case DecodeError::BadVersion: return "unsupported frame version";
        case DecodeError::BadType: return "unknown message type";
        case DecodeError::JsonTooLarge: return "JSON payload exceeds limit";
        case DecodeError::PcmTooLarge: return "PCM payload exceeds limit";
        case DecodeError::PcmMisaligned: return "PCM payload is not a whole number of float32 samples";
        case DecodeError::PcmNotAllowed: return "PCM payload is only allowed on TRANSCRIBE";
    }
    return "unknown";
}

std::array<uint8_t, kRequestHeaderSize> encode_request_header(const RequestHeader &header) {
    std::array<uint8_t, kRequestHeaderSize> out{};
    std::memcpy(out.data(), kRequestMagic, 4);
    uint8_t *cursor = out.data() + 4;
    put<uint16_t>(cursor, header.version);
    put<uint16_t>(cursor, uint16_t(header.type));
    put<uint64_t>(cursor, header.request_id);
    put<uint32_t>(cursor, header.json_len);
    put<uint64_t>(cursor, header.pcm_bytes);
    return out;
}

std::array<uint8_t, kResponseHeaderSize> encode_response_header(const ResponseHeader &header) {
    std::array<uint8_t, kResponseHeaderSize> out{};
    std::memcpy(out.data(), kResponseMagic, 4);
    uint8_t *cursor = out.data() + 4;
    put<uint16_t>(cursor, header.version);
    put<uint16_t>(cursor, header.status);
    put<uint64_t>(cursor, header.request_id);
    put<uint32_t>(cursor, header.json_len);
    return out;
}

DecodeError decode_request_header(const uint8_t *bytes, RequestHeader &out) {
    const uint8_t *cursor = bytes + 4;
    out.version = get<uint16_t>(cursor);
    const uint16_t type = get<uint16_t>(cursor);
    out.request_id = get<uint64_t>(cursor);
    out.json_len = get<uint32_t>(cursor);
    out.pcm_bytes = get<uint64_t>(cursor);
    out.type = MessageType(type);

    if (std::memcmp(bytes, kRequestMagic, 4) != 0) return DecodeError::BadMagic;
    if (out.version != kVersion) return DecodeError::BadVersion;
    if (type < uint16_t(MessageType::Create) || type > uint16_t(MessageType::Punctuate)) return DecodeError::BadType;
    if (out.json_len > kMaxJsonBytes) return DecodeError::JsonTooLarge;
    if (out.pcm_bytes > kMaxPcmBytes) return DecodeError::PcmTooLarge;
    if (out.pcm_bytes % 4 != 0) return DecodeError::PcmMisaligned;
    if (out.pcm_bytes != 0 && out.type != MessageType::Transcribe) return DecodeError::PcmNotAllowed;
    return DecodeError::None;
}

DecodeError decode_response_header(const uint8_t *bytes, ResponseHeader &out) {
    const uint8_t *cursor = bytes + 4;
    out.version = get<uint16_t>(cursor);
    out.status = get<uint16_t>(cursor);
    out.request_id = get<uint64_t>(cursor);
    out.json_len = get<uint32_t>(cursor);
    if (std::memcmp(bytes, kResponseMagic, 4) != 0) return DecodeError::BadMagic;
    if (out.version != kVersion) return DecodeError::BadVersion;
    if (out.json_len > kMaxJsonBytes) return DecodeError::JsonTooLarge;
    return DecodeError::None;
}

bool read_exact(std::FILE *stream, void *buffer, size_t length) {
    uint8_t *cursor = static_cast<uint8_t *>(buffer);
    while (length > 0) {
        const size_t got = std::fread(cursor, 1, length, stream);
        if (got == 0) return false;  // EOF or error: the stream is unusable either way
        cursor += got;
        length -= got;
    }
    return true;
}

bool write_all(std::FILE *stream, const void *buffer, size_t length) {
    const uint8_t *cursor = static_cast<const uint8_t *>(buffer);
    while (length > 0) {
        const size_t put_bytes = std::fwrite(cursor, 1, length, stream);
        if (put_bytes == 0) return false;
        cursor += put_bytes;
        length -= put_bytes;
    }
    return true;
}

}  // namespace sdasr::ipc
