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

#include "ggml-vulkan-shaders-runtime.h"
#include "httplib.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cmath>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <tlhelp32.h>
#else
#include <unistd.h>
#include <climits>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#endif

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
    int32_t     n_threads = 0; // 0 == auto (physical cores)
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
    std::string chat_template_override;
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
        } else if (arg == "--chat-template-file") {
            const char * v = next("--chat-template-file");
            if (!v) return false;
            std::ifstream in(v, std::ios::binary);
            if (!in) {
                error = std::string("cannot read chat template file: ") + v;
                return false;
            }
            std::ostringstream ss;
            ss << in.rdbuf();
            cfg.chat_template_override = ss.str();
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
    // The compute backend produced NaN/Inf logits. A broken GPU path (seen
    // with MoltenVK on a Radeon Instinct MI50) does this on every request;
    // the app answers by moving the model to the CPU, so it is reported as
    // its own status instead of a generic failure -- and instead of letting
    // llama_sampler_dist_apply's assertion abort the whole process.
    bool        numeric_failure = false;
    std::string error;
    std::string content;
    int32_t     prompt_tokens = 0;
    int32_t     prompt_tokens_reused = 0;   // restored from the prefix snapshot
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
        if (cfg.n_gpu_layers == 0) {
            // CPU-only must mean no GPU at all. With zero layers offloaded,
            // llama.cpp still sends large batches (the whole prompt) to any
            // compiled-in GPU backend ("op offload") -- a 688 MiB Vulkan
            // compute buffer was allocated for it with --gpu-layers 0, and
            // prompts ran on the GPU. That defeats the CPU fallback for a
            // GPU that computes wrong (NaN logits from MoltenVK on a Radeon
            // Instinct MI50 / Vega 20) and made a Windows run with an
            // integrated GPU minutes slower. An empty device list keeps the
            // GPU out of the model, and no_op_offload out of the context.
            params.devices = { nullptr };
            params.no_op_offload = true;
        }
        // Auto = physical cores (on Apple silicon: performance cores). A
        // second hyperthread per core adds no matmul throughput and makes
        // every thread barrier wait on the slowest sibling: on a 18-core /
        // 36-thread Xeon the default of hardware_concurrency() kept the
        // host spinning 36 threads for a 0.8B model.
        const int32_t resolved_threads =
            cfg.n_threads > 0 ? cfg.n_threads : std::max<int32_t>(1, common_cpu_get_num_physical_cores());
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

        templates_ = common_chat_templates_init(model_, cfg.chat_template_override);
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

        // Each request is an independent, stateless single-turn completion
        // -- this process serves many unrelated dictation segments over its
        // lifetime, never a multi-turn conversation -- so the sampler and
        // the memory start clean every time.
        //
        // What the requests do share is their opening: the correction
        // system prompt and its few-shot turns are ~270 of the ~295 prompt
        // tokens, identical for every sentence, and a rewrite style's system
        // prompt ~240 of ~275. Decoding them once and restoring that state
        // saves most of the prompt work. Qwen3.5 is a hybrid (recurrent +
        // attention layers) whose memory cannot be trimmed back to a prefix
        // with llama_memory_seq_rm, so each prefix is kept as a full
        // sequence-state snapshot (llama_state_seq_get_data) and restored
        // with llama_state_seq_set_data. Measured with llama.cpp b11826 on a
        // Core Ultra 5 225H CPU, 65-sentence correction corpus: p50 0.75 s
        // -> 0.32 s per sentence, identical outputs (65/65).
        //
        // Prefixes are learned, not configured: one is the opening this
        // prompt shares with one of the last few prompts. There are several
        // (kPrefixSlots, least recently used goes first) because one host
        // can serve more than one kind of request: the same model doing
        // correction and rewrite alternates two system prompts, and the
        // rewrite styles each have their own. With a single snapshot learned
        // from the previous request only, that alternation never hit
        // (YandexGPT on a CPU: 8 s correction and 11.6 s of rewrite prompt on
        // every dictation instead of ~1.5 s each).
        common_sampler_reset(sampler_);
        llama_memory_t mem = llama_get_memory(ctx_);
        llama_memory_seq_rm(mem, 0, -1, -1);

        auto common_prefix = [&](const std::vector<llama_token> & other) {
            size_t n = 0;
            while (n < tokens.size() && n < other.size() && tokens[n] == other[n]) {
                n++;
            }
            return n;
        };

        // The longest snapshot this prompt starts with, leaving at least one
        // token to decode (the logits come from the last one).
        PrefixSlot * best = nullptr;
        for (auto & slot : prefix_slots_) {
            if (slot.tokens.size() < tokens.size() && common_prefix(slot.tokens) == slot.tokens.size() &&
                (best == nullptr || slot.tokens.size() > best->tokens.size())) {
                best = &slot;
            }
        }
        // The longest opening shared with a recent prompt: a snapshot worth
        // taking when it reaches kMinPrefixTokens past what is restored.
        size_t shared = 0;
        if (prefix_reuse_enabled_) {
            for (const auto & recent : recent_prompts_) {
                shared = std::max(shared, common_prefix(recent));
            }
            shared = std::min(shared, tokens.size() - 1);
        }

        int n_past = 0;
        if (best != nullptr) {
            if (llama_state_seq_set_data(ctx_, best->state.data(), best->state.size(), 0) == best->state.size()) {
                n_past = static_cast<int>(best->tokens.size());
                best->last_used = ++prefix_clock_;
            } else {
                llama_memory_seq_rm(mem, 0, -1, -1);  // a failed restore may leave part of it
                prefix_slots_.erase(prefix_slots_.begin() + (best - prefix_slots_.data()));
            }
        }
        if (shared >= static_cast<size_t>(n_past) + kMinPrefixTokens) {
            if (llama_decode(ctx_, llama_batch_get_one(tokens.data() + n_past,
                                                       static_cast<int32_t>(shared - n_past)))) {
                out.error = "prompt decode failed";
                return out;
            }
            n_past = static_cast<int>(shared);
            take_prefix_snapshot(std::vector<llama_token>(tokens.begin(), tokens.begin() + shared));
        }
        if (prefix_reuse_enabled_) {
            recent_prompts_.push_back(tokens);
            if (recent_prompts_.size() > kRecentPrompts) {
                recent_prompts_.erase(recent_prompts_.begin());
            }
        }

        const int n_rest = static_cast<int>(tokens.size()) - n_past;
        if (!common_prompt_batch_decode(ctx_, tokens, n_rest, n_past, llama_n_batch(ctx_), "", false)) {
            out.error = "prompt decode failed";
            return out;
        }
        out.prompt_tokens = static_cast<int32_t>(tokens.size());
        out.prompt_tokens_reused = static_cast<int32_t>(tokens.size()) - n_rest;

        std::string content;
        for (int32_t i = 0; i < max_new; ++i) {
            if (!last_logits_finite()) {
                out.numeric_failure = true;
                out.error = "non-finite logits: the compute backend produced NaN/Inf";
                return out;
            }
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
    struct PrefixSlot {
        std::vector<llama_token> tokens;
        std::vector<uint8_t>     state;
        uint64_t                 last_used = 0;
    };

    // Snapshots the sequence state, whose memory holds exactly `prefix`,
    // into a slot: the least recently used one goes when all are taken.
    void take_prefix_snapshot(std::vector<llama_token> prefix) {
        const size_t size = llama_state_seq_get_size(ctx_, 0);
        if (size == 0 || size > kMaxPrefixStateBytes) {
            return;
        }
        PrefixSlot slot;
        slot.state.resize(size);
        if (llama_state_seq_get_data(ctx_, slot.state.data(), size, 0) != size) {
            return;
        }
        slot.tokens = std::move(prefix);
        slot.last_used = ++prefix_clock_;
        if (prefix_slots_.size() >= kPrefixSlots) {
            auto oldest = std::min_element(prefix_slots_.begin(), prefix_slots_.end(),
                [](const PrefixSlot & a, const PrefixSlot & b) { return a.last_used < b.last_used; });
            prefix_slots_.erase(oldest);
        }
        prefix_slots_.push_back(std::move(slot));
    }

    bool last_logits_finite() const {
        const float * logits = llama_get_logits_ith(ctx_, -1);
        if (logits == nullptr) {
            return false;
        }
        const int32_t n_vocab = llama_vocab_n_tokens(vocab_);
        for (int32_t i = 0; i < n_vocab; ++i) {
            if (!std::isfinite(logits[i])) {
                return false;
            }
        }
        return true;
    }

    common_init_result_ptr    result_;
    llama_model *              model_ = nullptr;
    llama_context *            ctx_ = nullptr;
    const llama_vocab *        vocab_ = nullptr;
    common_sampler *           sampler_ = nullptr;
    common_chat_templates_ptr  templates_;
    int32_t                    n_ctx_ = 0;
    std::mutex                 mutex_;
    // Prompt-prefix reuse (see generate()). A shorter shared opening is not
    // worth a snapshot: the copy would cost more than the tokens it saves.
    static constexpr size_t    kMinPrefixTokens = 32;
    // SUPERDICTATE_LLM_PREFIX_REUSE=0 turns it off, for A/B measurements.
    const bool                 prefix_reuse_enabled_ = [] {
        const char * v = std::getenv("SUPERDICTATE_LLM_PREFIX_REUSE");
        return v == nullptr || std::strcmp(v, "0") != 0;
    }();
    // Correction, rewrite and the three rewrite styles fit, with room for a
    // custom prompt; each snapshot of a ~250-token prefix is tens of MB for
    // an 8B model, and one larger than kMaxPrefixStateBytes is not kept.
    static constexpr size_t    kPrefixSlots = 6;
    static constexpr size_t    kRecentPrompts = 6;
    static constexpr size_t    kMaxPrefixStateBytes = 512u << 20;
    std::vector<PrefixSlot>    prefix_slots_;
    std::vector<std::vector<llama_token>> recent_prompts_;
    uint64_t                   prefix_clock_ = 0;
};

sdlh_json make_error_json(const std::string & message) {
    sdlh_json j;
    j["error"]["message"] = message;
    return j;
}

} // namespace

