// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor (model download).
//
import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Model download helpers

/// Progress callback for `TranscriptionWorker.load` (fraction completed,
/// 0...1), forwarded to `downloadOnnxModelIfNeeded`.
typealias SpeechModelDownloadProgressHandler = @Sendable (Double) -> Void

/// Computes the SHA-256 digest of a single known file, hex-encoded.
///
/// This is intentionally separate from `ModelIntegrity.sha256Hex(of:relativePath:)`,
/// which verifies files within the previous ASR stack's CoreML manifest tree (relative-path
/// aware, part of the manifest-verification machinery above). This function has
/// a simpler job: verify one specific downloaded model file against a single
/// pinned checksum.
func sha256Hex(ofFileAt url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Regular-file-only guard (spec §4.2 items 1-2: "Treat the destination as a
/// known regular file only. Reject symlinks, directories and special
/// files."). Returns `false` for anything that isn't a plain regular file
/// (symlink, directory, device node, socket, etc.) — including the
/// nothing-there case, which callers treat as "no cached file yet", not a
/// safety violation.
func isPlainRegularFile(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFREG
}

// MARK: - GEC correction model download + checksum verification
//
// Same download/verify/atomic-rename shape as downloadParakeetModelIfNeeded
// above, for the correction-mode model. The ship form is TWO files:
//
// 1. Base weights: Qwen3.5-0.8B vanilla Q6_K (bartowski GGUF, pinned
//    revision), 0.69 GB.
// 2. A ~2.9 MB LoRA adapter GGUF: VoiceScribe/qwen3-5-0.8b-dictation-
//    corrector-lora-adapter (V15 R-3), a Russian-dictation-corrector LoRA
//    trained EXACTLY on this app's task (post-ASR cleanup of Russian
//    dictation, foreign-term/script normalization гитхаб -> GitHub,
//    conservative editing policy). The adapter is converted to GGUF once
//    (upstream llama.cpp convert_lora_to_gguf.py @ the same commit the
//    llama_cpp_host tree is vendored at, --outtype f32) and committed to
//    THIS repository at models/gec-lora-adapter.gguf; the app downloads it
//    from this repo's raw GitHub URL, checksum-pinned like everything else.
//
// Model-selection history (all verified empirically against the real
// SuperDictateLLMHost via curl, see LLMPostprocessingPrompts.swift for the
// prompt side of the same story):
//   - loqira/Qwen3.5-0.8B-GEC-KAZ-RUS-ENG (the atom's original pick):
//     catastrophic forgetting, doesn't know the terms. Rejected.
//   - vanilla Qwen3.5-0.8B zero-shot: knows terms, no discipline
//     (hallucinates shell commands). Rejected.
//   - vanilla Qwen3.5-4B Q6_K + few-shot prompt: good quality, but 3.8 GB
//     download and multi-second correction latency. Superseded.
//   - synterr-nlp/bea2026-gec-adapters LoRA: regressed normalization
//     (English GEC benchmark, not this task). Rejected.
//   - VoiceScribe dictation-corrector LoRA on Qwen3.5-0.8B (CURRENT):
//     trained on this exact task; ~2.8 s per correction on CPU (measured),
//     0.69 GB download, excellent term normalization and request-echo
//     safety. Known weaknesses, accepted with mitigations: occasionally
//     drops the input's leading word ("я"/"расскажи"/...) and rarely
//     hallucinates unfamiliar terms (кубернейтс -> "Cerebral" seen once) —
//     both are caught by LLMCorrectionGuardrail (leading-word preservation
//     check) which falls back to the uncorrected input, per this pipeline's
//     never-lose-text policy. Punctuation fixing is also weaker than the
//     4B's — accepted: this app already has deterministic punctuation/final
//     period layers of its own.
//
// The adapter is rsLoRA (PEFT use_rslora=true): effective scale is
// alpha/sqrt(rank) = 80/4 = 20, while llama.cpp's loader computes
// adapter_scale * alpha/rank — so the host must be launched with
// --lora-scale 4.0 (4.0 * 80/16 == 20). That constant lives here
// (GEC_LORA_SCALE) next to the pins it derives from, and is threaded
// through LLMHostProcess/SuperDictateLLMHost (--lora-scale flag).
//
// Pinned to specific revisions, never `main` — same rationale as the
// Parakeet pin. Downloaded on demand only, exactly once the user enables
// "Исправлять ошибки" (TextPostprocessingMode.correction) — never bundled
// into the .app, never fetched eagerly at first launch, matching the
// Parakeet ASR model's own on-demand policy.

enum GECModelDownloadError: LocalizedError {
    // Neutral "LLM model" wording, not "GEC model": this error type is
    // shared by the fast-tier, YandexGPT, and LoRA downloads below, and
    // these strings surface verbatim in the Settings UI.
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case downloadFailed(underlying: Error)
    case httpError(statusCode: Int)
    case unsafeDestination(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let expected, let actual):
            return "Downloaded LLM model checksum mismatch: expected \(expected), got \(actual)"
        case .sizeMismatch(let expected, let actual):
            return "Downloaded LLM model size mismatch: expected \(expected) bytes, got \(actual) bytes"
        case .downloadFailed(let underlying):
            return "Failed to download LLM model: \(underlying.localizedDescription)"
        case .httpError(let statusCode):
            return "LLM model download failed with HTTP \(statusCode)"
        case .unsafeDestination(let detail):
            return "Refusing unsafe LLM model destination: \(detail)"
        }
    }
}

