import Foundation

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
