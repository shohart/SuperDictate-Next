# The Windows engines\ directory: the Silero VAD, and the experimental
# local LLM host.
#
# Both are built from the same vendored sources as the macOS app, compiled
# file for file the way swift/Package.swift compiles them:
#
#   silero-vad.dll             swift/Sources/silero_vad/upstream{,-vad}
#                              (whisper.cpp's Silero VAD over a CPU-only
#                              ggml v0.13.0, whisper_vad_* exported)
#   superdictate-llm-host.exe  swift/Sources/llama_cpp_host (llama.cpp
#                              d59d455, statically linked). Experimental,
#                              not in release builds (SD_LLM_HOST): Windows
#                              post-processing goes through an
#                              OpenAI-compatible endpoint. CPU only unless
#                              SD_LLM_VULKAN, which needs the Vulkan SDK to
#                              build and the GPU driver's vulkan-1.dll to run.
#
# Two separate binaries for the same reason as on macOS: they vendor two
# different ggml pins, whose flat C symbols cannot share one image.
#
# Built by windows/tools/build-engines.ps1; needs VS 2022 (C++ workload)
# and CMake 3.20+.

cmake_minimum_required(VERSION 3.20)
project(superdictate_engines LANGUAGES C CXX)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "engines/ is the Windows x64 build")
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

option(SD_LLM_HOST "Build the experimental local LLM host" OFF)
option(SD_LLM_VULKAN "Give the LLM host the Vulkan backend (experimental)" OFF)

get_filename_component(SD_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../../../swift/Sources" ABSOLUTE)
set(SD_LLAMA "${SD_SOURCES}/llama_cpp_host")
set(SD_VAD "${SD_SOURCES}/silero_vad")

# Same ISA baseline as the macOS targets (-mavx2 -mfma -mf16c); ggml-cpu
# derives __FMA__/__F16C__ from __AVX2__ under MSVC itself.
set(SD_COMMON_OPTIONS /arch:AVX2 /utf-8 /bigobj /permissive- /Zc:__cplusplus /W0)
set(SD_COMMON_DEFINITIONS
  _CRT_SECURE_NO_WARNINGS _USE_MATH_DEFINES NOMINMAX WIN32_LEAN_AND_MEAN
  GGML_USE_CPU GGML_USE_LLAMAFILE)

# -- superdictate-llm-host.exe ---------------------------------------------

if(SD_LLM_HOST)
file(GLOB_RECURSE SD_LLAMA_SOURCES CONFIGURE_DEPENDS
  "${SD_LLAMA}/*.c" "${SD_LLAMA}/*.cpp")
# The .spv corpus is data (shipped next to the host), and ggml-blas.cpp is
# the Accelerate backend macOS links; Windows has no BLAS backend.
list(FILTER SD_LLAMA_SOURCES EXCLUDE REGEX "/vulkan-shaders/")
list(FILTER SD_LLAMA_SOURCES EXCLUDE REGEX "/ggml-blas\\.cpp$")
if(NOT SD_LLM_VULKAN)
  list(FILTER SD_LLAMA_SOURCES EXCLUDE REGEX "/ggml-vulkan/")
endif()

add_executable(superdictate-llm-host ${SD_LLAMA_SOURCES})
target_compile_options(superdictate-llm-host PRIVATE ${SD_COMMON_OPTIONS})
target_compile_definitions(superdictate-llm-host PRIVATE
  ${SD_COMMON_DEFINITIONS}
  LLAMA_VERSION="d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd"
  LLAMA_COMMIT="d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd"
  GGML_VERSION="0.20.2"
  GGML_COMMIT="d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd")
# Order matters, as in Package.swift: common/ before src/, because both
# vendor a different unicode.h and common/jinja/ resolves it by search path.
target_include_directories(superdictate-llm-host PRIVATE
  "${SD_LLAMA}/upstream"
  "${SD_LLAMA}/upstream/include"
  "${SD_LLAMA}/upstream/common"
  "${SD_LLAMA}/upstream/src"
  "${SD_LLAMA}/upstream/ggml-cpu"
  "${SD_LLAMA}/upstream/ggml-vulkan"
  "${SD_LLAMA}/upstream/vendor"
  "${SD_LLAMA}/upstream/vendor/cpp-httplib")
target_link_libraries(superdictate-llm-host PRIVATE ws2_32 crypt32)
if(SD_LLM_VULKAN)
  find_package(Vulkan REQUIRED)
  target_compile_definitions(superdictate-llm-host PRIVATE GGML_USE_VULKAN)
  target_link_libraries(superdictate-llm-host PRIVATE Vulkan::Vulkan)
endif()
endif()

# -- silero-vad.dll ---------------------------------------------------------

file(GLOB_RECURSE SD_VAD_SOURCES CONFIGURE_DEPENDS
  "${SD_VAD}/upstream/*.c" "${SD_VAD}/upstream/*.cpp"
  "${SD_VAD}/upstream-vad/*.cpp")
list(FILTER SD_VAD_SOURCES EXCLUDE REGEX "/ggml-blas\\.cpp$")

add_library(silero-vad SHARED ${SD_VAD_SOURCES})
# whisper_vad.h declares plain extern "C" functions with no export macro;
# exporting everything is what makes them reachable from ctypes.
set_target_properties(silero-vad PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_compile_options(silero-vad PRIVATE ${SD_COMMON_OPTIONS})
target_compile_definitions(silero-vad PRIVATE
  ${SD_COMMON_DEFINITIONS}
  GGML_VERSION="0.13.0"
  GGML_COMMIT="e705c5fed490514458bdd2eaddc43bd098fcce9b")
target_include_directories(silero-vad PRIVATE
  "${SD_VAD}/upstream"
  "${SD_VAD}/upstream/include"
  "${SD_VAD}/upstream/ggml-cpu"
  "${SD_VAD}/upstream-vad"
  "${SD_VAD}/upstream-vad/include")
