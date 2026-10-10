// NeMo FastConformer + TDT (token-and-duration transducer) family, in the
// sherpa-onnx "nemo_transducer" layout: encoder / decoder (LSTM prediction
// net) / joiner graphs plus tokens.txt. Features come from the bundled
// NeMo-exact log-mel graph (nemo128.onnx), never from hand-written DSP.
//
// Reference implementation: native/asr-runtime/tools/reference_tdt.py. The
// two must produce identical text (spec §2.4, §11.2).
#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>

#include "family.h"

namespace sdasr {

namespace {

constexpr const char *kWordStart = "\xE2\x96\x81";  // U+2581 "▁"

int64_t int_param(const Manifest &manifest, const char *key) {
    auto it = manifest.params.find(key);
    if (it == manifest.params.end() || !it->is_number_integer()) {
        throw Error(SD_ASR_INVALID_MODEL, std::string("manifest: nemo_tdt requires integer params.") + key);
    }
    return it->get<int64_t>();
}

double number_param(const Manifest &manifest, const char *key) {
    auto it = manifest.params.find(key);
    if (it == manifest.params.end() || !it->is_number()) {
        throw Error(SD_ASR_INVALID_MODEL, std::string("manifest: nemo_tdt requires numeric params.") + key);
    }
    return it->get<double>();
}

bool starts_with(const std::string &value, const char *prefix) {
    return value.rfind(prefix, 0) == 0;
}

// Pieces such as <unk>, <pad>, <|nospeech|> never reach the transcript.
bool is_control_piece(const std::string &piece) {
    return piece.size() >= 2 && piece.front() == '<' && piece.back() == '>';
}

std::vector<std::string> load_tokens(const std::filesystem::path &path, int64_t expected_count) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw Error(SD_ASR_INVALID_MODEL, "cannot open tokens file");
    std::vector<std::string> pieces(static_cast<size_t>(expected_count));
    std::vector<bool> seen(static_cast<size_t>(expected_count), false);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        const size_t space = line.rfind(' ');
        if (space == std::string::npos || space == 0) throw Error(SD_ASR_INVALID_MODEL, "malformed tokens line: " + line);
        long long id = -1;
        try {
            id = std::stoll(line.substr(space + 1));
        } catch (...) {
            throw Error(SD_ASR_INVALID_MODEL, "malformed token id: " + line);
        }
        if (id < 0 || id >= expected_count) throw Error(SD_ASR_INVALID_MODEL, "token id out of range: " + line);
        pieces[size_t(id)] = line.substr(0, space);
        seen[size_t(id)] = true;
    }
    for (int64_t i = 0; i < expected_count; ++i) {
        if (!seen[size_t(i)]) throw Error(SD_ASR_INVALID_MODEL, "tokens file is missing id " + std::to_string(i));
    }
    return pieces;
}

std::vector<int64_t> output_shape(Ort::Session &session, size_t index) {
    return session.GetOutputTypeInfo(index).GetTensorTypeAndShapeInfo().GetShape();
}

void expect_names(Ort::Session &session, bool inputs, const std::vector<std::string> &expected, const char *graph) {
    Ort::AllocatorWithDefaultOptions allocator;
    const size_t count = inputs ? session.GetInputCount() : session.GetOutputCount();
    if (count != expected.size()) {
        throw Error(SD_ASR_INVALID_MODEL, std::string(graph) + ": unexpected " + (inputs ? "input" : "output") +
                                              " count " + std::to_string(count));
    }
    for (size_t i = 0; i < count; ++i) {
        auto name = inputs ? session.GetInputNameAllocated(i, allocator) : session.GetOutputNameAllocated(i, allocator);
        if (expected[i] != name.get()) {
            throw Error(SD_ASR_INVALID_MODEL, std::string(graph) + ": expected " + (inputs ? "input " : "output ") +
                                                  expected[i] + ", found " + name.get());
        }
    }
}

