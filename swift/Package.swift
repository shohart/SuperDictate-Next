// swift-tools-version: 6.0
//
// SuperDictate — a Swift push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet TDT v3 on the Apple Neural Engine. macOS 14
// (Sonoma) minimum. The Hardened Runtime microphone entitlement
// (`com.apple.security.device.audio-input` in `entitlements.plist`)
// is what Tahoe 26 checks before exposing the app in Privacy &
// Security → Microphone; on macOS 14–25 the legacy sandbox key
// (`com.apple.security.device.microphone`) is the fallback. Both
// ship in the same build so a single notarised binary works
// across the supported range.
import PackageDescription

let package = Package(
    name: "Parakey",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "Parakey", targets: ["Parakey"]),
        // A SEPARATE executable, deliberately never a dependency of
        // "Parakey" above -- see the SuperDictateLLMHost target's own
        // comment below for why (two independently vendored ggml copies
        // cannot share one linked binary).
        .executable(name: "SuperDictateLLMHost", targets: ["SuperDictateLLMHost"]),
    ],
    dependencies: [],
    targets: [
        // silero_vad — the Silero VAD (upstream-vad/, extracted from
        // whisper.cpp by scripts/vendor-silero-vad.sh) over a CPU-only ggml
        // v0.13.0 core (upstream/, scripts/vendor-ggml-core.sh). It only
        // finds pauses for long-dictation segmentation; speech recognition
        // runs in the SuperDictateOnnxHost helper and the GPU belongs to
        // SuperDictateLLMHost, so this target has no Vulkan and links no
        // MoltenVK. Non-x86 ggml-cpu arch variants are stripped at vendor
        // time. amx/ is compiled (ggml-cpu.cpp calls
        // ggml_backend_amx_buffer_type()/ggml_cpu_has_amx_int8()
        // unconditionally); its AMX code paths stay inert without
        // __AMX_INT8__/__AVX512VNNI__, which this target does not define.
        .target(
            name: "silero_vad",
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                .headerSearchPath("upstream-vad"),
                .headerSearchPath("upstream-vad/include"),
                // Intel ISA flags proven on the target machine (Xeon
                // E5-2678 v3 / E5-2696 v3).
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-Wno-ambiguous-macro",
                ]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                .headerSearchPath("upstream-vad"),
                .headerSearchPath("upstream-vad/include"),
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-Wno-ambiguous-macro",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "Parakey",
            dependencies: ["silero_vad"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // dev-run.sh and ship-swift.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
        // SuperDictateLLMHost — a minimal, hand-authored OpenAI-compatible
        // chat-completions HTTP host built on a vendored llama.cpp
        // (scripts/vendor-llama-cpp.sh; see swift/Sources/llama_cpp_host/
        // upstream/PROVENANCE.md for the exact pin). Deliberately its OWN
        // executableTarget/product, NEVER a dependency of "Parakey" above:
        // this target vendors its own independent copy of ggml (a
        // different pin than silero_vad/upstream's own, separately
        // vendored ggml v0.13.0), and SwiftPM statically links a target's
        // object files straight into whichever executable depends on it —
        // two independently vendored copies of ggml's flat C symbols
        // (ggml_init, the ggml_backend_reg singleton, etc.) in the same
        // linked binary is a guaranteed duplicate-symbol error. Instead,
        // this ships as its own separate binary in the .app
        // (Contents/Helpers/SuperDictateLLMHost, see scripts/build-app.sh)
        // that Parakey spawns as a subprocess and talks to over loopback
        // HTTP (LLMHostProcess.swift) via the same OpenAI-compatible
        // client (OpenAICompatibleClient.swift) used for a user-supplied
        // custom baseURL -- the two ggml copies never share an address
        // space.
        .executableTarget(
            name: "SuperDictateLLMHost",
            path: "Sources/llama_cpp_host",
            // upstream/ggml-vulkan/vulkan-shaders/ holds loose
            // pre-compiled `.spv` binaries (not source), loaded at runtime
            // by explicit file path (ggml-vulkan-shaders-runtime.cpp), not
            // compiled in -- and never through SwiftPM `resources:`.
            // scripts/build-test-app.sh / build-app.sh copy this directory
            // into the bundle as Contents/Resources/llama-vulkan-shaders,
            // where the host looks for it (superdictate_llm_host_main.cpp).
            exclude: [
                "upstream/ggml-vulkan/vulkan-shaders",
            ],
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                // Vulkan backend -- the app's only GPU path. The "LLM on
                // GPU (Vulkan)" toggle (Settings.llmUseGPU) picks it at
                // runtime via `--gpu-layers`, and `--list-devices` reports
                // what it can see (LLMHostProcess.swift, LLMGPUProbe.swift,
                // superdictate_llm_host_main.cpp); this define only makes
                // the backend available to register.
                .define("GGML_USE_VULKAN"),
                .define("LLAMA_VERSION", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .define("LLAMA_COMMIT", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .define("GGML_VERSION", to: "\"0.20.2\""),
                .define("GGML_COMMIT", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                // common/ before src/: common/jinja/*.cpp quote-includes
                // bare "unicode.h" with no same-directory match, and both
                // src/ and common/ vendor their OWN same-named-but-
                // different unicode.h/.cpp (two distinct upstream files) --
                // search-path order is the only thing disambiguating which
                // one a common/jinja/ file resolves to for a non-same-
                // directory quote-include. Files inside src/ itself always
                // resolve their own "unicode.h" via the same-directory
                // rule first, so this order never affects them.
                .headerSearchPath("upstream/common"),
                .headerSearchPath("upstream/src"),
                .headerSearchPath("upstream/ggml-cpu"),
                .headerSearchPath("upstream/ggml-vulkan"),
                .headerSearchPath("upstream/vendor"),
                .headerSearchPath("upstream/vendor/cpp-httplib"),
                // Intel ISA flags plus the Homebrew Vulkan headers (the
                // `opt/` symlink, not a versioned Cellar path) — proven on
                // the real target machine.
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-Wno-ambiguous-macro",
                    "-I/usr/local/opt/vulkan-headers/include",
                ]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_USE_VULKAN"),
                .define("LLAMA_VERSION", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .define("LLAMA_COMMIT", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .define("GGML_VERSION", to: "\"0.20.2\""),
                .define("GGML_COMMIT", to: "\"d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                // common/ before src/: common/jinja/*.cpp quote-includes
                // bare "unicode.h" with no same-directory match, and both
                // src/ and common/ vendor their OWN same-named-but-
                // different unicode.h/.cpp (two distinct upstream files) --
                // search-path order is the only thing disambiguating which
                // one a common/jinja/ file resolves to for a non-same-
                // directory quote-include. Files inside src/ itself always
                // resolve their own "unicode.h" via the same-directory
                // rule first, so this order never affects them.
                .headerSearchPath("upstream/common"),
                .headerSearchPath("upstream/src"),
                .headerSearchPath("upstream/ggml-cpu"),
                .headerSearchPath("upstream/ggml-vulkan"),
                .headerSearchPath("upstream/vendor"),
                .headerSearchPath("upstream/vendor/cpp-httplib"),
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-Wno-ambiguous-macro",
                    "-I/usr/local/opt/vulkan-headers/include",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                // Vulkan/MoltenVK, statically linked: MoltenVK's static
                // archive is linked directly so its Vulkan-ABI entry points
                // resolve straight into this binary, no Khronos loader /
                // Homebrew runtime dependency.
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                // The link step failed with
                // undefined MTLCreateSystemDefaultDevice/MTL* ObjC class
                // symbols from libMoltenVK.a until Metal was linked
                // explicitly (verified empirically).
                .linkedFramework("Metal"),
                .linkedLibrary("objc"),
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "/usr/local/opt/molten-vk/lib/libMoltenVK.a",
                ]),
            ]
        ),
    ],
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)
