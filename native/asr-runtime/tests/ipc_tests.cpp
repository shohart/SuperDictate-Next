// Framing v1 unit tests (spec §8).
#include <cstdio>
#include <cstring>

#include "ipc.h"
#include "test_util.h"

namespace ipc = sdasr::ipc;

TEST_CASE("request header round-trip") {
    ipc::RequestHeader in;
    in.type = ipc::MessageType::Transcribe;
    in.request_id = 0x0102030405060708ull;
    in.json_len = 17;
    in.pcm_bytes = 64000;
    const auto bytes = ipc::encode_request_header(in);
    CHECK_EQ(std::memcmp(bytes.data(), "SDAQ", 4), 0);
    CHECK_EQ(bytes[8], uint8_t(0x08));  // little-endian request id
    ipc::RequestHeader out;
    CHECK(ipc::decode_request_header(bytes.data(), out) == ipc::DecodeError::None);
    CHECK(out.type == ipc::MessageType::Transcribe);
    CHECK_EQ(out.request_id, in.request_id);
    CHECK_EQ(out.json_len, 17u);
    CHECK_EQ(out.pcm_bytes, 64000ull);
}

TEST_CASE("response header round-trip") {
    ipc::ResponseHeader in;
    in.status = 8;
    in.request_id = 99;
    in.json_len = 1234;
    const auto bytes = ipc::encode_response_header(in);
    ipc::ResponseHeader out;
    CHECK(ipc::decode_response_header(bytes.data(), out) == ipc::DecodeError::None);
    CHECK_EQ(out.status, uint16_t(8));
    CHECK_EQ(out.request_id, 99ull);
    CHECK_EQ(out.json_len, 1234u);
}

TEST_CASE("request header validation") {
    auto decode = [](ipc::RequestHeader header, const char *magic = nullptr) {
        auto bytes = ipc::encode_request_header(header);
        if (magic) std::memcpy(bytes.data(), magic, 4);
        ipc::RequestHeader out;
        return ipc::decode_request_header(bytes.data(), out);
    };
    ipc::RequestHeader ok;
    ok.type = ipc::MessageType::Status;
    CHECK(decode(ok, "SDAR") == ipc::DecodeError::BadMagic);
    ipc::RequestHeader v = ok;
    v.version = 2;
    CHECK(decode(v) == ipc::DecodeError::BadVersion);
    ipc::RequestHeader t = ok;
    t.type = ipc::MessageType(9);
    CHECK(decode(t) == ipc::DecodeError::BadType);
    ipc::RequestHeader j = ok;
    j.json_len = ipc::kMaxJsonBytes + 1;
    CHECK(decode(j) == ipc::DecodeError::JsonTooLarge);
    ipc::RequestHeader p = ok;
    p.type = ipc::MessageType::Transcribe;
    p.pcm_bytes = ipc::kMaxPcmBytes + 4;
    CHECK(decode(p) == ipc::DecodeError::PcmTooLarge);
    p.pcm_bytes = 6;
    CHECK(decode(p) == ipc::DecodeError::PcmMisaligned);
    ipc::RequestHeader s = ok;
    s.pcm_bytes = 4;
    CHECK(decode(s) == ipc::DecodeError::PcmNotAllowed);
}

TEST_CASE("exact reads detect EOF and short frames") {
    std::FILE *file = std::tmpfile();
    CHECK(file != nullptr);
    if (!file) return;
    const char payload[] = "abcdef";
    CHECK(ipc::write_all(file, payload, 6));
    std::rewind(file);
    char buffer[8] = {};
    CHECK(ipc::read_exact(file, buffer, 4));
    CHECK_EQ(std::memcmp(buffer, "abcd", 4), 0);
    CHECK(!ipc::read_exact(file, buffer, 4));  // only 2 bytes remain
    std::fclose(file);
}

int main() { return sdtest::run_all(); }
