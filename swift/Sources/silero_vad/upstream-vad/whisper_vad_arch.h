// Extracted verbatim (mechanically, via scripts/vendor-silero-vad.sh) from
// ggml-org/whisper.cpp's src/whisper-arch.h — the `vad_tensor` enum and its
// two lookup maps, which the VAD-specific tensor loader in whisper_vad.cpp
// uses to map named tensors in the ggml Silero VAD model file to ggml ops
// and canonical names. See PROVENANCE.md for the pinned commit.
//
// Do not hand-edit — re-run scripts/vendor-silero-vad.sh.
#pragma once

#include "ggml.h"

#include <map>

enum vad_tensor {
    VAD_TENSOR_STFT_BASIS,
    VAD_TENSOR_ENC_0_WEIGHT,
    VAD_TENSOR_ENC_0_BIAS,
    VAD_TENSOR_ENC_1_WEIGHT,
    VAD_TENSOR_ENC_1_BIAS,
    VAD_TENSOR_ENC_2_WEIGHT,
    VAD_TENSOR_ENC_2_BIAS,
    VAD_TENSOR_ENC_3_WEIGHT,
    VAD_TENSOR_ENC_3_BIAS,
    VAD_TENSOR_LSTM_WEIGHT_IH,
    VAD_TENSOR_LSTM_WEIGHT_HH,
    VAD_TENSOR_LSTM_BIAS_IH,
    VAD_TENSOR_LSTM_BIAS_HH,
    VAD_TENSOR_FINAL_CONV_WEIGHT,
    VAD_TENSOR_FINAL_CONV_BIAS,
};

static const std::map<vad_tensor, ggml_op> VAD_TENSOR_OPS = {
    {VAD_TENSOR_STFT_BASIS,          GGML_OP_IM2COL},
    {VAD_TENSOR_ENC_0_WEIGHT,        GGML_OP_IM2COL},
    {VAD_TENSOR_ENC_0_BIAS,          GGML_OP_ADD},
    {VAD_TENSOR_ENC_1_WEIGHT,        GGML_OP_IM2COL},
    {VAD_TENSOR_ENC_1_BIAS,          GGML_OP_ADD},
    {VAD_TENSOR_ENC_2_WEIGHT,        GGML_OP_IM2COL},
    {VAD_TENSOR_ENC_2_BIAS,          GGML_OP_ADD},
    {VAD_TENSOR_ENC_3_WEIGHT,        GGML_OP_IM2COL},
    {VAD_TENSOR_ENC_3_BIAS,          GGML_OP_ADD},

    {VAD_TENSOR_LSTM_WEIGHT_IH,      GGML_OP_MUL_MAT},
    {VAD_TENSOR_LSTM_WEIGHT_HH,      GGML_OP_MUL_MAT},
    {VAD_TENSOR_LSTM_BIAS_IH,        GGML_OP_ADD},
    {VAD_TENSOR_LSTM_BIAS_HH,        GGML_OP_ADD},

    {VAD_TENSOR_FINAL_CONV_WEIGHT,   GGML_OP_IM2COL},
    {VAD_TENSOR_FINAL_CONV_BIAS,     GGML_OP_ADD}
};

static const std::map<vad_tensor, const char *> VAD_TENSOR_NAMES = {
    {VAD_TENSOR_STFT_BASIS,          "_model.stft.forward_basis_buffer"},
    {VAD_TENSOR_ENC_0_WEIGHT,        "_model.encoder.0.reparam_conv.weight"},
    {VAD_TENSOR_ENC_0_BIAS,          "_model.encoder.0.reparam_conv.bias"},
    {VAD_TENSOR_ENC_1_WEIGHT,        "_model.encoder.1.reparam_conv.weight"},
    {VAD_TENSOR_ENC_1_BIAS,          "_model.encoder.1.reparam_conv.bias"},
    {VAD_TENSOR_ENC_2_WEIGHT,        "_model.encoder.2.reparam_conv.weight"},
    {VAD_TENSOR_ENC_2_BIAS,          "_model.encoder.2.reparam_conv.bias"},
    {VAD_TENSOR_ENC_3_WEIGHT,        "_model.encoder.3.reparam_conv.weight"},
    {VAD_TENSOR_ENC_3_BIAS,          "_model.encoder.3.reparam_conv.bias"},
    {VAD_TENSOR_LSTM_WEIGHT_IH,      "_model.decoder.rnn.weight_ih"},
    {VAD_TENSOR_LSTM_WEIGHT_HH,      "_model.decoder.rnn.weight_hh"},
    {VAD_TENSOR_LSTM_BIAS_IH,        "_model.decoder.rnn.bias_ih"},
    {VAD_TENSOR_LSTM_BIAS_HH,        "_model.decoder.rnn.bias_hh"},
    {VAD_TENSOR_FINAL_CONV_WEIGHT,   "_model.decoder.decoder.2.weight"},
    {VAD_TENSOR_FINAL_CONV_BIAS,     "_model.decoder.decoder.2.bias"}
};