// Base weights: Qwen3.5-0.8B vanilla (NOT Instruct, NOT -Base) Q6_K.
let GEC_MODEL_REPOSITORY = "bartowski/Qwen_Qwen3.5-0.8B-GGUF"
let GEC_MODEL_REVISION = "f36b1ea49a332ede8fe5f389bbf5b3575ef71f48"
let GEC_MODEL_FILENAME = "Qwen_Qwen3.5-0.8B-Q6_K.gguf"
private let GEC_MODEL_URL = URL(
    string: "https://huggingface.co/\(GEC_MODEL_REPOSITORY)/resolve/\(GEC_MODEL_REVISION)/\(GEC_MODEL_FILENAME)"
)!
// Verified against the actual downloaded bytes (not copied from HF API
// metadata) — same policy as every other pin in this file.
let GEC_MODEL_SHA256 = "976220309a81b4eb26462657a77570bc6e7d936e8425161c54d6d85488567f95"
let GEC_MODEL_SIZE_BYTES: Int64 = 691_461_216

// LoRA adapter GGUF: converted from VoiceScribe/qwen3-5-0.8b-dictation-
// corrector-lora-adapter @ HF revision 754d90dc5045eb16ff3d95f6e735909daeb4d7c6
// (safetensors SHA256 46285eb28877df9078c053fb8bfd8c9eb66fa153c0fe47e902188b9aee93bee1)
// via llama.cpp's convert_lora_to_gguf.py --outtype f32; the conversion
// output is what's checksum-pinned here. Committed at models/gec-lora-
// adapter.gguf in this repository and fetched from its raw GitHub URL so
// there is no third-party host that could 404 or serve different bytes.
let GEC_LORA_FILENAME = "qwen3.5-0.8b-dictation-corrector-lora.gguf"
let GEC_LORA_URL = URL(
    string: "https://github.com/shohart/SuperDictate-Next/raw/feat/llm-postproc-gec/models/gec-lora-adapter.gguf"
)!
let GEC_LORA_SHA256 = "7d4b10e098ff38306f13a561d26fc2f945fd9d13bfde7a0c67f4c91bff26617f"
let GEC_LORA_SIZE_BYTES: Int64 = 2_886_048

/// rsLoRA compensation: llama.cpp applies `adapter_scale * alpha / rank`
/// (llama-adapter.h get_scale); this adapter was trained with
/// use_rslora=true, i.e. effective scale `alpha / sqrt(rank)`. For rank 16
/// the compensating adapter_scale is sqrt(16) = 4.0. Verified empirically:
/// with the default 1.0 the adapter barely activates (термин-нормализация
/// отсутствует), with 4.0 the model card's reference behavior reproduces.
let GEC_LORA_SCALE: Double = 4.0

/// `~/Library/Application Support/SuperDictate/Models/LLM/` — a sibling of
/// the Parakeet ASR model directory, not inside it: this holds
/// text-generation GGUF weights for SuperDictateLLMHost, a completely
/// different runtime (llama_cpp_host) from the speech engine.
func llmModelCacheDirectory() -> URL {
    resolvedParakeetSupportDirectory(nil)!
        .appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent("LLM", isDirectory: true)
}

func gecModelPath() -> URL {
    llmModelCacheDirectory().appendingPathComponent(GEC_MODEL_FILENAME, isDirectory: false)
}

func gecLoraPath() -> URL {
    llmModelCacheDirectory().appendingPathComponent(GEC_LORA_FILENAME, isDirectory: false)
}

func gecModelCacheExists() -> Bool {
    func verified(_ path: URL, expectedSize: Int64) -> Bool {
        guard isPlainRegularFile(path.path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        return (attributes?[.size] as? Int64) == expectedSize
    }
    return verified(gecModelPath(), expectedSize: GEC_MODEL_SIZE_BYTES)
        && verified(gecLoraPath(), expectedSize: GEC_LORA_SIZE_BYTES)
}

func assertSufficientDiskSpaceForGECModelDownload() throws {
    let requiredBytes = GEC_MODEL_SIZE_BYTES + GEC_LORA_SIZE_BYTES + MODEL_DOWNLOAD_HEADROOM_BYTES
    let availableBytes = availableImportantDiskSpaceBytes(containing: llmModelCacheDirectory())
    guard let availableBytes, availableBytes >= 0, availableBytes < requiredBytes else {
        return
    }
    let detail = """
    Parakey needs about \(formattedByteCount(UInt64(GEC_MODEL_SIZE_BYTES + GEC_LORA_SIZE_BYTES))) of free disk space to download the correction model.

    Available: \(formattedByteCount(UInt64(availableBytes)))
    Needed: \(formattedByteCount(UInt64(requiredBytes)))

    Free some disk space, then retry.
    """
    throw NSError(domain: "Parakey", code: -9, userInfo: [NSLocalizedDescriptionKey: detail])
}

/// Shared download/verify/atomic-rename body for both correction-model
/// files — the exact shape the old single-file downloadGECModelIfNeeded
/// used, parameterized.
/// Delegate-backed model download with byte progress: the classic
/// URLSessionDownloadDelegate flow wrapped in a continuation, because the
/// async download(from:) convenience gives no progress callbacks — and
/// for multi-GB models the user needs to see movement.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var finishedLocation: URL?

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        finishedLocation = location
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            error = GECModelDownloadError.httpError(statusCode: http.statusCode)
        }
    }

    private var error: Error?

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { self.error = error }
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let finishedLocation {
            continuation.resume(returning: finishedLocation)
        } else {
            continuation.resume(throwing: GECModelDownloadError.httpError(statusCode: -1))
        }
    }
}

