// Model-family adapter interface. Each family owns its preprocessing,
// decoder loop and tokenization; nothing here assumes two ONNX models share
// a decoder (spec §3).
#pragma once

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "../manifest.h"
#include "../ort_session.h"

namespace sdasr {

struct DecodedToken {
    int id = 0;
    double t = 0;      // seconds from the start of the buffer passed in
    double conf = 0;   // softmax probability of the chosen token
};

struct DecodedWord {
    std::string w;
    double start = 0;
    double end = 0;
    double conf = 0;   // minimum token confidence within the word
};

struct FamilyResult {
    std::string text;
    double frame_sec = 0;
    std::vector<DecodedToken> tokens;
    std::vector<DecodedWord> words;
};

struct RunContext {
    Ort::RunOptions *run_options = nullptr;     // terminate flag for in-graph cancellation
    const std::atomic<bool> *cancelled = nullptr;  // polled between decoder steps
};

class ModelFamily {
public:
    virtual ~ModelFamily() = default;
    virtual FamilyResult transcribe(const std::vector<float> &samples, RunContext &context) = 0;
};

// Throws Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY / SD_ASR_INVALID_MODEL /
// SD_ASR_MODEL_LOAD_FAILED).
std::unique_ptr<ModelFamily> create_model_family(const Manifest &manifest, const SessionFactory &factory);

// Per-family constructors behind create_model_family (family.cpp).
std::unique_ptr<ModelFamily> create_nemo_tdt_family(const Manifest &manifest, const SessionFactory &factory);
std::unique_ptr<ModelFamily> create_gigaam_rnnt_family(const Manifest &manifest, const SessionFactory &factory);

}  // namespace sdasr