class NemoTdtFamily final : public ModelFamily {
public:
    NemoTdtFamily(const Manifest &manifest, const SessionFactory &factory)
        : memory_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {
        feature_dim_ = int_param(manifest, "feature_dim");
        vocab_size_ = int_param(manifest, "vocab_size");  // including blank
        blank_id_ = int_param(manifest, "blank_id");
        pred_hidden_ = int_param(manifest, "pred_hidden");
        pred_layers_ = int_param(manifest, "pred_rnn_layers");
        max_symbols_ = int_param(manifest, "max_symbols_per_frame");
        frame_sec_ = number_param(manifest, "hop_seconds") * double(int_param(manifest, "subsampling_factor"));
        auto durations = manifest.params.find("durations");
        if (durations == manifest.params.end() || !durations->is_array() || durations->empty()) {
            throw Error(SD_ASR_INVALID_MODEL, "manifest: nemo_tdt requires params.durations");
        }
        for (const auto &d : *durations) {
            if (!d.is_number_integer() || d.get<int64_t>() < 0) throw Error(SD_ASR_INVALID_MODEL, "bad duration");
            durations_.push_back(d.get<int64_t>());
        }
        if (blank_id_ < 0 || blank_id_ >= vocab_size_ || max_symbols_ < 1 || feature_dim_ < 1 || pred_hidden_ < 1 ||
            pred_layers_ < 1 || frame_sec_ <= 0) {
            throw Error(SD_ASR_INVALID_MODEL, "manifest: inconsistent nemo_tdt params");
        }

        pieces_ = load_tokens(manifest.file("tokens").path, vocab_size_);

        try {
            preprocessor_ = std::make_unique<Ort::Session>(factory.open_cpu(manifest.file("preprocessor").path));
            encoder_ = std::make_unique<Ort::Session>(factory.open(manifest.file("encoder").path));
            decoder_ = std::make_unique<Ort::Session>(factory.open_cpu(manifest.file("decoder").path));
            joiner_ = std::make_unique<Ort::Session>(factory.open_cpu(manifest.file("joiner").path));
        } catch (const Ort::Exception &e) {
            throw Error(SD_ASR_MODEL_LOAD_FAILED, std::string("ONNX Runtime failed to load model: ") + e.what());
        }

        expect_names(*preprocessor_, true, {"waveforms", "waveforms_lens"}, "preprocessor");
        expect_names(*preprocessor_, false, {"features", "features_lens"}, "preprocessor");
        expect_names(*encoder_, true, {"audio_signal", "length"}, "encoder");
        expect_names(*encoder_, false, {"outputs", "encoded_lengths"}, "encoder");
        expect_names(*decoder_, true, {"targets", "target_lengths", "h", "c"}, "decoder");
        expect_names(*decoder_, false, {"decoder_out", "decoder_out_length", "h_next", "c_next"}, "decoder");
        expect_names(*joiner_, true, {"encoder_out", "decoder_out"}, "joiner");
        expect_names(*joiner_, false, {"logits"}, "joiner");

        const auto features_shape = output_shape(*preprocessor_, 0);
        if (features_shape.size() != 3 || features_shape[1] != feature_dim_) {
            throw Error(SD_ASR_INVALID_MODEL, "preprocessor feature dimension does not match params.feature_dim");
        }
        const auto encoder_shape = output_shape(*encoder_, 0);
        if (encoder_shape.size() != 3 || encoder_shape[1] <= 0) {
            throw Error(SD_ASR_INVALID_MODEL, "encoder output must be [B, D, T] with a static D");
        }
        encoder_dim_ = encoder_shape[1];
        const auto logits_shape = output_shape(*joiner_, 0);
        if (logits_shape.empty() || logits_shape.back() != vocab_size_ + int64_t(durations_.size())) {
            throw Error(SD_ASR_INVALID_MODEL, "joiner logits width != vocab_size + durations");
        }
    }

