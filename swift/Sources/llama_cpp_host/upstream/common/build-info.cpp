// Hand-authored: see build-info.h.
#include "build-info.h"
#include <string>

int llama_build_number(void)   { return 0; }
const char * llama_commit(void)       { return "d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd"; }
const char * llama_compiler(void)     { return "SuperDictateLLMHost"; }
const char * llama_build_target(void) { return "x86_64-apple-macosx"; }
const char * llama_build_info(void) {
    static std::string s = std::string("SuperDictateLLMHost-") + "d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd";
    return s.c_str();
}
