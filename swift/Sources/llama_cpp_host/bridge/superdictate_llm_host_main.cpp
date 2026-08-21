// SuperDictate — SuperDictateLLMHost
//
// A deliberately minimal, hand-authored OpenAI-compatible chat-completions
// HTTP host, built on the vendored llama.cpp core in
// swift/Sources/llama_cpp_host/upstream/ (see scripts/vendor-llama-cpp.sh
// for exactly what is and is not vendored, and why this is NOT a vendor of
// upstream's own tools/server).
//
// This is its own SPM executableTarget, never linked into the Parakey
// executable (see that target's own comment in swift/Package.swift for why:
// this process vendors its own independent copy of ggml, and two
// independently-vendored copies of ggml's C symbols cannot be statically
// linked into one executable). Parakey spawns this binary as a subprocess
// and talks to it over loopback HTTP, using the exact same
// OpenAICompatibleClient.swift code path used for a user-supplied custom
// OpenAI-compatible baseURL -- this binary's whole reason to exist is to be
// indistinguishable, from that client's point of view, from a real
// OpenAI-compatible server.
//
// Deliberately out of scope for this minimal host (all real llama-server
// features SuperDictate does not need): streaming responses, multimodal
// (mtmd), tool calls, a bundled web UI, multi-request concurrency (a single
// global mutex serializes every /v1/chat/completions call -- this app only
// ever has one dictation in flight at a time), and model auto-download
// (the model path is always supplied by the caller; see ModelDownload.swift
// for why the app itself owns fetching model weights, on demand, the same
// way it already does for the Parakeet ASR model).
//
// Not part of the vendor tree — hand-authored, never touched by
// scripts/vendor-llama-cpp.sh.

#include "common.h"
#include "chat.h"
#include "sampling.h"
#include "llama.h"

#include "httplib.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Not "json" -- common/chat.h already defines that alias (to
// nlohmann::ordered_json) at global scope, and both headers end up in this
// translation unit.
using sdlh_json = nlohmann::json;

namespace {

struct HostConfig {
    std::string model_path;
    std::string host = "127.0.0.1";
    int         port = 0;
    int32_t     n_ctx = 4096;
    int32_t     n_threads = 0; // 0 == auto (hardware_concurrency)
    // 0 = CPU only, >0 = offload that many layers to the first non-CPU
    // ggml backend (Vulkan, when this build was compiled with
    // GGML_USE_VULKAN). Driven by the SAME Settings.useGPU toggle the
    // Swift side already uses for Parakeet (LLMHostProcess.swift) --
    // one user-facing "Use GPU" switch governs both models' backend.
    int32_t     n_gpu_layers = 0;
    // Optional GGUF LoRA adapter path (e.g. a GEC-specific fine-tune layer
    // on top of a vanilla base model -- see the atom's own §19-20
    // reference). Empty = no adapter.
    std::string lora_path;
    // Multiplier on top of the adapter GGUF's own adapter.lora.alpha/rank
    // scale (llama-adapter.h get_scale: scale = lora_scale * alpha / rank).
    // 1.0 = llama.cpp's own default (--lora). An rsLoRA-trained adapter
    // (PEFT use_rslora=true, effective scale alpha/sqrt(rank) instead of
    // alpha/rank) needs lora_scale = sqrt(rank) to reproduce its training
    // scale -- e.g. the bundled dictation-corrector adapter (rank 16,
    // alpha 80, rsLoRA) needs 4.0: 4.0 * 80/16 == 80/sqrt(16) == 20.0.
    float lora_scale = 1.0f;
};

bool parse_args(int argc, char ** argv, HostConfig & cfg, std::string & error) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto next = [&](const char * flag) -> const char * {
            if (i + 1 >= argc) {
                error = std::string("missing value for ") + flag;
                return nullptr;
            }
            return argv[++i];
        };
        if (arg == "--model") {
            const char * v = next("--model");
            if (!v) return false;
            cfg.model_path = v;
        } else if (arg == "--host") {
            const char * v = next("--host");
            if (!v) return false;
            cfg.host = v;
        } else if (arg == "--port") {
            const char * v = next("--port");
            if (!v) return false;
            cfg.port = std::atoi(v);
        } else if (arg == "--ctx-size" || arg == "-c") {
            const char * v = next("--ctx-size");
            if (!v) return false;
            cfg.n_ctx = std::atoi(v);
        } else if (arg == "--threads" || arg == "-t") {
            const char * v = next("--threads");
            if (!v) return false;
            cfg.n_threads = std::atoi(v);
        } else if (arg == "--gpu-layers" || arg == "-ngl") {
            const char * v = next("--gpu-layers");
            if (!v) return false;
            cfg.n_gpu_layers = std::atoi(v);
        } else if (arg == "--lora") {
            const char * v = next("--lora");
            if (!v) return false;
            cfg.lora_path = v;
        } else if (arg == "--lora-scale") {
            const char * v = next("--lora-scale");
            if (!v) return false;
            cfg.lora_scale = std::atof(v);
        } else {
            error = "unknown argument: " + arg;
            return false;
        }
    }
    if (cfg.model_path.empty()) {
        error = "--model is required";
        return false;
    }
    if (cfg.port <= 0) {
        error = "--port is required and must be > 0";
        return false;
    }
    return true;
}

