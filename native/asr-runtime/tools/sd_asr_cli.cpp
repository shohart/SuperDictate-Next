// sd_asr_cli — load one model through the C ABI and transcribe WAV files.
// Development / diagnostics tool; prints one result JSON per line.
//
//   sd_asr_cli --model <dir> --assets <dir> [--provider cpu] [--threads N]
//              [--text-only] [--repeat N] file.wav...
//   sd_asr_cli --model <punctuation model dir> --punctuate [--text-only] < lines.txt
//              (one input line -> one output line)
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "sd_asr.h"
#include "wav.h"

int main(int argc, char **argv) {
    std::string model_dir, assets_dir, provider = "auto";
    int threads = 0;
    int repeat = 1;
    bool text_only = false;
    bool punctuate = false;
    std::vector<std::string> files;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value = [&](const char *name) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", name);
                std::exit(64);
            }
            return argv[++i];
        };
        if (arg == "--model") model_dir = value("--model");
        else if (arg == "--assets") assets_dir = value("--assets");
        else if (arg == "--provider") provider = value("--provider");
        else if (arg == "--threads") threads = std::stoi(value("--threads"));
        else if (arg == "--repeat") repeat = std::stoi(value("--repeat"));
        else if (arg == "--text-only") text_only = true;
        else if (arg == "--punctuate") punctuate = true;
        else files.push_back(arg);
    }
    if (model_dir.empty() || (files.empty() && !punctuate)) {
        std::fprintf(stderr, "usage: sd_asr_cli --model <dir> [--assets <dir>] [--provider p] [--threads n] "
                             "[--repeat n] [--text-only] file.wav...\n");
        return 64;
    }

    nlohmann::json config = {{"model_directory", model_dir}, {"assets_directory", assets_dir},
                             {"provider", provider}, {"intra_op_threads", threads}};
    sd_asr_handle *handle = nullptr;
    char *error = nullptr;
    if (sd_asr_create(config.dump().c_str(), &handle, &error) != SD_ASR_OK) {
        std::fprintf(stderr, "create failed: %s\n", error ? error : "?");
        sd_asr_free(error);
        return 1;
    }
    char *status = nullptr;
    sd_asr_get_status(handle, &status);
    std::fprintf(stderr, "%s\n", status);
    sd_asr_free(status);

    int exit_code = 0;
    if (punctuate) {
        std::string line;
        while (std::getline(std::cin, line)) {
            char *result = nullptr;
            if (sd_asr_punctuate_utf8(handle, line.c_str(), nullptr, &result, &error) != SD_ASR_OK) {
                std::fprintf(stderr, "punctuate failed: %s\n", error ? error : "?");
                sd_asr_free(error);
                error = nullptr;
                exit_code = 1;
                std::printf("\n");
                continue;
            }
            if (text_only) {
                std::printf("%s\n", nlohmann::json::parse(result)["text"].get<std::string>().c_str());
            } else {
                std::printf("%s\n", result);
            }
            std::fflush(stdout);
            sd_asr_free(result);
        }
    }
    for (const auto &file : files) {
        sdasr::WavAudio wav;
        std::string wav_error;
        if (!sdasr::read_wav_mono(file, wav, wav_error)) {
            std::fprintf(stderr, "%s: %s\n", file.c_str(), wav_error.c_str());
            exit_code = 1;
            continue;
        }
        for (int r = 0; r < repeat; ++r) {
            char *result = nullptr;
            const sd_asr_status rc = sd_asr_transcribe_pcm_f32(handle, wav.samples.data(), wav.samples.size(),
                                                               wav.sample_rate, nullptr, &result, &error);
            if (rc != SD_ASR_OK) {
                std::fprintf(stderr, "%s: %s\n", file.c_str(), error ? error : "?");
                sd_asr_free(error);
                error = nullptr;
                exit_code = 1;
                break;
            }
            if (text_only) {
                std::printf("%s\n", nlohmann::json::parse(result)["text"].get<std::string>().c_str());
            } else {
                std::printf("%s\n", result);
            }
            sd_asr_free(result);
        }
    }
    sd_asr_destroy(handle);
    return exit_code;
}
