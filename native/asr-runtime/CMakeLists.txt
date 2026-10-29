# SuperDictate cross-platform ASR runtime (docs/specs/cross-platform-onnx-asr-spec.md).
#
#   scripts/fetch-onnxruntime.sh            # once per platform
#   cmake -S native/asr-runtime -B native/asr-runtime/build -DCMAKE_BUILD_TYPE=Release
#   cmake --build native/asr-runtime/build -j
#   ctest --test-dir native/asr-runtime/build --output-on-failure
cmake_minimum_required(VERSION 3.20)
project(sd_asr_runtime LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

# --- Pinned ONNX Runtime SDK -------------------------------------------------
set(SD_ASR_ORT_VERSION "1.23.2")
if(WIN32)
  set(_sd_ort_platform "win-x64")
elseif(APPLE)
  if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64" OR (NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "arm64"))
    set(_sd_ort_platform "osx-arm64")
  else()
    set(_sd_ort_platform "osx-x86_64")
  endif()
else()
  set(_sd_ort_platform "linux-x64")
endif()
set(SD_ASR_ORT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/${_sd_ort_platform}"
    CACHE PATH "Extracted ONNX Runtime ${SD_ASR_ORT_VERSION} SDK (scripts/fetch-onnxruntime.sh)")
if(NOT EXISTS "${SD_ASR_ORT_ROOT}/include/onnxruntime_cxx_api.h")
  message(FATAL_ERROR "ONNX Runtime SDK not found at ${SD_ASR_ORT_ROOT}. Run scripts/fetch-onnxruntime.sh ${_sd_ort_platform}")
endif()
file(READ "${SD_ASR_ORT_ROOT}/VERSION_NUMBER" _sd_ort_found_version)
string(STRIP "${_sd_ort_found_version}" _sd_ort_found_version)
if(NOT _sd_ort_found_version STREQUAL SD_ASR_ORT_VERSION)
  message(FATAL_ERROR "ONNX Runtime ${_sd_ort_found_version} found, ${SD_ASR_ORT_VERSION} required (one ABI on every platform)")
endif()

add_library(onnxruntime SHARED IMPORTED GLOBAL)
target_include_directories(onnxruntime INTERFACE "${SD_ASR_ORT_ROOT}/include")
if(WIN32)
  set_target_properties(onnxruntime PROPERTIES
    IMPORTED_LOCATION "${SD_ASR_ORT_ROOT}/lib/onnxruntime.dll"
    IMPORTED_IMPLIB "${SD_ASR_ORT_ROOT}/lib/onnxruntime.lib")
elseif(APPLE)
  set_target_properties(onnxruntime PROPERTIES
    IMPORTED_LOCATION "${SD_ASR_ORT_ROOT}/lib/libonnxruntime.${SD_ASR_ORT_VERSION}.dylib"
    IMPORTED_SONAME "@rpath/libonnxruntime.${SD_ASR_ORT_VERSION}.dylib")
else()
  set_target_properties(onnxruntime PROPERTIES
    IMPORTED_LOCATION "${SD_ASR_ORT_ROOT}/lib/libonnxruntime.so.${SD_ASR_ORT_VERSION}"
    IMPORTED_SONAME "libonnxruntime.so.1")
endif()

# --- Core library ------------------------------------------------------------
add_library(sd_asr STATIC
  src/audio.cpp
  src/manifest.cpp
  src/ort_session.cpp
  src/sd_asr.cpp
  src/sha256.cpp
  src/families/family.cpp
  src/families/family_util.cpp
  src/families/bpe_tokenizer.cpp
  src/families/gigaam_rnnt.cpp
  src/families/hotwords.cpp
  src/families/modernbert_punct.cpp
  src/families/nemo_tdt.cpp
  src/families/punct_text.cpp
)
target_include_directories(sd_asr
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_link_libraries(sd_asr PUBLIC onnxruntime)
if(MSVC)
  target_compile_options(sd_asr PRIVATE /W4 /utf-8)
else()
  target_compile_options(sd_asr PRIVATE -Wall -Wextra)
endif()

find_package(Threads REQUIRED)

add_library(sd_asr_ipc STATIC src/ipc.cpp)
target_include_directories(sd_asr_ipc PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")

# Executables find the ORT shared library next to themselves (Windows,
# Linux dev) or in ../Frameworks inside the macOS .app bundle.
function(sd_asr_executable name)
  add_executable(${name} ${ARGN})
  target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${CMAKE_CURRENT_SOURCE_DIR}/third_party" "${CMAKE_CURRENT_SOURCE_DIR}/tools")
  target_link_libraries(${name} PRIVATE sd_asr sd_asr_ipc Threads::Threads)
  if(APPLE)
    set_target_properties(${name} PROPERTIES
      BUILD_RPATH "${SD_ASR_ORT_ROOT}/lib"
      INSTALL_RPATH "@executable_path/../Frameworks")
  elseif(UNIX)
    set_target_properties(${name} PROPERTIES BUILD_RPATH "${SD_ASR_ORT_ROOT}/lib" INSTALL_RPATH "$ORIGIN")
  endif()
  if(MSVC)
    target_compile_options(${name} PRIVATE /utf-8)
  endif()
endfunction()

sd_asr_executable(SuperDictateOnnxHost host/onnx_host_main.cpp)
sd_asr_executable(sd_asr_cli tools/sd_asr_cli.cpp)

if(WIN32)
  foreach(_exe SuperDictateOnnxHost sd_asr_cli)
    add_custom_command(TARGET ${_exe} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${SD_ASR_ORT_ROOT}/lib/onnxruntime.dll" "$<TARGET_FILE_DIR:${_exe}>")
  endforeach()
endif()

# --- Tests -------------------------------------------------------------------
option(SD_ASR_BUILD_TESTS "Build sd_asr tests" ON)
if(SD_ASR_BUILD_TESTS)
  enable_testing()
  sd_asr_executable(sd_asr_contract_tests tests/contract_tests.cpp)
  sd_asr_executable(sd_asr_ipc_tests tests/ipc_tests.cpp)
  sd_asr_executable(sd_asr_model_tests tests/model_tests.cpp)
  sd_asr_executable(sd_asr_punct_tests tests/punct_tests.cpp)
  add_test(NAME contract COMMAND sd_asr_contract_tests "${CMAKE_CURRENT_SOURCE_DIR}/assets")
  add_test(NAME ipc COMMAND sd_asr_ipc_tests)
  # Skips (exit 77) unless SD_ASR_TEST_MODEL_DIR / SD_ASR_TEST_GOLDEN_DIR are set.
  add_test(NAME model COMMAND sd_asr_model_tests "${CMAKE_CURRENT_SOURCE_DIR}/assets")
  set_tests_properties(model PROPERTIES SKIP_RETURN_CODE 77)
  # Skips (exit 77) unless SD_ASR_TEST_PUNCT_MODEL_DIR is set.
  add_test(NAME punct COMMAND sd_asr_punct_tests "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
  set_tests_properties(punct PROPERTIES SKIP_RETURN_CODE 77)
endif()
