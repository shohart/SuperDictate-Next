// Parakey — push-to-talk dictation for macOS.
//
// Swift menu-bar app. The runtime covers hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (Parakeet via ONNX Runtime in the
// SuperDictateOnnxHost helper, CPU only — the GPU is for the LLM host),
// paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, and permission guidance.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import parakeet_cpp
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

/// Exit status written by a detached diagnostic task and read after its
/// semaphore is signalled (a plain captured `var` is rejected by Swift 6
/// strict concurrency).
final class DiagnosticExitCode: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = EXIT_FAILURE

    var value: Int32 { lock.lock(); defer { lock.unlock() }; return status }
    func set(_ newValue: Int32) { lock.lock(); status = newValue; lock.unlock() }
}

func runAudioCaptureDiagnostic(arguments: [String]) -> Int32? {
    guard arguments.first == "--diagnose-audio-capture" else { return nil }
    guard arguments.count == 3,
          let duration = TimeInterval(arguments[2]),
          duration > 0,
          duration <= 15 else {
        fputs("usage: SuperDictate --diagnose-audio-capture <device-uid|default> <seconds>\n",
              stderr)
        return EXIT_FAILURE
    }

    let preference = arguments[1] == "default" ? "" : arguments[1]
    let capture = AudioCapture()
    do {
        try capture.startRecording(inputDevicePreference: preference)
        Thread.sleep(forTimeInterval: duration)
        let recording = capture.endRecording()
        capture.stopEngine()

        let capturedSeconds = Double(recording.samples.count) / SAMPLE_RATE
        let peak = recording.samples.reduce(Float(0)) { max($0, abs($1)) }
        print(
            String(
                format: "AUDIO CAPTURE: requested=%.2fs captured=%.3fs samples=%d peak=%.6f",
                duration,
                capturedSeconds,
                recording.samples.count,
                peak
            )
        )
        return capturedSeconds >= duration * 0.75 ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
        capture.stopEngine()
        fputs("AUDIO CAPTURE FAILED: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }
}

/// Permanent, production-shipped diagnostic entry point backing
/// `scripts/benchmark-asr.sh` (spec
/// §19/§27). Deliberately checked BEFORE `NSApplication.shared` is ever
/// constructed — like `runAudioCaptureDiagnostic` above and unlike the
/// `#if DEBUG`-only `--self-test`/`--transcribe-file` hooks used in earlier
/// migration phases — so an unrecognized-in-a-release-build argument can
/// never fall through to `SuperDictateControlPanelApp`'s normal startup and
/// clobber the production LaunchAgent plist (exactly the incident the Phase
/// 4 report documents and warns never to repeat). Runs the REAL production
/// code paths (`TranscriptionWorker` and `transcribeSegmented`, i.e. the
/// same segmentation a recorded dictation goes through, with each engine's
/// helper resolved from Contents/Helpers) — never a mock.
///
/// usage: SuperDictate --benchmark-transcribe [onnx] cpu <threads> <wav1> [wav2 ...]
///
/// Speech recognition is ONNX on the CPU only; the retired `whisper` and
/// `parakeet` (GGUF) backends and `vulkan` are rejected with a message.
/// Loads the model once (device/threads as given), warms up, then
/// transcribes every listed WAV path IN ORDER through that one loaded
/// worker (repeat a path multiple times in argv to measure
/// warm-latency distribution — the calling script does this). Each result
/// is printed as one machine-parseable line; the calling shell script does
/// all statistics (median/p95, peak RSS via /usr/bin/time -l wrapping the
/// whole process, bucket selection, corpus generation). Exits non-zero with
/// a message on stderr for any failure.
func runASRBenchmarkDiagnostic(arguments: [String]) -> Int32? {
    guard arguments.first == "--benchmark-transcribe" else { return nil }
    let usage = "usage: SuperDictate --benchmark-transcribe [onnx] cpu <threads> <wav1> [wav2 ...]\n"
    var rest = Array(arguments.dropFirst())
    if let first = rest.first, first == "whisper" || first == "parakeet" {
        fputs("benchmark: the \(first) backend was removed; speech recognition is ONNX on the CPU only\n", stderr)
        return EXIT_FAILURE
    }
    if rest.first == "onnx" {
        rest.removeFirst()
    }
    if rest.first == "vulkan" {
        fputs("benchmark: speech recognition is CPU-only (the GPU is reserved for the LLM host)\n", stderr)
        return EXIT_FAILURE
    }
    guard rest.count >= 3,
          rest[0] == "cpu",
          let threads = Int(rest[1]), (1...32).contains(threads)
    else {
        fputs(usage, stderr)
        return EXIT_FAILURE
    }
    let wavPaths = Array(rest.dropFirst(2))

    // Bare top-level `Task { }` inherits MainActor isolation with no run
    // loop pumping here (no NSApplication yet) — a guaranteed self-deadlock,
    // root-caused in the Phase 3 report. `Task.detached` + a semaphore
    // (the Phase 4 report's proven fix for this exact shape) avoids it.
    let semaphore = DispatchSemaphore(value: 0)
    let exitCode = DiagnosticExitCode()
    Task.detached {
        defer { semaphore.signal() }
        do {
            try await runSegmentedBenchmark(threads: threads, wavPaths: wavPaths)
            exitCode.set(EXIT_SUCCESS)
        } catch {
            fputs("BENCH_FAILED: \(error.localizedDescription)\n", stderr)
            exitCode.set(EXIT_FAILURE)
        }
    }
    // Pump the main run loop while waiting instead of blocking it: any
    // main-actor hop on the dictation path would otherwise deadlock.
    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return exitCode.value
}

private func benchmarkEscapedText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

/// Every WAV through the REAL dictation path: a `TranscriptionWorker`
/// loaded like the agent loads it, then `transcribeSegmented` —
/// PauseSegmenter (≤ 25 s segments), the overlap windows and seam dedup —
/// exactly as a recorded dictation. Never a raw whole-file engine call: the
/// app never hands the engine a long unsegmented clip, and the benchmark
/// must not either.
private func runSegmentedBenchmark(threads: Int, wavPaths: [String]) async throws {
    let profile = SpeechModelProfile.productionDefault
    // The worker reads its thread count from this override (1...32).
    setenv("SUPERDICTATE_ASR_THREADS", String(threads), 1)
    let worker = TranscriptionWorker()

    let loadStart = ProcessInfo.processInfo.systemUptime
    try await worker.load(profile: profile)
    let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
    // load() already warmed the engine; this second pass mirrors the
    // agent's own post-load warm-up through the worker. Not worker.warmUp():
    // that resolves the dictation language from the keyboard layout on the
    // main actor, which a headless benchmark has no use for.
    let warmStart = ProcessInfo.processInfo.systemUptime
    _ = try await worker.transcribe(samples: [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4)),
                                    resolveViaKeyboard: false,
                                    requestedAt: warmStart)
    let warmSeconds = ProcessInfo.processInfo.systemUptime - warmStart
    let backend = "onnx"
    let deviceArg = "cpu"
    let actualDevice = "cpu"

    print("BENCH_LOAD backend=\(backend) device=\(deviceArg) requested_threads=\(threads) load_s=\(loadSeconds) warmup_s=\(warmSeconds) actual_device=\(actualDevice) path=segmented")

    for path in wavPaths {
        let samples = try benchmarkReadMonoPCM(fileURL: URL(fileURLWithPath: path))
        let durationSeconds = Double(samples.count) / SAMPLE_RATE
        let segmentCount = PauseSegmenter.segment(samples: samples, sampleRate: SAMPLE_RATE).count
        let callStart = ProcessInfo.processInfo.systemUptime
        let result = try await transcribeSegmented(samples: samples,
                                                   worker: worker,
                                                   language: nil,
                                                   resolveViaKeyboard: false,
                                                   requestedAt: callStart)
        let wallSeconds = ProcessInfo.processInfo.systemUptime - callStart
        let rtf = durationSeconds > 0 ? result.engineProcessingSeconds / durationSeconds : 0
        print("BENCH_RESULT backend=\(backend) file=\(path) duration_s=\(durationSeconds) segments=\(segmentCount) wall_s=\(wallSeconds) inference_s=\(result.engineProcessingSeconds) total_s=\(wallSeconds) rtf=\(rtf) used_gpu=false segment_failure=\(result.hadSegmentFailure) text=\(benchmarkEscapedText(result.text))")
    }
    await worker.unload()
}

/// Reads a WAV file as mono Float32 PCM at `SAMPLE_RATE` Hz, converting if
/// the source file's format differs (the benchmark corpus is generated at
/// 16 kHz mono already, so this is normally a straight passthrough read —
/// the conversion path exists only as a safety net for a hand-supplied
/// fixture in a different format).
func benchmarkReadMonoPCM(fileURL: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: fileURL)
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: SAMPLE_RATE,
                                            channels: 1,
                                            interleaved: false) else {
        throw ASREngineError.inferenceFailed("could not construct target PCM format")
    }
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)) else {
        throw ASREngineError.inferenceFailed("could not allocate source buffer for \(fileURL.path)")
    }
    try file.read(into: sourceBuffer)

    if file.processingFormat.sampleRate == targetFormat.sampleRate,
       file.processingFormat.channelCount == 1,
       file.processingFormat.commonFormat == .pcmFormatFloat32,
       let channelData = sourceBuffer.floatChannelData {
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(sourceBuffer.frameLength)))
    }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
        throw ASREngineError.inferenceFailed("could not construct converter for \(fileURL.path)")
    }
    let estimatedFrames = AVAudioFrameCount(
        Double(sourceBuffer.frameLength) * targetFormat.sampleRate / file.processingFormat.sampleRate
    ) + 16
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
        throw ASREngineError.inferenceFailed("could not allocate output buffer for \(fileURL.path)")
    }
    var delivered = false
    var conversionError: NSError?
    converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
        if delivered {
            outStatus.pointee = .noDataNow
            return nil
        }
        delivered = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
    if let conversionError {
        throw ASREngineError.inferenceFailed("PCM conversion failed for \(fileURL.path): \(conversionError.localizedDescription)")
    }
    guard let channelData = outBuffer.floatChannelData else {
        throw ASREngineError.inferenceFailed("converted buffer has no channel data for \(fileURL.path)")
    }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
}