@discardableResult
private func downloadGECFileIfNeeded(existingDescription: String,
                                     destination: URL,
                                     remoteURL: URL,
                                     expectedSize: Int64,
                                     expectedSHA256: String,
                                     progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
    if FileManager.default.fileExists(atPath: destination.path) {
        guard isPlainRegularFile(destination.path) else {
            throw GECModelDownloadError.unsafeDestination(
                "existing cache path is not a plain regular file: \(destination.path)"
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let actualSize = (attributes?[.size] as? Int64) ?? -1
        if actualSize == expectedSize {
            let actualHash = try sha256Hex(ofFileAt: destination)
            if actualHash == expectedSHA256 {
                return destination
            }
        }
        log("LLM: cached \(existingDescription) failed size/checksum verification; redownloading")
        try? FileManager.default.removeItem(at: destination)
    }

    let destinationDirectory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    // Delegate-backed download task: byte progress for the UI + the
    // finished temp file via continuation.
    let delegate = ModelDownloadDelegate(progress: progress ?? { _, _ in })
    let progressSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { progressSession.finishTasksAndInvalidate() }

    let systemTempURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        delegate.setContinuation(continuation)
        progressSession.downloadTask(with: remoteURL).resume()
    }

    let sameVolumeTempURL = destinationDirectory.appendingPathComponent(
        ".\(destination.lastPathComponent).download-\(UUID().uuidString)", isDirectory: false
    )
    try FileManager.default.moveItem(at: systemTempURL, to: sameVolumeTempURL)

    func cleanupTemp() {
        try? FileManager.default.removeItem(at: sameVolumeTempURL)
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: sameVolumeTempURL.path)
    let actualSize = (attributes?[.size] as? Int64) ?? -1
    guard actualSize == expectedSize else {
        cleanupTemp()
        throw GECModelDownloadError.sizeMismatch(expected: expectedSize, actual: actualSize)
    }

    let actualHash = try sha256Hex(ofFileAt: sameVolumeTempURL)
    guard actualHash == expectedSHA256 else {
        cleanupTemp()
        throw GECModelDownloadError.checksumMismatch(expected: expectedSHA256, actual: actualHash)
    }

    _ = try FileManager.default.replaceItemAt(destination, withItemAt: sameVolumeTempURL)
    return destination
}

@discardableResult
func downloadGECModelIfNeeded() async throws -> URL {
    try assertSufficientDiskSpaceForGECModelDownload()
    let base = try await downloadGECFileIfNeeded(
        existingDescription: "GEC base model",
        destination: gecModelPath(),
        remoteURL: GEC_MODEL_URL,
        expectedSize: GEC_MODEL_SIZE_BYTES,
        expectedSHA256: GEC_MODEL_SHA256
    )
    _ = try await downloadGECFileIfNeeded(
        existingDescription: "GEC LoRA adapter",
        destination: gecLoraPath(),
        remoteURL: GEC_LORA_URL,
        expectedSize: GEC_LORA_SIZE_BYTES,
        expectedSHA256: GEC_LORA_SHA256
    )
    return base
}

// MARK: - YandexGPT-5-Lite-8B model (quality correction + rewrite)
//
// One file serves TWO functions (docs/specs/rewrite-tiered-correction-
// spec.md §2.2): the `.quality` correction tier AND the bundled rewrite
// model. Selected from benchmark/REPORT.md (2026-08-21):
//   - correction: EM 0.892, Levenshtein 0.985, Identity 1.000, p50 433 ms
//     — clear winner over every other candidate including 9B Qwen3.5.
//   - rewrite: FactRec 0.527 (highest), LenRatio 0.966 (closest to 1.0),
//     p50 2668 ms.
// Pinned to the OFFICIAL yandex/YandexGPT-5-Lite-8B-instruct-GGUF repo at
// a specific revision, never `main` — same policy as every other pin in
// this file. The SHA256 below was computed from the actual bytes of the
// local copy this benchmark ran on (benchmark/models/, 2026-08-21) and
// cross-checked against the repo's LFS metadata — identical values, i.e.
// the app downloads the exact model the benchmark validated.

let YANDEXGPT_MODEL_REPOSITORY = "yandex/YandexGPT-5-Lite-8B-instruct-GGUF"
let YANDEXGPT_MODEL_REVISION = "9fe287d2f512503046bb008aed350f2b4bbb903d"
let YANDEXGPT_MODEL_FILENAME = "YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf"
private let YANDEXGPT_MODEL_URL = URL(
    string: "https://huggingface.co/\(YANDEXGPT_MODEL_REPOSITORY)/resolve/\(YANDEXGPT_MODEL_REVISION)/\(YANDEXGPT_MODEL_FILENAME)"
)!
let YANDEXGPT_MODEL_SHA256 = "d9ff5b826f20fbcc2f898f9f2349ac21241579f8fbb79cd32148a333623ba228"
let YANDEXGPT_MODEL_SIZE_BYTES: Int64 = 4_920_741_184

func yandexGPTModelPath() -> URL {
    llmModelCacheDirectory().appendingPathComponent(YANDEXGPT_MODEL_FILENAME, isDirectory: false)
}

func yandexGPTModelCacheExists() -> Bool {
    guard isPlainRegularFile(yandexGPTModelPath().path) else { return false }
    let attributes = try? FileManager.default.attributesOfItem(atPath: yandexGPTModelPath().path)
    return (attributes?[.size] as? Int64) == YANDEXGPT_MODEL_SIZE_BYTES
}

func assertSufficientDiskSpaceForYandexModelDownload() throws {
    let requiredBytes = YANDEXGPT_MODEL_SIZE_BYTES + MODEL_DOWNLOAD_HEADROOM_BYTES
    let availableBytes = availableImportantDiskSpaceBytes(containing: llmModelCacheDirectory())
    guard let availableBytes, availableBytes >= 0, availableBytes < requiredBytes else {
        return
    }
    let detail = """
    Parakey needs about \(formattedByteCount(UInt64(YANDEXGPT_MODEL_SIZE_BYTES))) of free disk space to download YandexGPT 5 Light.

    Available: \(formattedByteCount(UInt64(availableBytes)))
    Needed: \(formattedByteCount(UInt64(requiredBytes)))

    Free some disk space, then retry.
    """
    throw NSError(domain: "Parakey", code: -10, userInfo: [NSLocalizedDescriptionKey: detail])
}

@discardableResult
func downloadYandexModelIfNeeded() async throws -> URL {
    try assertSufficientDiskSpaceForYandexModelDownload()
    return try await downloadGECFileIfNeeded(
        existingDescription: "YandexGPT model",
        destination: yandexGPTModelPath(),
        remoteURL: YANDEXGPT_MODEL_URL,
        expectedSize: YANDEXGPT_MODEL_SIZE_BYTES,
        expectedSHA256: YANDEXGPT_MODEL_SHA256
    )
}

// MARK: - Benchmark model pins (2026-08-21, benchmark/REPORT.md)
//
// Every pin below was verified by hashing the exact local file the
// benchmark ran on (benchmark/models/) and cross-checking that SHA256
// against the repo's LFS metadata — the app downloads the exact bytes the
// benchmark validated. Same policy as the GEC/YandexGPT pins above.

struct BundledLLMModelPin {
    let repository: String
    let revision: String
    let remoteFileName: String
    let sha256: String
    let sizeBytes: Int64

    var url: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remoteFileName)")!
    }
}

