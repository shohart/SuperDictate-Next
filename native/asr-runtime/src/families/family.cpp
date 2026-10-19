#include "family.h"

namespace sdasr {

std::unique_ptr<ModelFamily> create_model_family(const Manifest &manifest, const SessionFactory &factory) {
    if (manifest.family == "nemo_tdt") return create_nemo_tdt_family(manifest, factory);
    if (manifest.family == "gigaam_rnnt") return create_gigaam_rnnt_family(manifest, factory);
    throw Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY, "unsupported model family '" + manifest.family + "'");
}

}  // namespace sdasr
