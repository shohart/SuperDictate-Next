// SuperDictateWhisperHost — persistent whisper.cpp transcription worker.
//
// Stdio protocol (identical to the retired Python faster-whisper host):
//   request:  LE uint32 sample count, then count × LE float32 PCM @16 kHz
//   response: LE uint32 UTF-8 byte length, then the UTF-8 text
// EOF on stdin ends the process cleanly (which also guarantees no orphaned
// helper survives a crashed parent — the pipe closes with the parent).
//
// Usage: SuperDictateWhisperHost MODEL_PATH LANGUAGE gpu [N_THREADS]
// GPU only: Whisper large-v3-turbo on CPU saturates every core of a
// many-core Mac for minutes and froze the whole machine during a
// benchmark (2026-10-16), so there is no CPU mode and no CPU fallback —
// a GPU context that fails to initialize is a hard failure the app turns
// into a Parakeet fallback.
// Vulkan shaders are found via the SUPERDICTATE_VULKAN_SHADER_DIR env var
// (tier 1 of ggml-vulkan-shaders-runtime's 3-tier fallback), which the
// spawning engine sets to the app bundle's whisper-vulkan-shaders/ corpus.
//
// Transcription settings transcribed from the old in-process
// WhisperEngine.swift (git a7ceb9e), with two deliberate changes:
//  - WHISPER_SAMPLING_GREEDY instead of beam search: large-v3-turbo is a
//    distilled model, for which greedy decoding is the recommended mode
//    (beam search risks repetition loops and only adds cost).
//  - (removed 2026-10-17) the old CPU-context fallback on GPU init failure.

import Foundation
import whisper_cpp

private func log(_ message: String) {
    FileHandle.standardError.write(Data("[whisper-host] \(message)\n".utf8))
}

private func readExactly(_ count: Int) -> Data? {
    var data = Data(capacity: count)
    while data.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count),
              !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

/// whisper.cpp encodes a fixed 1500-frame (30 s) window by default
/// regardless of real audio length — the dominant cost for short clips.
/// `audio_ctx` trims the window roughly proportionally. Transcribed from
/// the old WhisperEngine.audioContextFrames (see its doc comment there for
/// the truncation-boundary analysis behind the 2× margin); only ever
/// applied when a concrete language is forced, never under auto-detect.
private func audioContextFrames(sampleCount: Int, modelMaxAudioCtx: Int32) -> Int32 {
    let framesPerSecond = 50.0 // 1500 frames / 30 s
    let durationSeconds = Double(sampleCount) / Double(WHISPER_SAMPLE_RATE)
    let neededFrames = Int32((durationSeconds * framesPerSecond * 2.0).rounded(.up))
    return min(modelMaxAudioCtx, max(neededFrames, 256))
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    log("usage: SuperDictateWhisperHost MODEL_PATH LANGUAGE gpu [N_THREADS]")
    exit(2)
}
guard arguments[3] == "gpu" else {
    log("CPU mode is not supported: Whisper runs only on a GPU")
    exit(2)
}
let modelPath = arguments[1]
let language = arguments[2]
// The CPU side of a GPU run (mel, sampling) needs few threads; never
// default to every core (36 on the Xeon Mac Pro).
let threadCount = arguments.count > 4
    ? max(1, min(32, Int(arguments[4]) ?? 1))
    : max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))

// use_gpu alone is not enough: with no GPU backend device whisper.cpp
// silently computes on the CPU. Require a ggml device of type GPU
// (dedicated memory — a discrete card; integrated GPUs report IGPU).
guard let gpuDevice = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) else {
    log("no discrete GPU device found: Whisper runs only on a discrete GPU")
    exit(5)
}
log("GPU device: \(String(cString: ggml_backend_dev_description(gpuDevice)))")

let started = Date()
var contextParams = whisper_context_default_params()
// Flash attention auto-enables in this whisper.cpp pin and is measurably
// SLOWER than plain attention under MoltenVK on the RX 6600 — disable
// unless explicitly requested (arg 5 = "fa").
contextParams.flash_attn = arguments.count > 5 && arguments[5] == "fa"
contextParams.use_gpu = true
guard let context = whisper_init_from_file_with_params(modelPath, contextParams) else {
    log("failed to load model on the GPU at \(modelPath)")
    exit(3)
}
log("model loaded in \(String(format: "%.2f", Date().timeIntervalSince(started))) s "
    + "(gpu=true, threads=\(threadCount))")

while true {
    guard let header = readExactly(4) else { break }
    let count = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard count > 0, count <= 30 * 16_000 else {
        log("refusing sample count \(count)")
        exit(4)
    }
    guard let pcm = readExactly(Int(count) * 4) else { break }
    // Target host is x86_64 (little-endian) — the LE float32 PCM bytes are
    // directly bindable. Mirrors how the Python host consumed the same pipe.
    let samples: [Float] = pcm.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
    }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.print_progress = false
    params.print_realtime = false
    params.print_special = false
    params.no_timestamps = true
    params.n_threads = Int32(threadCount)

    // Route every language through strdup/free (never point params.language
    // at Swift string storage that may be released).
    let languageCString = strdup(language)
    defer { free(languageCString) }
    params.language = UnsafePointer(languageCString)

    // Trim the encoder window ONLY when a concrete language is forced —
    // trimming while whisper auto-detects was found on real hardware to
    // garble non-English audio (old WhisperEngine doc comment).
    if language != "auto" && !language.isEmpty {
        params.audio_ctx = audioContextFrames(
            sampleCount: samples.count,
            modelMaxAudioCtx: whisper_n_audio_ctx(context)
        )
    }

    let result = samples.withUnsafeBufferPointer { buffer in
        whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
    }
    guard result == 0 else {
        log("whisper_full failed with code \(result)")
        exit(5)
    }

    var text = ""
    let segmentCount = whisper_full_n_segments(context)
    for i in 0..<segmentCount {
        if let segmentText = whisper_full_get_segment_text(context, i) {
            text += String(cString: segmentText)
        }
    }
    let payload = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    var length = UInt32(payload.count).littleEndian
    var response = Data(bytes: &length, count: 4)
    response.append(payload)
    FileHandle.standardOutput.write(response)
}

whisper_free(context)
exit(0)