func bundledLLMModelPin(_ model: BundledLLMModel) -> BundledLLMModelPin {
    switch model {
    case .voiceScribe:
        return BundledLLMModelPin(
            repository: GEC_MODEL_REPOSITORY,
            revision: GEC_MODEL_REVISION,
            remoteFileName: GEC_MODEL_FILENAME,
            sha256: GEC_MODEL_SHA256,
            sizeBytes: GEC_MODEL_SIZE_BYTES)
    case .yandexGPT:
        return BundledLLMModelPin(
            repository: YANDEXGPT_MODEL_REPOSITORY,
            revision: YANDEXGPT_MODEL_REVISION,
            remoteFileName: YANDEXGPT_MODEL_FILENAME,
            sha256: YANDEXGPT_MODEL_SHA256,
            sizeBytes: YANDEXGPT_MODEL_SIZE_BYTES)
    case .qwen35_4b:
        return BundledLLMModelPin(
            repository: "bartowski/Qwen_Qwen3.5-4B-GGUF",
            revision: "4168f45a16a1290d65a4ec0fa312ae917a4c15d6",
            remoteFileName: "Qwen_Qwen3.5-4B-Q6_K.gguf",
            sha256: "5a5bc7a3f9375b395e9f81fb69109038cf160c84606b8192f13cbb8355ca59f2",
            sizeBytes: 3_805_358_048)
    case .ruAdapt4b:
        // NB: the repo names its quant files bare ("Q6_K.gguf") — the
        // local cache filename below keeps the model name for clarity.
        return BundledLLMModelPin(
            repository: "RefalMachine/RuadaptQwen3-4B-Instruct-GGUF",
            revision: "0cf4a934b379b3d070116164aaa6e5db1c7d4198",
            remoteFileName: "Q6_K.gguf",
            sha256: "a206b1994822653e1da29ce76e96dc57f0f2a899f09a44466b94d3c043b82d29",
            sizeBytes: 3_295_488_128)
    case .qvikhr4b:
        return BundledLLMModelPin(
            repository: "Vikhrmodels/QVikhr-3-4B-Instruction-GGUF",
            revision: "ab5a2e9090cd1643ea48f3eb86d7b8fde8df8db6",
            remoteFileName: "QVikhr-3-4B-Instruction-Q6_K.gguf",
            sha256: "4b75f6682b1d84c9048f54ffe5ddb54c7c5202afccb4121d027b59c227c31076",
            sizeBytes: 3_306_261_568)
    case .ministral3b:
        return BundledLLMModelPin(
            repository: "unsloth/Ministral-3-3B-Instruct-2512-GGUF",
            revision: "7564922f37fa5bbb62b87f09a55c12f1f91d7a6a",
            remoteFileName: "Ministral-3-3B-Instruct-2512-Q6_K.gguf",
            sha256: "ca22c676b97aad1d50952416f44ddd6d8130e24c11c474aed5e8865dd7e35297",
            sizeBytes: 2_821_256_480)
    case .phi4mini:
        return BundledLLMModelPin(
            repository: "unsloth/Phi-4-mini-instruct-GGUF",
            revision: "78eb92a46fc37e6b524df991ed9aca9bc6aa7b80",
            remoteFileName: "Phi-4-mini-instruct-Q6_K.gguf",
            sha256: "72b8446a3db55617950bef48d296659050867cca41bd7a7be4622010c9589400",
            sizeBytes: 3_155_622_880)
    case .loqira:
        return BundledLLMModelPin(
            repository: "loqira/Qwen3.5-0.8B-GEC-KAZ-RUS-ENG",
            revision: "ced469768d40dffc899fe459efb66a4a07aeabee",
            remoteFileName: "Qwen3.5-0.8B-GEC-KAZ-RUS-ENG.Q4_0.gguf",
            sha256: "893f573db88f587e823b66847e06049cdb3029eff6177d92f6577179f7178871",
            sizeBytes: 563_035_616)
    case .vanilla08b:
        // The VoiceScribe base WITHOUT the LoRA — literally the same pinned
        // file as the GEC base weights.
        return BundledLLMModelPin(
            repository: GEC_MODEL_REPOSITORY,
            revision: GEC_MODEL_REVISION,
            remoteFileName: GEC_MODEL_FILENAME,
            sha256: GEC_MODEL_SHA256,
            sizeBytes: GEC_MODEL_SIZE_BYTES)
    case .lfm25:
        return BundledLLMModelPin(
            repository: "LiquidAI/LFM2.5-2.6B-GGUF",
            revision: "f4a289c8a200a5ca71005ba7abc2dad33058a450",
            remoteFileName: "LFM2.5-2.6B-Q6_K.gguf",
            sha256: "2e74b1a0979a4a1936a408445147d103b8f15b2e2ec31c65fa0166f9069c250d",
            sizeBytes: 2_221_615_104)
    case .gemma4e4b:
        return BundledLLMModelPin(
            repository: "google/gemma-4-E4B-it-qat-q4_0-gguf",
            revision: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
            remoteFileName: "gemma-4-E4B_q4_0-it.gguf",
            sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee",
            sizeBytes: 5_154_941_280)
    case .qwen35_9b:
        return BundledLLMModelPin(
            repository: "unsloth/Qwen3.5-9B-GGUF",
            revision: "3885219b6810b007914f3a7950a8d1b469d598a5",
            remoteFileName: "Qwen3.5-9B-Q4_K_M.gguf",
            sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
            sizeBytes: 5_680_522_464)
    }
}