    FamilyResult transcribe(const std::vector<float> &samples, RunContext &context) override {
        Ort::RunOptions &run_options = *context.run_options;

        // 1. Features [1, feature_dim, frames].
        const int64_t wave_shape[2] = {1, int64_t(samples.size())};
        int64_t wave_len = int64_t(samples.size());
        const int64_t len_shape[1] = {1};
        Ort::Value pre_inputs[2] = {
            Ort::Value::CreateTensor<float>(memory_, const_cast<float *>(samples.data()), samples.size(), wave_shape, 2),
            Ort::Value::CreateTensor<int64_t>(memory_, &wave_len, 1, len_shape, 1),
        };
        const char *pre_in[] = {"waveforms", "waveforms_lens"};
        const char *pre_out[] = {"features", "features_lens"};
        auto features = preprocessor_->Run(run_options, pre_in, pre_inputs, 2, pre_out, 2);
        check_cancelled(context);

        // 2. Encoder [1, encoder_dim, T'].
        const char *enc_in[] = {"audio_signal", "length"};
        const char *enc_out[] = {"outputs", "encoded_lengths"};
        Ort::Value enc_inputs[2] = {std::move(features[0]), std::move(features[1])};
        auto encoded = encoder_->Run(run_options, enc_in, enc_inputs, 2, enc_out, 2);
        check_cancelled(context);

        const auto enc_shape = encoded[0].GetTensorTypeAndShapeInfo().GetShape();
        if (enc_shape.size() != 3 || enc_shape[0] != 1 || enc_shape[1] != encoder_dim_) {
            throw Error(SD_ASR_INFERENCE_FAILED, "unexpected encoder output shape");
        }
        const int64_t total_frames = enc_shape[2];
        const int64_t frames = std::min<int64_t>(encoded[1].GetTensorData<int32_t>()[0], total_frames);
        const float *enc = encoded[0].GetTensorData<float>();

        // Channel-major [D, T] -> frame-major [T, D] so each joiner step reads
        // one contiguous frame.
        std::vector<float> frame_major(static_cast<size_t>(frames * encoder_dim_));
        for (int64_t d = 0; d < encoder_dim_; ++d) {
            const float *row = enc + d * total_frames;
            for (int64_t t = 0; t < frames; ++t) frame_major[size_t(t * encoder_dim_ + d)] = row[t];
        }

        // 3. Greedy TDT decoding (spec §5.5).
        const size_t state_size = size_t(pred_layers_ * pred_hidden_);
        std::vector<float> h(state_size, 0.0f), c(state_size, 0.0f);
        std::vector<float> h_next(state_size), c_next(state_size), dec_out(static_cast<size_t>(pred_hidden_));
        run_decoder(run_options, int32_t(blank_id_), h, c, dec_out, h_next, c_next);

        FamilyResult result;
        result.frame_sec = frame_sec_;
        std::vector<float> enc_frame(static_cast<size_t>(encoder_dim_));
        int64_t t = 0;
        int64_t emitted_this_frame = 0;
        while (t < frames) {
            check_cancelled(context);
            std::copy_n(frame_major.begin() + t * encoder_dim_, encoder_dim_, enc_frame.begin());
            const std::vector<float> logits = run_joiner(run_options, enc_frame, dec_out);

            const auto token_end = logits.begin() + vocab_size_;
            const int64_t token = std::distance(logits.begin(), std::max_element(logits.begin(), token_end));
            const int64_t duration_index = std::distance(token_end, std::max_element(token_end, logits.end()));
            const int64_t skip = durations_[size_t(duration_index)];

            if (token != blank_id_) {
                const std::string &piece = pieces_[size_t(token)];
                if (!is_control_piece(piece)) {
                    result.tokens.push_back({int(token), double(t) * frame_sec_, softmax_probability(logits, token)});
                }
                h.swap(h_next);
                c.swap(c_next);
                run_decoder(run_options, int32_t(token), h, c, dec_out, h_next, c_next);
                ++emitted_this_frame;
            }
            if (skip > 0) {
                t += skip;
                emitted_this_frame = 0;
            } else if (token == blank_id_ || emitted_this_frame >= max_symbols_) {
                t += 1;
                emitted_this_frame = 0;
            }
        }

        build_text_and_words(result, double(frames) * frame_sec_);
        return result;
    }

private:
    static void check_cancelled(const RunContext &context) {
        if (context.cancelled && context.cancelled->load()) throw Error(SD_ASR_CANCELLED, "request cancelled");
    }

    void run_decoder(Ort::RunOptions &run_options, int32_t token, std::vector<float> &h, std::vector<float> &c,
                     std::vector<float> &dec_out, std::vector<float> &h_next, std::vector<float> &c_next) {
        int32_t target = token;
        int32_t target_length = 1;
        const int64_t target_shape[2] = {1, 1};
        const int64_t length_shape[1] = {1};
        const int64_t state_shape[3] = {pred_layers_, 1, pred_hidden_};
        Ort::Value inputs[4] = {
            Ort::Value::CreateTensor<int32_t>(memory_, &target, 1, target_shape, 2),
            Ort::Value::CreateTensor<int32_t>(memory_, &target_length, 1, length_shape, 1),
            Ort::Value::CreateTensor<float>(memory_, h.data(), h.size(), state_shape, 3),
            Ort::Value::CreateTensor<float>(memory_, c.data(), c.size(), state_shape, 3),
        };
        const char *in_names[] = {"targets", "target_lengths", "h", "c"};
        const char *out_names[] = {"decoder_out", "h_next", "c_next"};
        auto outputs = decoder_->Run(run_options, in_names, inputs, 4, out_names, 3);
        copy_tensor(outputs[0], dec_out);
        copy_tensor(outputs[1], h_next);
        copy_tensor(outputs[2], c_next);
    }