std::string now_request_id() {
    static std::atomic<uint64_t> counter{0};
    uint64_t n = ++counter;
    char buf[64];
    std::snprintf(buf, sizeof(buf), "sdlh-%llu", static_cast<unsigned long long>(n));
    return buf;
}

// Defensive strip of a leading <think>...</think> block. Correct-mode
// callers always pass enable_thinking=false (see atom guidance this feature
// implements: GEC must never emit a reasoning block), but chat-template
// behavior for that flag is model-specific -- this is a cheap belt-and-
// braces net, not the primary mechanism.
std::string strip_leading_think_block(const std::string & text) {
    const std::string open_tag = "<think>";
    const std::string close_tag = "</think>";
    size_t start = text.find_first_not_of(" \t\r\n");
    if (start == std::string::npos || text.compare(start, open_tag.size(), open_tag) != 0) {
        return text;
    }
    size_t close = text.find(close_tag, start + open_tag.size());
    if (close == std::string::npos) {
        return text;
    }
    size_t rest = close + close_tag.size();
    rest = text.find_first_not_of(" \t\r\n", rest);
    return rest == std::string::npos ? std::string() : text.substr(rest);
}

struct GenerationResult {
    bool        ok = false;
    std::string error;
    std::string content;
    int32_t     prompt_tokens = 0;
    int32_t     completion_tokens = 0;
};

class LlmHost {
public:
    bool load(const HostConfig & cfg, std::string & error) {
        llama_backend_init();

        common_params params;
        // Our minimal common_params otherwise stays on common.h's own
        // default (fit_params = true), which calls common_fit_params() to
        // size buffers against "free device memory". On this model's
        // hybrid recurrent/SSM architecture (Gated Delta Net / DeepSeek V4
        // HC state sizing) that estimation overflowed to (size_t)-1 and
        // ggml_aligned_malloc tried to allocate SIZE_MAX bytes. We always
        // load one known local file on predictable hardware -- there is
        // nothing to "fit" here, so this is disabled outright rather than
        // chased into common_fit_params itself. (The actual SIZE_MAX crash
        // turned out to have a second, independent cause too --
        // cpuparams_batch.n_threads below -- fixed either way; fit_params
        // stays off since it's still correct for this app's "always one
        // known local file" model, and toggling it made no measurable
        // difference to generation speed when that was separately
        // investigated as a suspect.)
        params.fit_params = false;
        params.model.path = cfg.model_path;
        params.n_ctx = cfg.n_ctx;
        params.n_batch = std::min<int32_t>(2048, std::max<int32_t>(512, cfg.n_ctx));
        // 0 = CPU only (struct default is -1 = "auto", which would offload
        // to any compiled-in GPU backend unconditionally -- explicit 0
        // instead, so a caller that never passes --gpu-layers gets the
        // same CPU-only behavior this host always had, backend-registered-
        // but-unused Vulkan support notwithstanding).
        params.n_gpu_layers = cfg.n_gpu_layers;
        const int32_t resolved_threads =
            cfg.n_threads > 0 ? cfg.n_threads : static_cast<int32_t>(std::thread::hardware_concurrency());
        params.cpuparams.n_threads = resolved_threads;
        // common_cpu_params::n_threads defaults to -1 (common.h) and this
        // struct is otherwise left untouched here (we don't vendor
        // arg.cpp, which is what normally fills it in for the CLI's
        // --threads-batch). common_threadpools::init (common.cpp) computes
        // `sizeof(struct ggml_compute_state) * tpp->n_threads` for the
        // BATCH threadpool whenever its n_threads differs from the
        // foreground one (ggml_threadpool_params_match) -- left at -1,
        // that multiplication overflows to a ~SIZE_MAX allocation and
        // ggml_aligned_malloc aborts. Mirror the CLI's implicit default
        // (batch threads == regular threads unless told otherwise).
        params.cpuparams_batch.n_threads = resolved_threads;
        // Correction mode is always greedy (temperature <= 0 samples
        // greedily -- see common_params_sampling::temp's own doc comment).
        params.sampling.temp = 0.0f;
        params.sampling.n_probs = 0;

        if (!cfg.lora_path.empty()) {
            common_adapter_lora_info lora;
            lora.path = cfg.lora_path;
            lora.scale = cfg.lora_scale;
            params.lora_adapters.push_back(lora);
        }

        result_ = common_init_from_params(params, /*model_only=*/false);
        if (!result_ || result_->model() == nullptr || result_->context() == nullptr) {
            error = "failed to load model from '" + cfg.model_path + "'";
            return false;
        }

        model_ = result_->model();
        ctx_ = result_->context();
        vocab_ = llama_model_get_vocab(model_);
        sampler_ = result_->sampler(0);
        if (sampler_ == nullptr) {
            error = "failed to initialize sampler";
            return false;
        }

        templates_ = common_chat_templates_init(model_, /*chat_template_override=*/"");
        if (!templates_) {
            error = "failed to initialize chat templates";
            return false;
        }

        n_ctx_ = cfg.n_ctx;
        return true;
    }