/// Writes the model's chat-template override (if any) into the LLM cache
/// and returns its path. Idempotent: rewrites only when the content
/// differs. nil = the model uses its built-in template.
func bundledLLMChatTemplateFile(_ model: BundledLLMModel) -> URL? {
    guard let template = model.chatTemplateOverride else { return nil }
    let url = llmModelCacheDirectory()
        .appendingPathComponent("chat-template-\(model.rawValue).jinja", isDirectory: false)
    let existing = try? String(contentsOf: url, encoding: .utf8)
    if existing != template {
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }
    return url
}

/// Local cache filename per model — usually the remote name; the bare-named
/// RuAdapt repo file ("Q6_K.gguf") is stored under a model-qualified name so
/// it can never collide with another bare-named download.
func bundledLLMModelCacheFileName(_ model: BundledLLMModel) -> String {
    switch model {
    case .ruAdapt4b: return "RuadaptQwen3-4B-Instruct-Q6_K.gguf"
    default: return bundledLLMModelPin(model).remoteFileName
    }
}

func bundledLLMModelPath(_ model: BundledLLMModel) -> URL {
    llmModelCacheDirectory().appendingPathComponent(bundledLLMModelCacheFileName(model),
                                                    isDirectory: false)
}

/// The LoRA adapter the host must load for `model` (empty STRING = none;
/// never an empty URL — `URL(fileURLWithPath: "").path` silently resolves
/// to the process working directory). Only VoiceScribe has one (rsLoRA-
/// compensated scale — see GEC_LORA_SCALE).
func bundledLLMLoraPath(_ model: BundledLLMModel) -> String {
    model.usesLoRAAdapter ? gecLoraPath().path : ""
}

func bundledLLMLoraScale(_ model: BundledLLMModel) -> Double {
    model.usesLoRAAdapter ? GEC_LORA_SCALE : 1.0
}

/// Whether every file the bundled pass needs for `model` is present and
/// size-verified in the LLM cache.
func bundledLLMModelExists(_ model: BundledLLMModel) -> Bool {
    let pin = bundledLLMModelPin(model)
    let path = bundledLLMModelPath(model)
    guard isPlainRegularFile(path.path),
          let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
          (attributes[.size] as? Int64) == pin.sizeBytes else {
        return false
    }
    if model.usesLoRAAdapter {
        return gecModelCacheExists() // base pair check includes the LoRA
    }
    return true
}

/// Total bytes a model's download needs (model file + LoRA when present).
func bundledLLMModelDownloadSize(_ model: BundledLLMModel) -> Int64 {
    bundledLLMModelPin(model).sizeBytes + (model.usesLoRAAdapter ? GEC_LORA_SIZE_BYTES : 0)
}