// `--list-devices`: print every GPU/IGPU device this host's own ggml
// registry enumerates (one `DEVICE <name>\t<description>` line each) and
// exit. The app uses it to decide whether "LLM on GPU (Vulkan)" can take
// effect — asking the very Vulkan stack that will run the model, rather
// than probing some other library's copy.
static int list_gpu_devices() {
    llama_backend_init();
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
        if (type != GGML_BACKEND_DEVICE_TYPE_GPU && type != GGML_BACKEND_DEVICE_TYPE_IGPU) {
            continue;
        }
        std::printf("DEVICE %s\t%s\n", ggml_backend_dev_name(dev), ggml_backend_dev_description(dev));
    }
    std::fflush(stdout);
    llama_backend_free();
    return 0;
}

// The Vulkan backend loads its SPIR-V shaders from loose .spv files, which
// ship in Contents/Resources/llama-vulkan-shaders (scripts/build-app.sh).
// Without this the loader falls back to the shader directory of the source
// tree the binary was compiled in: that works on the build machine only,
// and only while that tree exists -- mac-v0.8.4 was built in a temporary
// worktree, which was then deleted, and every GPU start crashed.
static void configure_vulkan_shader_dir() {
#if defined(__APPLE__)
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    char resolved[PATH_MAX];
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, resolved) == nullptr) {
        return;
    }
    std::string dir(resolved);
    dir = dir.substr(0, dir.find_last_of('/')) + "/../Resources/llama-vulkan-shaders";
    char shaders[PATH_MAX];
    struct stat st;
    if (realpath(dir.c_str(), shaders) != nullptr && stat(shaders, &st) == 0 && S_ISDIR(st.st_mode)) {
        ggml_vk_shaders_set_directory(shaders);
    }
