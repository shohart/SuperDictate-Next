#include "ort_session.h"

#include <algorithm>
#include <thread>

namespace sdasr {

namespace {

bool contains(const std::vector<std::string> &values, const std::string &value) {
    return std::find(values.begin(), values.end(), value) != values.end();
}

const char *ort_provider_name(const std::string &provider) {
    if (provider == "coreml") return "CoreMLExecutionProvider";
    if (provider == "directml") return "DmlExecutionProvider";
    return "CPUExecutionProvider";
}

}  // namespace

Ort::Env &ort_env() {
    static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "sd_asr");
    return env;
}

std::string ort_version() {
    return Ort::GetVersionString();
}

std::vector<std::string> available_providers() {
    return Ort::GetAvailableProviders();
}

int default_intra_op_threads() {
    const int cores = int(std::thread::hardware_concurrency());
    return std::max(2, std::min(8, cores / 2));
}

SessionFactory::SessionFactory(const RuntimeOptions &options, const Manifest &manifest) {
    const std::string &requested = options.provider;
    if (requested != "auto" && requested != "cpu" && requested != "coreml" && requested != "directml") {
        throw Error(SD_ASR_INVALID_ARGUMENT, "unknown provider '" + requested + "'");
    }
    if (options.intra_op_threads < 0 || options.intra_op_threads > 64 ||
        options.inter_op_threads < 0 || options.inter_op_threads > 64) {
        throw Error(SD_ASR_INVALID_ARGUMENT, "thread counts must be within 0...64");
    }
    intra_op_threads_ = options.intra_op_threads > 0 ? options.intra_op_threads : default_intra_op_threads();
    inter_op_threads_ = options.inter_op_threads > 0 ? options.inter_op_threads : 1;
    allow_spinning_ = options.allow_spinning;

    resolution_.requested = requested;
    if (requested == "auto") {
        // API v1: no accelerator is validated for any shipped model yet, so
        // auto means CPU — and says why (spec §6).
        resolution_.actual = "cpu";
        resolution_.fallback_reason = "accelerators not validated for this model";
        return;
    }
    if (requested == "cpu") {
        resolution_.actual = "cpu";
        return;
    }
    if (!contains(available_providers(), ort_provider_name(requested))) {
        throw Error(SD_ASR_PROVIDER_UNAVAILABLE,
                    std::string(ort_provider_name(requested)) + " is not available in this ONNX Runtime build");
    }
    if (!contains(manifest.providers, requested) && !options.allow_unvalidated_providers) {
        throw Error(SD_ASR_PROVIDER_UNAVAILABLE,
                    "provider '" + requested + "' is not validated for model '" + manifest.model_id +
                        "' (set allow_unvalidated_providers for benchmarking)");
    }
    // ORT may still place unsupported nodes on CPU; never claim full offload.
    resolution_.actual = requested + "+cpu";
}

Ort::SessionOptions SessionFactory::base_options() const {
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(intra_op_threads_);
    options.SetInterOpNumThreads(inter_op_threads_);
    options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    options.AddConfigEntry("session.intra_op.allow_spinning", allow_spinning_ ? "1" : "0");
    options.AddConfigEntry("session.inter_op.allow_spinning", allow_spinning_ ? "1" : "0");
    return options;
}

Ort::Session SessionFactory::open(const std::filesystem::path &model_path) const {
    Ort::SessionOptions options = base_options();
    if (resolution_.actual == "coreml+cpu") {
        options.AppendExecutionProvider("CoreML", {{"ModelFormat", "MLProgram"}, {"MLComputeUnits", "ALL"}});
    } else if (resolution_.actual == "directml+cpu") {
        options.AppendExecutionProvider("DML", {});
    }
    // fs::path::c_str() is ORTCHAR_T-compatible on every platform (wchar_t
    // on Windows), so non-ASCII profile paths work without conversion.
    return Ort::Session(ort_env(), model_path.c_str(), options);
}

Ort::Session SessionFactory::open_cpu(const std::filesystem::path &model_path) const {
    Ort::SessionOptions options = base_options();
    // Per-step graphs run thousands of tiny inferences per utterance; waking
    // a thread pool for each costs more than the math (spinning is off).
    options.SetIntraOpNumThreads(1);
    return Ort::Session(ort_env(), model_path.c_str(), options);
}

}  // namespace sdasr