func assertSufficientDiskSpaceForBundledModel(_ model: BundledLLMModel) throws {
    let requiredBytes = bundledLLMModelDownloadSize(model) + MODEL_DOWNLOAD_HEADROOM_BYTES
    let availableBytes = availableImportantDiskSpaceBytes(containing: llmModelCacheDirectory())
    guard let availableBytes, availableBytes >= 0, availableBytes < requiredBytes else {
        return
    }
    let detail = """
    Parakey needs about \(formattedByteCount(UInt64(bundledLLMModelDownloadSize(model)))) of free disk space to download \(model.displayName).

    Available: \(formattedByteCount(UInt64(availableBytes)))
    Needed: \(formattedByteCount(UInt64(requiredBytes)))

    Free some disk space, then retry.
    """
    throw NSError(domain: "Parakey", code: -10, userInfo: [NSLocalizedDescriptionKey: detail])
}

/// On-demand download for whichever files `model`'s bundled pass needs
/// (no-op returning the cached file when already verified).
@discardableResult
func downloadBundledLLMModelIfNeeded(_ model: BundledLLMModel,
                                     progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
    if model == .voiceScribe {
        // VoiceScribe is the two-file pair (base + LoRA) — its dedicated
        // downloader already handles both pins and the disk-space check.
        return try await downloadGECModelIfNeeded()
    }
    if model == .yandexGPT {
        return try await downloadYandexModelIfNeeded()
    }
    try assertSufficientDiskSpaceForBundledModel(model)
    let pin = bundledLLMModelPin(model)
    return try await downloadGECFileIfNeeded(
        existingDescription: model.displayName,
        destination: bundledLLMModelPath(model),
        remoteURL: pin.url,
        expectedSize: pin.sizeBytes,
        expectedSHA256: pin.sha256,
        progress: progress
    )
}


private func resolvedParakeetSupportDirectory(_ override: URL?) -> URL? {
    override
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SuperDictate", isDirectory: true)
}

func isSafeSpeechModelCacheDirectory(_ cacheDir: URL,
                                     parakeetSupportDirectory: URL? = nil) -> Bool {
    let supportDirectory = resolvedParakeetSupportDirectory(parakeetSupportDirectory)
    guard let supportDirectory else { return false }

    let cacheURL = cacheDir.standardizedFileURL
    let supportURL = supportDirectory.standardizedFileURL
    guard cacheURL.isFileURL, supportURL.isFileURL else { return false }

    let cachePath = cacheURL.path
    let supportPath = supportURL.path
    let supportPrefix = supportPath.hasSuffix("/") ? supportPath : "\(supportPath)/"
    guard cachePath.hasPrefix(supportPrefix), cachePath != supportPath else { return false }

    let relativePath = String(cachePath.dropFirst(supportPrefix.count))
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty
        && !components.contains("")
        && !components.contains(".")
        && !components.contains("..")
}

func isExistingSpeechModelCacheDirectorySafeForRemoval(
    _ cacheDir: URL,
    parakeetSupportDirectory: URL? = nil
) -> Bool {
    guard isSafeSpeechModelCacheDirectory(cacheDir,
                                          parakeetSupportDirectory: parakeetSupportDirectory),
          let supportDirectory = resolvedParakeetSupportDirectory(parakeetSupportDirectory) else {
        return false
    }

    let cachePath = cacheDir.standardizedFileURL.path
    let supportPath = supportDirectory.standardizedFileURL.path
    let supportPrefix = supportPath.hasSuffix("/") ? supportPath : "\(supportPath)/"
    let relativePath = String(cachePath.dropFirst(supportPrefix.count))
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)

    guard isExistingPlainDirectory(supportPath) else { return false }
    var currentPath = supportPath
    // Walk every component except the last through the plain-directory
    // check — that confirms the whole parent chain is real directories with
    // no symlink hops. The cache target itself (last component) may be
    // either a plain file (the Parakeet `.gguf` model) or a plain directory
    // (older cache shapes), so it gets a looser leaf check below rather
    // than being forced through isExistingPlainDirectory.
    for component in components.dropLast() {
        currentPath = (currentPath as NSString).appendingPathComponent(String(component))
        guard isExistingPlainDirectory(currentPath) else { return false }
    }
    guard let lastComponent = components.last else { return false }
    currentPath = (currentPath as NSString).appendingPathComponent(String(lastComponent))
    guard currentPath == cachePath else { return false }
    return isExistingPlainDirectory(currentPath) || isExistingPlainFile(currentPath)
}

func speechModelCacheBaseDirectory() -> URL {
    resolvedParakeetSupportDirectory(nil) ?? FileManager.default.temporaryDirectory
}

/// `~/Library/Application Support/SuperDictate/Models`: the optional Silero
/// VAD model lives here (see `sileroVadModelPath`). The retired GGUF
/// Parakeet and Whisper models also lived here; their files are left in
/// place, never loaded.
func speechModelsDirectory() -> URL {
    resolvedParakeetSupportDirectory(nil)!
        .appendingPathComponent("Models", isDirectory: true)
}

func speechModelCacheDirectory(for profile: SpeechModelProfile) -> URL {
    switch profile {
    case .parakeetUltraOnnx:
        return onnxModelCacheDirectory()
    }
}