    // Serialized: this app only ever has one dictation post-processing
    // request in flight, and llama_context state (the KV cache) is not
    // safe to touch from more than one thread at a time.
    GenerationResult generate(const std::vector<sdlh_json> & messages,
                              bool enable_thinking,
                              int32_t max_tokens) {
        std::lock_guard<std::mutex> lock(mutex_);
        GenerationResult out;

        std::vector<common_chat_msg> chat_msgs;
        chat_msgs.reserve(messages.size());
        for (const auto & m : messages) {
            common_chat_msg msg;
            msg.role = m.value("role", "user");
            msg.content = m.value("content", "");
            chat_msgs.push_back(std::move(msg));
        }
        if (chat_msgs.empty()) {
            out.error = "messages must not be empty";
            return out;
        }

        common_chat_templates_inputs inputs;
        inputs.messages = chat_msgs;
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = enable_thinking;
        inputs.reasoning_format = COMMON_REASONING_FORMAT_NONE;

        common_chat_params chat_params;
        try {
            chat_params = common_chat_templates_apply(templates_.get(), inputs);
        } catch (const std::exception & e) {
            out.error = std::string("chat template apply failed: ") + e.what();
            return out;
        }

        std::vector<llama_token> tokens =
            common_tokenize(vocab_, chat_params.prompt, /*add_special=*/true, /*parse_special=*/true);

        const int32_t max_new = std::max<int32_t>(1, std::min<int32_t>(max_tokens, n_ctx_ - static_cast<int32_t>(tokens.size()) - 8));
        if (static_cast<int32_t>(tokens.size()) >= n_ctx_ - 8) {
            out.error = "prompt too long for context size";
            return out;
        }

        // Reset KV cache + sampler state: each request is an independent,
        // stateless single-turn completion -- this process serves many
        // unrelated dictation segments over its lifetime, never a
        // multi-turn conversation.
        llama_memory_t mem = llama_get_memory(ctx_);
        llama_memory_seq_rm(mem, 0, -1, -1);
        common_sampler_reset(sampler_);

        int n_past = 0;
        if (!common_prompt_batch_decode(ctx_, tokens, static_cast<int>(tokens.size()), n_past,
                                        llama_n_batch(ctx_), "", false)) {
            out.error = "prompt decode failed";
            return out;
        }
        out.prompt_tokens = static_cast<int32_t>(tokens.size());

        std::string content;
        for (int32_t i = 0; i < max_new; ++i) {
            llama_token token = common_sampler_sample(sampler_, ctx_, -1);
            common_sampler_accept(sampler_, token, /*is_generated=*/true);

            if (llama_vocab_is_eog(vocab_, token)) {
                break;
            }
            content += common_token_to_piece(vocab_, token, /*special=*/false);
            out.completion_tokens++;

            llama_batch step = llama_batch_get_one(&token, 1);
            if (llama_decode(ctx_, step)) {
                out.error = "decode failed during generation";
                return out;
            }
            n_past++;
        }

        out.ok = true;
        out.content = strip_leading_think_block(content);
        return out;
    }

private:
    common_init_result_ptr    result_;
    llama_model *              model_ = nullptr;
    llama_context *            ctx_ = nullptr;
    const llama_vocab *        vocab_ = nullptr;
    common_sampler *           sampler_ = nullptr;
    common_chat_templates_ptr  templates_;
    int32_t                    n_ctx_ = 0;
    std::mutex                 mutex_;
};

