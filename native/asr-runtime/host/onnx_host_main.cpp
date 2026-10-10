// SuperDictateOnnxHost — one ONNX ASR model per process, driven over
// stdin/stdout with framed IPC v1 (src/ipc.h, spec §8).
//
// Threads: the main thread only reads frames, so CANCEL / STATUS stay
// responsive while a TRANSCRIBE runs on the single worker thread. Every
// response is written under one mutex. Lifetime: EOF on stdin, SHUTDOWN, or
// (POSIX) being re-parented all end the process — a crashed app never leaves
// an orphaned model-holding helper behind. A malformed frame ends the
// process too: after a framing error the byte stream cannot be trusted.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ipc.h"
#include "nlohmann/json.hpp"
#include "sd_asr.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

using nlohmann::json;
namespace ipc = sdasr::ipc;

namespace {

std::mutex g_write_mutex;

void log_line(const std::string &message) {
    std::fprintf(stderr, "SuperDictateOnnxHost: %s\n", message.c_str());
    std::fflush(stderr);
}

// Returns false when stdout is gone (parent died); callers then exit.
bool respond(uint64_t request_id, sd_asr_status status, const std::string &body) {
    std::lock_guard<std::mutex> lock(g_write_mutex);
    ipc::ResponseHeader header;
    header.status = uint16_t(status);
    header.request_id = request_id;
    header.json_len = uint32_t(body.size());
    const auto bytes = ipc::encode_response_header(header);
    const bool ok = ipc::write_all(stdout, bytes.data(), bytes.size()) &&
                    ipc::write_all(stdout, body.data(), body.size()) && std::fflush(stdout) == 0;
    return ok;
}

std::string error_body(sd_asr_status status, const std::string &message) {
    return json{{"category", sd_asr_status_name(status)}, {"message", message}}.dump();
}

std::string take(char *buffer) {
    std::string out = buffer ? buffer : "";
    sd_asr_free(buffer);
    return out;
}

struct HostState {
    sd_asr_handle *handle = nullptr;
    std::thread worker;
    std::atomic<bool> worker_running{false};

    void join_worker() {
        if (worker.joinable()) worker.join();
    }

    void stop() {
        if (handle && worker_running.load()) sd_asr_cancel(handle, "*");
        join_worker();
        if (handle) {
            sd_asr_destroy(handle);
            handle = nullptr;
        }
    }
};

#ifndef _WIN32
void start_parent_watchdog() {
    const pid_t original_parent = getppid();
    std::thread([original_parent] {
        for (;;) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            if (getppid() != original_parent) {
                log_line("parent process went away; exiting");
                std::_Exit(0);
            }
        }
    }).detach();
}
#endif

}  // namespace

