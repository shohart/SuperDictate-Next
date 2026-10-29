#include "family.h"

namespace sdasr {

std::string ModelFamily::punctuate(const std::string &, RunContext &) {
    throw Error(SD_ASR_INVALID_ARGUMENT, "this model transcribes audio; it does not restore punctuation");
}

const hotwords::PhraseTokenizer *ModelFamily::hotword_tokenizer(std::string &reason) const {
    reason = "this model family does not support hotwords";
    return nullptr;
}

std::unique_ptr<ModelFamily> create_model_family(const Manifest &manifest, const SessionFactory &factory) {
    if (manifest.family == "nemo_tdt") return create_nemo_tdt_family(manifest, factory);
    if (manifest.family == "gigaam_rnnt") return create_gigaam_rnnt_family(manifest, factory);
    if (manifest.family == "modernbert_punct") return create_modernbert_punct_family(manifest, factory);
    throw Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY, "unsupported model family '" + manifest.family + "'");
}

}  // namespace sdasr