func speechModelDownloadRequiredBytes(for profile: SpeechModelProfile,
                                      headroomBytes: Int64 = MODEL_DOWNLOAD_HEADROOM_BYTES) -> Int64 {
    profile.estimatedDownloadBytes + headroomBytes
}

func speechModelDiskSpaceFailureDetail(profile: SpeechModelProfile,
                                       availableBytes: Int64?,
                                       requiredBytes: Int64) -> String? {
    guard let availableBytes, availableBytes >= 0, availableBytes < requiredBytes else {
        return nil
    }
    return """
    Parakey needs \(profile.downloadSizeText) of free disk space to download \(profile.shortName), plus room for the speech runtime to prepare it.

    Available: \(formattedByteCount(UInt64(availableBytes)))
    Needed: \(formattedByteCount(UInt64(requiredBytes)))

    Free some disk space, then retry loading the speech model. Audio is not uploaded.
    """
}

func availableImportantDiskSpaceBytes(containing url: URL) -> Int64? {
    let fm = FileManager.default
    var probe = url.standardizedFileURL
    while !fm.fileExists(atPath: probe.path), probe.path != "/" {
        probe.deleteLastPathComponent()
    }
    guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let capacity = values.volumeAvailableCapacityForImportantUsage else {
        return nil
    }
    return Int64(capacity)
}

func speechModelCacheExists(for profile: SpeechModelProfile) -> Bool {
    switch profile {
    case .parakeetUltraOnnx:
        // manifest.json is written last, only after every file verified.
        return isPlainRegularFile(onnxModelManifestURL().path)
    }
}

func assertSufficientDiskSpaceForSpeechModelDownload(profile: SpeechModelProfile) throws {
    let requiredBytes = speechModelDownloadRequiredBytes(for: profile)
    let availableBytes = availableImportantDiskSpaceBytes(containing: speechModelCacheBaseDirectory())
    guard let detail = speechModelDiskSpaceFailureDetail(profile: profile,
                                                        availableBytes: availableBytes,
                                                        requiredBytes: requiredBytes) else {
        return
    }
    throw NSError(domain: "Parakey",
                  code: -8,
                  userInfo: [NSLocalizedDescriptionKey: detail])
}

func removeSpeechModelCacheDirectory(_ cacheDir: URL) async throws -> Bool {
    guard isSafeSpeechModelCacheDirectory(cacheDir) else {
        throw NSError(
            domain: "Parakey",
            code: -3,
            userInfo: [
                NSLocalizedDescriptionKey: "Refusing to remove unexpected speech model cache path: \(cacheDir.path)"
            ]
        )
    }

    return try await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheDir.path) else {
            return false
        }
        guard isExistingSpeechModelCacheDirectorySafeForRemoval(cacheDir) else {
            throw NSError(
                domain: "Parakey",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refusing to remove unsafe speech model cache path: \(cacheDir.path)"
                ]
            )
        }
        try fm.removeItem(at: cacheDir)
        return true
    }.value
}

func isExistingPlainDirectory(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}

private func isExistingPlainFile(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFREG
}

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func normalizedTranscriptCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedTranscriptCorrectionSource(source)
        guard !source.isEmpty,
              !replacement.isEmpty,
              !key.isEmpty,
              source.utf8.count <= MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
              replacement.utf8.count <= MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES,
              !source.unicodeScalars.contains(where: { $0.value == 0 }),
              !replacement.unicodeScalars.contains(where: { $0.value == 0 }) else {
            continue
        }

        let cleaned = TranscriptCorrection(source: source, replacement: replacement)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            guard result.count < MAX_TRANSCRIPT_CORRECTIONS else { continue }
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

/// First line of the import-confirmation dialog. When the file holds
/// more entries than survive normalization (over the
/// MAX_TRANSCRIPT_CORRECTIONS cap, or invalid/duplicate entries), the
/// dialog must state the file's real count and how many will actually
/// be kept — normalization runs before the dialog, so without this the
/// user is told an oversized file "contains 512 corrections".
func correctionImportCountText(sourceName: String, originalCount: Int, keptCount: Int) -> String {
    guard originalCount > keptCount else {
        return "\(sourceName) contains \(keptCount) corrections."
    }
    return "\(sourceName) contains \(originalCount) entries; only the first \(keptCount) valid corrections (Parakey keeps at most \(MAX_TRANSCRIPT_CORRECTIONS)) will be imported."
}

/// Appended to the import dialog when choosing Merge would push the
/// combined set over the correction cap. The merge path drops over-cap
/// entries silently, so the dialog has to warn before the user picks.
func correctionImportMergeCapWarningText(existingCount: Int,
                                         newCount: Int,
                                         cap: Int = MAX_TRANSCRIPT_CORRECTIONS) -> String? {
    let mergedCount = existingCount + newCount
    guard mergedCount > cap else { return nil }
    return "Merging would produce \(mergedCount) corrections; Parakey keeps at most \(cap), so \(mergedCount - cap) would be dropped."
}

private func utf8ClippedPrefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for character in text {
        let byteCount = String(character).utf8.count
        guard usedBytes + byteCount <= maxBytes else { break }
        result.append(character)
        usedBytes += byteCount
    }
    return result
}

func correctionSourcePrefill(from transcript: String) -> String {
    let flat = transcript
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return utf8ClippedPrefix(flat, maxBytes: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)
}