sdlh_json make_error_json(const std::string & message) {
    sdlh_json j;
    j["error"]["message"] = message;
    return j;
}

} // namespace

int main(int argc, char ** argv) {
    HostConfig cfg;
    std::string arg_error;
    if (!parse_args(argc, argv, cfg, arg_error)) {
        std::fprintf(stderr, "superdictate-llm-host: %s\n", arg_error.c_str());
        std::fprintf(stderr, "usage: superdictate-llm-host --model <path.gguf> --port <port> "
                             "[--host 127.0.0.1] [--ctx-size 4096] [--threads N] [--gpu-layers N] "
                             "[--lora <path.gguf>] [--lora-scale N]\n");
        return 1;
    }

    LlmHost host;
    std::string load_error;
    std::fprintf(stderr, "superdictate-llm-host: loading model '%s' ...\n", cfg.model_path.c_str());
    if (!host.load(cfg, load_error)) {
        std::fprintf(stderr, "superdictate-llm-host: %s\n", load_error.c_str());
        return 1;
    }
    std::fprintf(stderr, "superdictate-llm-host: model loaded, listening on %s:%d\n",
                 cfg.host.c_str(), cfg.port);

    httplib::Server svr;

    svr.Get("/health", [](const httplib::Request &, httplib::Response & res) {
        res.set_content(sdlh_json{{"status", "ok"}}.dump(), "application/json");
    });

    svr.Post("/v1/chat/completions", [&host](const httplib::Request & req, httplib::Response & res) {
        sdlh_json body;
        try {
            body = sdlh_json::parse(req.body);
        } catch (const std::exception & e) {
            res.status = 400;
            res.set_content(make_error_json(std::string("invalid JSON body: ") + e.what()).dump(), "application/json");
            return;
        }

        if (!body.contains("messages") || !body["messages"].is_array() || body["messages"].empty()) {
            res.status = 400;
            res.set_content(make_error_json("'messages' must be a non-empty array").dump(), "application/json");
            return;
        }

        bool enable_thinking = false;
        if (body.contains("chat_template_kwargs") && body["chat_template_kwargs"].is_object()) {
            enable_thinking = body["chat_template_kwargs"].value("enable_thinking", false);
        }
        int32_t max_tokens = body.value("max_tokens", 512);
        if (max_tokens <= 0) {
            max_tokens = 512;
        }

        std::vector<sdlh_json> messages(body["messages"].begin(), body["messages"].end());
        GenerationResult gen = host.generate(messages, enable_thinking, max_tokens);
        if (!gen.ok) {
            res.status = 500;
            res.set_content(make_error_json(gen.error).dump(), "application/json");
            return;
        }

        sdlh_json resp;
        resp["id"] = now_request_id();
        resp["object"] = "chat.completion";
        resp["created"] = static_cast<int64_t>(std::time(nullptr));
        resp["model"] = body.value("model", "superdictate-llm-host");
        resp["choices"] = sdlh_json::array({ sdlh_json{
            {"index", 0},
            {"message", sdlh_json{{"role", "assistant"}, {"content", gen.content}}},
            {"finish_reason", "stop"},
        } });
        resp["usage"] = sdlh_json{
            {"prompt_tokens", gen.prompt_tokens},
            {"completion_tokens", gen.completion_tokens},
            {"total_tokens", gen.prompt_tokens + gen.completion_tokens},
        };
        res.set_content(resp.dump(), "application/json");
    });

    if (!svr.listen(cfg.host, cfg.port)) {
        std::fprintf(stderr, "superdictate-llm-host: failed to listen on %s:%d\n", cfg.host.c_str(), cfg.port);
        return 1;
    }
    return 0;
}
