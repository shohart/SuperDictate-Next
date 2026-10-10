// Shared internal types for the sd_asr runtime. Never exported.
#pragma once

#include <stdexcept>
#include <string>

#include "nlohmann/json.hpp"
#include "sd_asr.h"

namespace sdasr {

using json = nlohmann::json;

// Every internal failure is thrown as an Error carrying the C ABI status it
// maps to; the ABI layer (sd_asr.cpp) is the only place that catches and
// converts to {"category":..., "message":...}.
class Error : public std::runtime_error {
public:
    Error(sd_asr_status status, const std::string &message)
        : std::runtime_error(message), status_(status) {}
    sd_asr_status status() const { return status_; }

private:
    sd_asr_status status_;
};

}  // namespace sdasr