func normalizedAudioLevel(from samples: [Float]) -> Float {
    var sumSquares: Double = 0
    var count = 0

    for sample in samples where sample.isFinite {
        let clamped = max(-1, min(1, sample))
        sumSquares += Double(clamped * clamped)
        count += 1
    }

    return normalizedAudioLevel(sumSquares: sumSquares, sampleCount: count)
}

func normalizedAudioLevel(sumSquares: Double, sampleCount: Int) -> Float {
    guard sampleCount > 0, sumSquares > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0 else { return 0 }

    // This is a voice-visibility meter, not a calibrated VU meter.
    // Keep low room tone calm, then aggressively lift speech-range RMS
    // so normal close-mic speech visibly opens the HUD without shouting.
    let decibels = 20 * log10(rms)
    let gated = (decibels + 52) / 20
    guard gated > 0.06 else { return 0 }
    let lifted = pow(max(0, min(1, gated)), 0.42)
    return Float(max(0, min(1, lifted)))
}

func visibleRecordingLevel(rawLevel: Float) -> Float {
    guard rawLevel.isFinite else { return 0 }
    return max(0, min(1, rawLevel))
}

func recordingHUDPhaseSpeed(mode: RecordingHUDMode, level: Float) -> CGFloat {
    switch mode {
    case .recording:
        let voiceLevel = CGFloat(visibleRecordingLevel(rawLevel: level))
        return RECORDING_HUD_RECORDING_BASE_PHASE_SPEED
            + (voiceLevel * RECORDING_HUD_RECORDING_LEVEL_PHASE_SPEED)
    case .transcribing:
        return RECORDING_HUD_TRANSCRIBING_PHASE_SPEED
    case .correcting:
        return RECORDING_HUD_CORRECTING_PHASE_SPEED
    case .error:
        return 0
    }
}

struct TranscriptCorrectionSyncMergeResult: Equatable {
    let corrections: [TranscriptCorrection]
    let conflictingSources: [String]
}

struct CorrectionSyncFileFingerprint: Equatable {
    let modifiedAt: Date?
    let size: Int?
    let sha256: String
}

func correctionSyncFingerprint(for url: URL) -> CorrectionSyncFileFingerprint? {
    do {
        let digest = try correctionSyncFileSHA256Hex(url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CorrectionSyncFileFingerprint(modifiedAt: values.contentModificationDate,
                                             size: values.fileSize,
                                             sha256: digest)
    } catch {
        return nil
    }
}

/// Fingerprint for bytes this process just wrote to `url`. Content
/// hash and size come from the in-memory data — never from re-reading
/// the file, which races with a sync provider replacing it in the
/// write-to-fingerprint window and would swallow that remote change
/// until the next local edit. Only the modification date is read
/// back; if even that races, the SHA mismatch on the next scan still
/// detects the remote change.
func correctionSyncFingerprint(forWrittenData data: Data, at url: URL) -> CorrectionSyncFileFingerprint {
    var hasher = SHA256()
    hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    return CorrectionSyncFileFingerprint(modifiedAt: modifiedAt,
                                         size: data.count,
                                         sha256: digest)
}

private func correctionSyncFileSHA256Hex(_ url: URL) throws -> String {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw TranscriptCorrectionsTransferError.notRegularFile
    }
    guard st.st_size <= TranscriptCorrectionsTransfer.maxFileBytes else {
        throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size),
                                                              TranscriptCorrectionsTransfer.maxFileBytes)
    }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func mergedTranscriptCorrectionsForSync(base: [TranscriptCorrection],
                                        local: [TranscriptCorrection],
                                        remote: [TranscriptCorrection]) -> TranscriptCorrectionSyncMergeResult {
    let base = normalizedTranscriptCorrections(base)
    let local = normalizedTranscriptCorrections(local)
    let remote = normalizedTranscriptCorrections(remote)

    func dictionaryBySource(_ corrections: [TranscriptCorrection]) -> [String: TranscriptCorrection] {
        Dictionary(uniqueKeysWithValues: corrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })
    }

    let baseBySource = dictionaryBySource(base)
    let localBySource = dictionaryBySource(local)
    let remoteBySource = dictionaryBySource(remote)

    var orderedSources: [String] = []
    var seenSources: Set<String> = []
    func appendSources(from corrections: [TranscriptCorrection]) {
        for correction in corrections {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            if seenSources.insert(key).inserted {
                orderedSources.append(key)
            }
        }
    }

    appendSources(from: local)
    appendSources(from: remote)
    appendSources(from: base)

    var merged: [TranscriptCorrection] = []
    var conflicts: [String] = []

    for source in orderedSources {
        let baseline = baseBySource[source]
        let localCorrection = localBySource[source]
        let remoteCorrection = remoteBySource[source]

        let chosen: TranscriptCorrection?
        if localCorrection == remoteCorrection {
            chosen = localCorrection
        } else if localCorrection == baseline {
            chosen = remoteCorrection
        } else if remoteCorrection == baseline {
            chosen = localCorrection
        } else {
            conflicts.append(localCorrection?.source ?? remoteCorrection?.source ?? baseline?.source ?? source)
            continue
        }

        if let chosen {
            merged.append(chosen)
        }
    }

    return TranscriptCorrectionSyncMergeResult(corrections: merged,
                                               conflictingSources: conflicts)
}
