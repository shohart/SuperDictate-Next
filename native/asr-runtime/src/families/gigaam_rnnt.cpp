// GigaAM v3 (Conformer + RNN-T) family, in the istupakov/gigaam-v3-onnx
// layout used by onnx-asr: encoder / decoder (one-layer LSTM prediction net)
// / joint graphs plus a "<piece> <id>" vocabulary. Features come from the
// bundled gigaam_v3.onnx log-mel graph (onnx-asr, MIT), never from
// hand-written DSP.
//
// Reference implementation: native/asr-runtime/tools/reference_gigaam.py,
// itself checked against onnx-asr 0.12.0. The two must produce identical
// text and tokens (spec §2.4, §11.2).
#include <algorithm>
#include <cstring>

#include "family_util.h"

namespace sdasr {

namespace {

class GigaamRnntFamily final : public ModelFamily {
public:
    GigaamRnntFamily(const Manifest &manifest, const SessionFactory &factory)
        : memory_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {
        feature_dim_ = int_param(manifest, "feature_dim");
        vocab_size_ = int_param(manifest, "vocab_size");  // including blank
        blank_id_ = int_param(manifest, "blank_id");
        pred_hidden_ = int_param(manifest, "pred_hidden");
        max_symbols_ = int_param(manifest, "max_symbols_per_frame");
        frame_sec_ = number_param(manifest, "hop_seconds") * double(int_param(manifest, "subsampling_factor"));
        if (blank_id_ < 0 || blank_id_ >= vocab_size_ || max_symbols_ < 1 || feature_dim_ < 1 || pred_hidden_ < 1 ||
            frame_sec_ <= 0) {
            throw Error(SD_ASR_INVALID_MODEL, "manifest: inconsistent gigaam_rnnt params");
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
        expect_names(*encoder_, false, {"encoded", "encoded_len"}, "encoder");
        expect_names(*decoder_, true, {"x", "h.1", "c.1"}, "decoder");
        expect_names(*decoder_, false, {"dec", "h", "c"}, "decoder");
        expect_names(*joiner_, true, {"enc", "dec"}, "joiner");
        expect_names(*joiner_, false, {"joint"}, "joiner");

        const auto features_shape = output_shape(*preprocessor_, 0);
        if (features_shape.size() != 3 || features_shape[1] != feature_dim_) {
            throw Error(SD_ASR_INVALID_MODEL, "preprocessor feature dimension does not match params.feature_dim");
        }
        const auto encoder_shape = output_shape(*encoder_, 0);
        if (encoder_shape.size() != 3 || encoder_shape[1] <= 0) {
            throw Error(SD_ASR_INVALID_MODEL, "encoder output must be [B, D, T] with a static D");
        }
        encoder_dim_ = encoder_shape[1];
        const auto decoder_shape = output_shape(*decoder_, 0);
        if (decoder_shape.empty() || decoder_shape.back() != pred_hidden_) {
            throw Error(SD_ASR_INVALID_MODEL, "decoder output width != params.pred_hidden");
        }
        const auto logits_shape = output_shape(*joiner_, 0);
        if (logits_shape.empty() || logits_shape.back() != vocab_size_) {
            throw Error(SD_ASR_INVALID_MODEL, "joint logits width != params.vocab_size");
        }
    }

    FamilyResult transcribe(const std::vector<float> &samples, RunContext &context) override {
        Ort::RunOptions &run_options = *context.run_options;

        // 1. Features [1, feature_dim, frames] (+ their valid length).
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

        // 2. Encoder [1, encoder_dim, T']. Unlike nemo128, gigaam_v3.onnx
        // (center=false) reports features_lens == T, which onnx-asr passes
        // straight through.
        const char *enc_in[] = {"audio_signal", "length"};
        const char *enc_out[] = {"encoded", "encoded_len"};
        Ort::Value enc_inputs[2] = {std::move(features[0]), std::move(features[1])};
        auto encoded = encoder_->Run(run_options, enc_in, enc_inputs, 2, enc_out, 2);
        check_cancelled(context);

        const auto enc_shape = encoded[0].GetTensorTypeAndShapeInfo().GetShape();
        if (enc_shape.size() != 3 || enc_shape[0] != 1 || enc_shape[1] != encoder_dim_) {
            throw Error(SD_ASR_INFERENCE_FAILED, "unexpected encoder output shape");
        }
        const int64_t total_frames = enc_shape[2];
        const auto len_type = encoded[1].GetTensorTypeAndShapeInfo().GetElementType();
        const int64_t encoded_len = len_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                                        ? encoded[1].GetTensorData<int64_t>()[0]
                                        : int64_t(encoded[1].GetTensorData<int32_t>()[0]);
        const int64_t frames = std::max<int64_t>(0, std::min<int64_t>(encoded_len, total_frames));
        const float *enc = encoded[0].GetTensorData<float>();

        // Channel-major [D, T] -> frame-major [T, D] so each joint step reads
        // one contiguous frame.
        std::vector<float> frame_major(static_cast<size_t>(frames * encoder_dim_));
        for (int64_t d = 0; d < encoder_dim_; ++d) {
            const float *row = enc + d * total_frames;
            for (int64_t t = 0; t < frames; ++t) frame_major[size_t(t * encoder_dim_ + d)] = row[t];
        }

        // 3. Greedy RNN-T (onnx-asr _AsrWithTransducerDecoding): the
        // decoder output for (last emitted token or blank, state) is computed
        // once and reused until the next emission; at most max_symbols
        // tokens per encoder frame.
        const size_t hidden = size_t(pred_hidden_);
        std::vector<float> h(hidden, 0.0f), c(hidden, 0.0f);
        std::vector<float> h_next(hidden), c_next(hidden), dec_out(hidden);
        run_decoder(run_options, blank_id_, h, c, dec_out, h_next, c_next);

        FamilyResult result;
        result.frame_sec = frame_sec_;
        std::vector<float> enc_frame(static_cast<size_t>(encoder_dim_));
        std::vector<float> logits(static_cast<size_t>(vocab_size_));
        int64_t t = 0;
        int64_t emitted_this_frame = 0;
        while (t < frames) {
            check_cancelled(context);
            std::copy_n(frame_major.begin() + t * encoder_dim_, encoder_dim_, enc_frame.begin());
            run_joiner(run_options, enc_frame, dec_out, logits);
            const int64_t token = std::distance(logits.begin(), std::max_element(logits.begin(), logits.end()));

            if (token != blank_id_) {
                if (!is_control_piece(pieces_[size_t(token)])) {
                    result.tokens.push_back({int(token), double(t) * frame_sec_,
                                             softmax_probability(logits.data(), logits.size(), size_t(token))});
                }
                h.swap(h_next);
                c.swap(c_next);
                run_decoder(run_options, token, h, c, dec_out, h_next, c_next);
                ++emitted_this_frame;
            }
            if (token == blank_id_ || emitted_this_frame >= max_symbols_) {
                t += 1;
                emitted_this_frame = 0;
            }
        }

        build_text_and_words_space_rule(result, pieces_, double(frames) * frame_sec_);
        return result;
    }

private:
    void run_decoder(Ort::RunOptions &run_options, int64_t token, std::vector<float> &h, std::vector<float> &c,
                     std::vector<float> &dec_out, std::vector<float> &h_next, std::vector<float> &c_next) {
        int64_t x = token;
        const int64_t x_shape[2] = {1, 1};
        const int64_t state_shape[3] = {1, 1, pred_hidden_};
        Ort::Value inputs[3] = {
            Ort::Value::CreateTensor<int64_t>(memory_, &x, 1, x_shape, 2),
            Ort::Value::CreateTensor<float>(memory_, h.data(), h.size(), state_shape, 3),
            Ort::Value::CreateTensor<float>(memory_, c.data(), c.size(), state_shape, 3),
        };
        const char *in_names[] = {"x", "h.1", "c.1"};
        const char *out_names[] = {"dec", "h", "c"};
        auto outputs = decoder_->Run(run_options, in_names, inputs, 3, out_names, 3);
        copy_tensor(outputs[0], dec_out);
        copy_tensor(outputs[1], h_next);
        copy_tensor(outputs[2], c_next);
    }

    // dec [1, 1, H] is fed as [1, H, 1]: the same contiguous data.
    void run_joiner(Ort::RunOptions &run_options, std::vector<float> &enc_frame, std::vector<float> &dec_out,
                    std::vector<float> &logits) {
        const int64_t enc_shape[3] = {1, encoder_dim_, 1};
        const int64_t dec_shape[3] = {1, pred_hidden_, 1};
        Ort::Value inputs[2] = {
            Ort::Value::CreateTensor<float>(memory_, enc_frame.data(), enc_frame.size(), enc_shape, 3),
            Ort::Value::CreateTensor<float>(memory_, dec_out.data(), dec_out.size(), dec_shape, 3),
        };
        const char *in_names[] = {"enc", "dec"};
        const char *out_names[] = {"joint"};
        auto outputs = joiner_->Run(run_options, in_names, inputs, 2, out_names, 1);
        copy_tensor(outputs[0], logits);
    }

    static void copy_tensor(Ort::Value &value, std::vector<float> &out) {
        const size_t count = value.GetTensorTypeAndShapeInfo().GetElementCount();
        if (count != out.size()) throw Error(SD_ASR_INFERENCE_FAILED, "unexpected decoder/joint tensor size");
        const float *data = value.GetTensorData<float>();
        std::copy(data, data + count, out.begin());
    }

    Ort::MemoryInfo memory_;
    std::unique_ptr<Ort::Session> preprocessor_, encoder_, decoder_, joiner_;
    std::vector<std::string> pieces_;
    int64_t feature_dim_ = 0, vocab_size_ = 0, blank_id_ = 0, pred_hidden_ = 0, max_symbols_ = 0, encoder_dim_ = 0;
    double frame_sec_ = 0;
};

}  // namespace

std::unique_ptr<ModelFamily> create_gigaam_rnnt_family(const Manifest &manifest, const SessionFactory &factory) {
    return std::make_unique<GigaamRnntFamily>(manifest, factory);
}

}  // namespace sdasr