#endif
}

// A missing shader does not fail cleanly: pipeline creation reads a null
// buffer and the process dies with SIGSEGV. So check before any pipeline
// exists, and run on the CPU instead.
static bool vulkan_shaders_present() {
    std::ifstream probe(std::string(ggml_vk_shaders_directory()) + "/matmul_f32_f32.spv");
    return probe.good();
}

int main(int argc, char ** argv) {
    configure_vulkan_shader_dir();
    if (argc == 2 && std::string(argv[1]) == "--list-devices") {
        return list_gpu_devices();
    }
    HostConfig cfg;
    std::string arg_error;
    if (!parse_args(argc, argv, cfg, arg_error)) {
        std::fprintf(stderr, "superdictate-llm-host: %s\n", arg_error.c_str());
        std::fprintf(stderr, "usage: superdictate-llm-host --model <path.gguf> --port <port> "
                             "[--host 127.0.0.1] [--ctx-size 4096] [--threads N] [--gpu-layers N] "
                             "[--lora <path.gguf>] [--lora-scale N]\n"
                             "       superdictate-llm-host --list-devices\n");
        return 1;
    }

    if (cfg.n_gpu_layers != 0) {
        if (vulkan_shaders_present()) {
            std::fprintf(stderr, "superdictate-llm-host: vulkan shaders: %s\n", ggml_vk_shaders_directory());
        } else {
            std::fprintf(stderr, "superdictate-llm-host: vulkan shaders not found in %s; running on the CPU\n",
                         ggml_vk_shaders_directory());
            cfg.n_gpu_layers = 0;
        }
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

    // Parent-death watchdog. When the SuperDictate process that spawned
    // this helper dies — crash, SIGKILL, a rebuild replacing the bundle —
    // this helper would otherwise be re-parented to launchd and linger
    // forever holding gigabytes of model memory (observed in the wild:
    // ten orphaned helpers up to 34 hours old). The original PPID is
    // captured ONCE at startup; any change means the parent exited, and
    // the whole process shuts down within one poll interval. _Exit (not
    // exit) so an in-flight generation's destructors cannot hang the
    // shutdown — nobody is left waiting for that response anyway.
    //
    // Windows has no re-parenting to poll for: the parent's PID is looked up
    // once, and a handle to it is waited on. (The Windows app also puts this
    // process in a kill-on-close job object; this covers running it alone.)
#ifdef _WIN32
    HANDLE parent = nullptr;
    {
        const DWORD self = GetCurrentProcessId();
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot != INVALID_HANDLE_VALUE) {
            PROCESSENTRY32W entry{};
            entry.dwSize = sizeof(entry);
            for (BOOL ok = Process32FirstW(snapshot, &entry); ok; ok = Process32NextW(snapshot, &entry)) {
                if (entry.th32ProcessID == self) {
                    parent = OpenProcess(SYNCHRONIZE, FALSE, entry.th32ParentProcessID);
                    break;
                }
            }
            CloseHandle(snapshot);
        }
    }
    if (parent != nullptr) {
        std::thread([parent]() {
            WaitForSingleObject(parent, INFINITE);
            std::fprintf(stderr, "superdictate-llm-host: parent exited, shutting down\n");
            std::_Exit(0);
        }).detach();
    }
#else
    const pid_t original_ppid = getppid();
    std::thread([original_ppid]() {
        while (true) {
            std::this_thread::sleep_for(std::chrono::seconds(2));
            if (getppid() != original_ppid) {
                std::fprintf(stderr, "superdictate-llm-host: parent exited, shutting down\n");
                std::_Exit(0);
            }
        }
    }).detach();
#endif

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
            res.status = gen.numeric_failure ? 503 : 500;
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
            // OpenAI's own field for prompt tokens served from a cache.
            {"prompt_tokens_details", sdlh_json{{"cached_tokens", gen.prompt_tokens_reused}}},
        };
        res.set_content(resp.dump(), "application/json");
    });

    if (!svr.listen(cfg.host, cfg.port)) {
        std::fprintf(stderr, "superdictate-llm-host: failed to listen on %s:%d\n", cfg.host.c_str(), cfg.port);
        return 1;
    }
    return 0;
}