    std::vector<float> run_joiner(Ort::RunOptions &run_options, std::vector<float> &enc_frame,
                                  std::vector<float> &dec_out) {
        const int64_t enc_shape[3] = {1, encoder_dim_, 1};
        const int64_t dec_shape[3] = {1, pred_hidden_, 1};
        Ort::Value inputs[2] = {
            Ort::Value::CreateTensor<float>(memory_, enc_frame.data(), enc_frame.size(), enc_shape, 3),
            Ort::Value::CreateTensor<float>(memory_, dec_out.data(), dec_out.size(), dec_shape, 3),
        };
        const char *in_names[] = {"encoder_out", "decoder_out"};
        const char *out_names[] = {"logits"};
        auto outputs = joiner_->Run(run_options, in_names, inputs, 2, out_names, 1);
        const size_t count = outputs[0].GetTensorTypeAndShapeInfo().GetElementCount();
        const float *data = outputs[0].GetTensorData<float>();
        return std::vector<float>(data, data + count);
    }

    static void copy_tensor(Ort::Value &value, std::vector<float> &out) {
        const size_t count = value.GetTensorTypeAndShapeInfo().GetElementCount();
        if (count != out.size()) throw Error(SD_ASR_INFERENCE_FAILED, "unexpected decoder tensor size");
        const float *data = value.GetTensorData<float>();
        std::copy(data, data + count, out.begin());
    }

    double softmax_probability(const std::vector<float> &logits, int64_t token) const {
        const auto end = logits.begin() + vocab_size_;
        const float max_logit = *std::max_element(logits.begin(), end);
        double sum = 0;
        for (auto it = logits.begin(); it != end; ++it) sum += std::exp(double(*it - max_logit));
        return std::exp(double(logits[size_t(token)] - max_logit)) / sum;
    }

    // Text = pieces joined with U+2581 -> space, outer spaces trimmed. Words
    // = runs of tokens starting at a U+2581 piece (the first token always
    // starts a word).
    void build_text_and_words(FamilyResult &result, double audio_end) const {
        std::string text;
        for (size_t i = 0; i < result.tokens.size(); ++i) {
            const DecodedToken &token = result.tokens[i];
            const std::string &piece = pieces_[size_t(token.id)];
            const bool word_start = starts_with(piece, kWordStart);
            const std::string body = word_start ? piece.substr(3) : piece;
            if (word_start || result.words.empty()) {
                if (!result.words.empty()) {
                    result.words.back().end = std::min(result.words.back().end, token.t);
                }
                result.words.push_back({body, token.t, token.t + result.frame_sec, token.conf});
            } else {
                DecodedWord &word = result.words.back();
                word.w += body;
                word.end = token.t + result.frame_sec;
                word.conf = std::min(word.conf, token.conf);
            }
            text += word_start ? " " + body : body;
        }
        if (!result.words.empty()) result.words.back().end = std::min(result.words.back().end, audio_end);
        const size_t first = text.find_first_not_of(' ');
        const size_t last = text.find_last_not_of(' ');
        result.text = first == std::string::npos ? std::string() : text.substr(first, last - first + 1);
        result.words.erase(std::remove_if(result.words.begin(), result.words.end(),
                                          [](const DecodedWord &w) { return w.w.empty(); }),
                           result.words.end());
    }

    Ort::MemoryInfo memory_;
    std::unique_ptr<Ort::Session> preprocessor_, encoder_, decoder_, joiner_;
    std::vector<std::string> pieces_;
    std::vector<int64_t> durations_;
    int64_t feature_dim_ = 0, vocab_size_ = 0, blank_id_ = 0, pred_hidden_ = 0, pred_layers_ = 0;
    int64_t max_symbols_ = 0, encoder_dim_ = 0;
    double frame_sec_ = 0;
};

}  // namespace

std::unique_ptr<ModelFamily> create_model_family(const Manifest &manifest, const SessionFactory &factory) {
    if (manifest.family == "nemo_tdt") return std::make_unique<NemoTdtFamily>(manifest, factory);
    throw Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY, "unsupported model family '" + manifest.family + "'");
}

}  // namespace sdasr
