// Punctuation restoration with a ModernBERT token classifier
// (Horizon-Labs/punctuation-restoration-{small,base}, mmBERT): one label
// after each word, taken from the word's last sub-token. Long texts run in
// overlapping token chunks, exactly as the model card's punctuate.py does.
//
// Reference implementation: native/asr-runtime/tools/reference_punct.py.
#include <algorithm>

#include "bpe_tokenizer.h"
#include "family_util.h"
#include "punct_text.h"

namespace sdasr {

namespace {

class ModernBertPunctFamily final : public ModelFamily {
public:
    ModernBertPunctFamily(const Manifest &manifest, const SessionFactory &factory)
        : memory_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {
        cls_id_ = int_param(manifest, "cls_id");
        sep_id_ = int_param(manifest, "sep_id");
        chunk_tokens_ = int_param(manifest, "chunk_tokens");
        overlap_tokens_ = int_param(manifest, "overlap_tokens");
        if (auto it = manifest.params.find("labels"); it != manifest.params.end() && it->is_array()) {
            for (const auto &label : *it) {
                if (!label.is_string()) throw Error(SD_ASR_INVALID_MODEL, "manifest: labels must be strings");
                labels_.push_back(label.get<std::string>());
            }
        }
        if (labels_.empty() || chunk_tokens_ < 8 || overlap_tokens_ < 0 || overlap_tokens_ * 2 >= chunk_tokens_) {
            throw Error(SD_ASR_INVALID_MODEL, "manifest: inconsistent modernbert_punct params");
        }

        tokenizer_ = std::make_unique<BpeTokenizer>(manifest.file("tokenizer").path);
        try {
            model_ = std::make_unique<Ort::Session>(factory.open(manifest.file("model").path));
        } catch (const Ort::Exception &e) {
            throw Error(SD_ASR_MODEL_LOAD_FAILED, std::string("ONNX Runtime failed to load model: ") + e.what());
        }
        expect_names(*model_, true, {"input_ids", "attention_mask"}, "model");
        expect_names(*model_, false, {"logits"}, "model");
        const auto shape = output_shape(*model_, 0);
        if (shape.size() != 3 || shape[2] != int64_t(labels_.size())) {
            throw Error(SD_ASR_INVALID_MODEL, "model output does not match params.labels");
        }
    }

    FamilyResult transcribe(const std::vector<float> &, RunContext &) override {
        throw Error(SD_ASR_INVALID_ARGUMENT, "this model restores punctuation; it does not transcribe audio");
    }

    std::string punctuate(const std::string &text, RunContext &context) override {
        const std::vector<PunctWord> words = split_punct_words(text);
        if (words.empty()) return text;

        std::vector<int64_t> ids;
        std::vector<size_t> word_last;  // index into ids of each word's last token
        for (const auto &w : words) {
            const auto pieces = tokenizer_->encode_word(w.core);
            ids.insert(ids.end(), pieces.begin(), pieces.end());
            word_last.push_back(ids.size() - 1);
        }

        std::vector<int> token_labels(ids.size(), 0);
        size_t start = 0;
        for (;;) {
            const size_t end = std::min(ids.size(), start + size_t(chunk_tokens_));
            run_chunk(ids, start, end, token_labels, end == ids.size() ? end : end - size_t(overlap_tokens_),
                      context);
            if (end == ids.size()) break;
            start = end - size_t(overlap_tokens_);
        }

        std::vector<std::string> labels;
        labels.reserve(words.size());
        for (size_t last : word_last) labels.push_back(labels_[size_t(token_labels[last])]);
        return merge_punct_labels(words, labels);
    }

private:
    // Labels tokens [start, keep_to) from a forward pass over [start, end)
    // framed by CLS/SEP.
    void run_chunk(const std::vector<int64_t> &ids, size_t start, size_t end, std::vector<int> &token_labels,
                   size_t keep_to, RunContext &context) {
        std::vector<int64_t> input;
        input.reserve(end - start + 2);
        input.push_back(cls_id_);
        input.insert(input.end(), ids.begin() + long(start), ids.begin() + long(end));
        input.push_back(sep_id_);
        std::vector<int64_t> mask(input.size(), 1);
        const int64_t shape[2] = {1, int64_t(input.size())};
        Ort::Value inputs[2] = {
            Ort::Value::CreateTensor<int64_t>(memory_, input.data(), input.size(), shape, 2),
            Ort::Value::CreateTensor<int64_t>(memory_, mask.data(), mask.size(), shape, 2),
        };
        const char *in_names[] = {"input_ids", "attention_mask"};
        const char *out_names[] = {"logits"};
        auto out = model_->Run(*context.run_options, in_names, inputs, 2, out_names, 1);
        check_cancelled(context);

        const auto out_shape = out[0].GetTensorTypeAndShapeInfo().GetShape();
        const size_t classes = labels_.size();
        if (out_shape.size() != 3 || out_shape[1] != int64_t(input.size()) || out_shape[2] != int64_t(classes)) {
            throw Error(SD_ASR_INFERENCE_FAILED, "unexpected logits shape");
        }
        const float *logits = out[0].GetTensorData<float>();
        for (size_t k = start; k < keep_to; ++k) {
            const float *row = logits + (k - start + 1) * classes;  // +1: CLS
            token_labels[k] = int(std::max_element(row, row + classes) - row);
        }
    }

    Ort::MemoryInfo memory_;
    std::unique_ptr<BpeTokenizer> tokenizer_;
    std::unique_ptr<Ort::Session> model_;
    std::vector<std::string> labels_;
    int64_t cls_id_ = 0, sep_id_ = 0, chunk_tokens_ = 0, overlap_tokens_ = 0;
};

}  // namespace

std::unique_ptr<ModelFamily> create_modernbert_punct_family(const Manifest &manifest, const SessionFactory &factory) {
    return std::make_unique<ModernBertPunctFamily>(manifest, factory);
}

}  // namespace sdasr
