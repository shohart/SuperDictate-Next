import Foundation
import parakeet_cpp

/// Errors raised around the ONNX ASR helper and the benchmark's audio
/// loading. The helper's own transport failures are `OnnxAsrEngineError`.
enum ASREngineError: LocalizedError {
    case inferenceFailed(String)
    case tokenDecodeFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .inferenceFailed(let detail):
            return "Speech recognition failed: \(detail)"
        case .tokenDecodeFailed(let detail):
            return "Failed to decode token timestamps: \(detail)"
        case .emptyAudio:
            return "No audio samples to transcribe"
        }
    }
}

/// Side-effect-free probe: does ggml's device registry enumerate a usable
/// Vulkan GPU/IGPU? Speech recognition never uses it (CPU only); it drives
/// the "LLM on GPU (Vulkan)" menu item. The LLM host has its own ggml copy,
/// so this only answers "is there a Vulkan device on this Mac".
func vulkanGPUAvailable() -> Bool {
    sd_parakeet_vulkan_available() != 0
}

/// Human-readable description of the first enumerated Vulkan device
/// (e.g. "AMD Radeon RX 6600 (MoltenVK)"), or "" if none is available.
func vulkanGPUDeviceDescription() -> String {
    String(cString: sd_parakeet_vulkan_device_description())
}
