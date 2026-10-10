// ONNX Runtime environment, session options and execution-provider policy
// (spec §6). Provider resolution is honest: an explicitly requested
// accelerator that is unavailable is an error, never a silent CPU run.
#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include "common.h"
#include "manifest.h"
#include "onnxruntime_cxx_api.h"

namespace sdasr {

struct ProviderResolution {
    std::string requested;        // "auto" | "cpu" | "coreml" | "directml"
    std::string actual;           // "cpu" | "coreml+cpu" | "directml+cpu"
    std::string fallback_reason;  // non-empty when actual differs from an accelerator request
};

struct RuntimeOptions {
    std::string provider = "auto";
    int intra_op_threads = 0;  // 0 = default policy
    int inter_op_threads = 1;
    bool allow_unvalidated_providers = false;
    // ORT worker threads spin briefly (bounded) before sleeping. Measured
    // ~25% faster encoder on 8 threads; set false for minimum idle CPU.
    bool allow_spinning = true;
};

// Process-wide ORT environment (created on first use, never destroyed
// before exit — ORT forbids using sessions after the Env is gone).
Ort::Env &ort_env();

std::string ort_version();
std::vector<std::string> available_providers();

// Default thread policy shared with the GGUF engine:
// max(2, min(8, hardware_concurrency / 2)).
int default_intra_op_threads();

class SessionFactory {
public:
    // Throws Error(SD_ASR_PROVIDER_UNAVAILABLE / SD_ASR_INVALID_ARGUMENT).
    SessionFactory(const RuntimeOptions &options, const Manifest &manifest);

    Ort::Session open(const std::filesystem::path &model_path) const;
    // Small per-step graphs (decoder/joiner/preprocessor) always run on CPU
    // with a single thread: per-call accelerator dispatch or thread-pool
    // wake-ups cost more than the work itself.
    Ort::Session open_cpu(const std::filesystem::path &model_path) const;

    const ProviderResolution &resolution() const { return resolution_; }
    int intra_op_threads() const { return intra_op_threads_; }
    int inter_op_threads() const { return inter_op_threads_; }
    bool allow_spinning() const { return allow_spinning_; }

private:
    Ort::SessionOptions base_options() const;

    ProviderResolution resolution_;
    int intra_op_threads_ = 1;
    int inter_op_threads_ = 1;
    bool allow_spinning_ = true;
};

}  // namespace sdasr