int main() {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#else
    start_parent_watchdog();
#endif
    if (sd_asr_api_version() != SD_ASR_API_VERSION) {
        log_line("sd_asr API version mismatch");
        return 3;
    }

    HostState state;
    std::vector<uint8_t> header_bytes(ipc::kRequestHeaderSize);
    for (;;) {
        if (!ipc::read_exact(stdin, header_bytes.data(), header_bytes.size())) {
            state.stop();  // EOF: the parent closed our stdin or died
            return 0;
        }
        ipc::RequestHeader header;
        const ipc::DecodeError decode = ipc::decode_request_header(header_bytes.data(), header);
        if (decode != ipc::DecodeError::None) {
            log_line(std::string("framing error: ") + ipc::describe(decode));
            respond(header.request_id, SD_ASR_INVALID_ARGUMENT, error_body(SD_ASR_INVALID_ARGUMENT, ipc::describe(decode)));
            state.stop();
            return 2;
        }

        std::string body(header.json_len, '\0');
        if (header.json_len && !ipc::read_exact(stdin, body.data(), body.size())) {
            state.stop();
            return 0;
        }
        std::vector<float> pcm;
        if (header.pcm_bytes) {
            pcm.resize(size_t(header.pcm_bytes / 4));
            if (!ipc::read_exact(stdin, pcm.data(), size_t(header.pcm_bytes))) {
                state.stop();
                return 0;
            }
        }

        switch (header.type) {
            case ipc::MessageType::Create: {
                if (state.handle) {
                    respond(header.request_id, SD_ASR_INVALID_ARGUMENT,
                            error_body(SD_ASR_INVALID_ARGUMENT, "a model is already loaded in this host"));
                    break;
                }
                char *error = nullptr;
                const sd_asr_status status = sd_asr_create(body.c_str(), &state.handle, &error);
                if (status != SD_ASR_OK) {
                    respond(header.request_id, status, take(error));
                } else {
                    char *status_json = nullptr;
                    sd_asr_get_status(state.handle, &status_json);
                    respond(header.request_id, SD_ASR_OK, take(status_json));
                }
                break;
            }
            case ipc::MessageType::Transcribe: {
                if (!state.handle) {
                    respond(header.request_id, SD_ASR_INVALID_ARGUMENT,
                            error_body(SD_ASR_INVALID_ARGUMENT, "no model loaded (send CREATE first)"));
                    break;
                }
                if (state.worker_running.load()) {
                    respond(header.request_id, SD_ASR_BUSY,
                            error_body(SD_ASR_BUSY, "another transcription is running"));
                    break;
                }
                json options = body.empty() ? json::object() : json::parse(body, nullptr, false);
                if (!options.is_object()) {
                    respond(header.request_id, SD_ASR_INVALID_ARGUMENT,
                            error_body(SD_ASR_INVALID_ARGUMENT, "options are not a JSON object"));
                    break;
                }
                options["request_id"] = std::to_string(header.request_id);
                uint32_t sample_rate = 16000;
                if (auto it = options.find("sample_rate"); it != options.end() && it->is_number_unsigned()) {
                    sample_rate = it->get<uint32_t>();
                }
                state.join_worker();
                state.worker_running.store(true);
                state.worker = std::thread([&state, id = header.request_id, samples = std::move(pcm),
                                            options_text = options.dump(), sample_rate] {
                    char *result = nullptr;
                    char *error = nullptr;
                    const sd_asr_status status = sd_asr_transcribe_pcm_f32(
                        state.handle, samples.data(), samples.size(), sample_rate, options_text.c_str(), &result, &error);
                    state.worker_running.store(false);
                    const std::string response = status == SD_ASR_OK ? take(result) : take(error);
                    sd_asr_free(status == SD_ASR_OK ? error : result);  // the other one is NULL; belt and braces
                    if (!respond(id, status, response)) {
                        log_line("stdout closed; exiting");
                        std::_Exit(0);
                    }
                });
                break;
            }
            case ipc::MessageType::Status: {
                if (!state.handle) {
                    respond(header.request_id, SD_ASR_OK, json{{"state", "empty"}, {"api_version", SD_ASR_API_VERSION}}.dump());
                    break;
                }
                char *status_json = nullptr;
                const sd_asr_status status = sd_asr_get_status(state.handle, &status_json);
                respond(header.request_id, status, take(status_json));
                break;
            }
            case ipc::MessageType::Cancel: {
                // Body {"target": <request id>} names the request to cancel; the
                // CANCEL frame's own request_id only correlates this ack.
                const json request = body.empty() ? json::object() : json::parse(body, nullptr, false);
                std::string target = "*";
                if (request.is_object()) {
                    if (auto it = request.find("target"); it != request.end() && it->is_number_unsigned()) {
                        target = std::to_string(it->get<uint64_t>());
                    }
                }
                const sd_asr_status status =
                    state.handle ? sd_asr_cancel(state.handle, target.c_str()) : SD_ASR_INVALID_ARGUMENT;
                respond(header.request_id, status,
                        status == SD_ASR_OK ? json{{"cancelled", target}}.dump()
                                            : error_body(status, "no running request " + target));
                break;
            }
            case ipc::MessageType::Shutdown: {
                state.stop();
                respond(header.request_id, SD_ASR_OK, "{}");
                return 0;
            }
        }
    }
}
