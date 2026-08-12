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
    ],
    dependencies: [],
    targets: [
        .target(
            name: "parakeet_cpp",
            // Non-x86 arch variants were already stripped by
            // scripts/vendor-parakeet-cpp.sh at vendor time (see that
            // script's `rm -rf` block), so nothing needs excluding there.
            // amx/ is kept in-tree and compiled (ggml-cpu.cpp calls
            // ggml_backend_amx_buffer_type()/ggml_cpu_has_amx_int8()
            // unconditionally — same as this fork's already-proven
            // whisper_cpp target, which also compiled it in unguarded);
            // its actual AMX codegen paths stay inert without
            // __AMX_INT8__/__AVX512VNNI__, which this target does not
            // define.
            //
            // upstream/ggml-vulkan/vulkan-shaders/ IS excluded: it holds
            // loose pre-compiled `.spv` binaries (not source), loaded at
            // runtime by explicit file path (see
            // scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.cpp)
            // — never through SwiftPM's `resources:` mechanism, which
            // bundles a `<Package>_<Target>.bundle` directory that
            // `codesign --deep` won't accept as a signable component
            // (same rationale as the Parakey executable target's own
            // `resources:` comment below). scripts/build-app.sh copies this
            // directory into Contents/Resources/vulkan-shaders/ directly
            // for the shipped .app; dev-run.sh does the equivalent for
            // `swift run` builds that need it configured via
            // ggml_vk_shaders_set_directory().
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
                // Vulkan backend (Phase 5 of the parakeet.cpp migration
                // plan). Mirrors the deleted whisper_cpp target's own
                // GGML_USE_VULKAN addition exactly (see `git show
                // 1bb8ae4^:swift/Package.swift`) — same define, gated the
                // same way in ggml-backend-reg.cpp
                // (upstream/ggml-backend-reg.cpp:45,125-128) to register
                // ggml_backend_vk_reg() into the device registry that
                // pk::Backend / sd_parakeet_vulkan_available() both walk.
                .define("GGML_USE_VULKAN"),
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .define("PARAKEET_VERSION", to: "\"0.0.1\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                // ggml-vulkan-shaders-runtime.h is included from
                // include/parakeet_cpp_module.h (the umbrella header) so
                // Swift can call ggml_vk_shaders_set_directory(); it lives
                // under upstream/ggml-vulkan/, a directory this search path
                // makes reachable via quote-include from anywhere in the
                // target (ggml-vulkan.cpp's own #include
                // "ggml-vulkan-shaders.hpp" resolves via the
                // same-directory-as-includer tier and doesn't need this,
                // but include/parakeet_cpp_module.h does).
                .headerSearchPath("upstream/ggml-vulkan"),
                // Silero VAD (scripts/vendor-silero-vad.sh), a SEPARATE,
                // additive vendor tree from upstream/ above (see
                // upstream-vad/PROVENANCE.md) -- not yet wired into the
                // umbrella header/bridge (that's a later task), but its
                // translation unit (upstream-vad/whisper_vad.cpp) is
                // auto-discovered and compiled as part of this same target,
                // so its own quote-includes ("include/whisper_vad.h",
                // "whisper_vad_arch.h") need to resolve, plus the ggml
                // headers it depends on (already reachable via the
                // "upstream/include" search path above).
                .headerSearchPath("upstream-vad"),
                .headerSearchPath("upstream-vad/include"),
                // Same Intel-ISA flags this fork already carries for
                // whisper_cpp's ggml build (see git history / the removed
                // whisper_cpp target this replaces) — proven on the real
                // target machine (Intel Xeon E5-2678 v3). The vulkan-headers
                // -I flag is the same Homebrew `opt/` symlink path (not a
                // versioned Cellar path) the deleted whisper_cpp target used,
                // for brew-upgrade resilience.
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
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .define("PARAKEET_VERSION", to: "\"0.0.1\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                // ggml-vulkan-shaders-runtime.h is included from
                // include/parakeet_cpp_module.h (the umbrella header) so
                // Swift can call ggml_vk_shaders_set_directory(); it lives
                // under upstream/ggml-vulkan/, a directory this search path
                // makes reachable via quote-include from anywhere in the
                // target (ggml-vulkan.cpp's own #include
                // "ggml-vulkan-shaders.hpp" resolves via the
                // same-directory-as-includer tier and doesn't need this,
                // but include/parakeet_cpp_module.h does).
                .headerSearchPath("upstream/ggml-vulkan"),
                // Silero VAD (scripts/vendor-silero-vad.sh) -- see the
                // matching comment in cSettings above.
                .headerSearchPath("upstream-vad"),
                .headerSearchPath("upstream-vad/include"),
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-Wno-ambiguous-macro",
                    "-I/usr/local/opt/vulkan-headers/include",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                // Vulkan/MoltenVK, statically linked — same frameworks +
                // static-archive approach proven for whisper_cpp (see `git
                // show 1bb8ae4^:swift/Package.swift`). Linking MoltenVK's
                // static archive directly (not -lMoltenVK/-lvulkan) means
                // MoltenVK's own Vulkan-ABI entry points (vkCreateInstance
                // etc.) resolve straight into this binary — no Khronos
                // loader, no ICD manifest lookup, no runtime Homebrew
                // dependency. `otool -L` on the final app binary must show
                // none of /usr/local/, /opt/homebrew/, Cellar,
                // libMoltenVK.dylib, libvulkan.dylib — see the Phase 5
                // integration report for the verification run.
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("objc"),
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "/usr/local/opt/molten-vk/lib/libMoltenVK.a",
                ]),
            ]
        ),
        .executableTarget(
            name: "Parakey",
            dependencies: ["parakeet_cpp"],
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
    ],
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)
