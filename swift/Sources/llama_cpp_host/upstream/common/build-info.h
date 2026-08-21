// Hand-authored replacement for upstream's CMake `configure_file`'d
// build-info.h/.cpp -- SwiftPM has no configure_file step, so this fixes
// the values instead of stamping them at build time. See
// scripts/vendor-llama-cpp.sh for the pinned commit these correspond to.
#pragma once
int          llama_build_number(void);
const char * llama_commit(void);
const char * llama_compiler(void);
const char * llama_build_target(void);
