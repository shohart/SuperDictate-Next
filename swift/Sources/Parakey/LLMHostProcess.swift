// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import Darwin
import Foundation

// MARK: - Bundled LLM host process
//
// Manages the SuperDictateLLMHost subprocess: a separately vendored/built
// llama.cpp core (swift/Sources/llama_cpp_host/, see that target's own
// comment in swift/Package.swift) exposing a minimal OpenAI-compatible
// /v1/chat/completions + /health surface over loopback HTTP. Spawned lazily
// (only once the user enables a postprocessing mode AND the model file is
// present — see ModelDownload.swift for the on-demand download, same
// policy as the Parakeet ASR model), never linked into this process: the
// two independently-vendored ggml copies cannot share an address space, so
// this is deliberately IPC over HTTP, not a function call.
//
// Once running, callers reach it through OpenAICompatibleClient.swift —
// the exact same client used for a user-supplied custom baseURL — pointed
// at `baseURL`.

enum LLMHostProcessError: Error, Equatable, Sendable {
    /// The SuperDictateLLMHost binary isn't where this build expects it
    /// (packaged .app: Contents/Helpers/; `swift run` dev builds: next to
    /// the Parakey binary in .build/<config>/).
    case helperBinaryNotFound
    /// Couldn't allocate a loopback port, or Process.run() itself threw.
    case launchFailed(String)
    /// The process started but /health never answered within the timeout
    /// (most commonly: still loading a large model — see the caller's own
    /// timeout budget, not this fixed poll timeout, for the real ceiling).
    case healthCheckTimedOut
    /// The process exited (crashed, or model load failed) before /health
    /// ever answered.
    case processExitedDuringStartup(Int32)
}

// A plain actor, NOT @MainActor -- matching ParakeetEngine/TranscriptionWorker's
// own convention for an async worker with mutable state. This matters
// operationally, not just stylistically: SelfTest.swift's
// runParakeetEngineSynchronously bridge blocks the CALLING thread with a
// semaphore while a Task completes the real work; if that work were
// @MainActor-isolated and the calling thread happened to be the main
// thread, the blocked semaphore would starve the only executor that could
// ever run the MainActor work, deadlocking forever. A plain actor's
// executor is independent of which thread is blocked, so it has no such
// hazard (verified empirically: an earlier @MainActor version of this type
// hung the `llm-gec` self-test indefinitely for exactly this reason).
actor LLMHostProcess {
    private var process: Process?
    private(set) var port: Int = 0
    let host = "127.0.0.1"

    var isRunning: Bool { process?.isRunning ?? false }

    var baseURL: URL? {
        guard isRunning, port > 0 else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// Starts the helper against `modelPath` if not already running.
    /// Idempotent: a second call while already running for the SAME model
    /// path is a no-op success; callers that need to switch models (or
    /// flip `useGPU`) must `stop()` first -- in practice this never
    /// happens mid-session, since a settings change that affects `useGPU`
    /// already restarts the whole background service (ControlPanel's
    /// "Save & Restart"), giving every `LLMHostProcess` instance a fresh
    /// `ParakeyApp` lifetime.
    ///
    /// `useGPU` mirrors the SAME `Settings.useGPU` toggle Parakeet itself
    /// reads (TranscriptionWorker.swift) -- one user-facing switch governs
    /// the backend for both models, per the atom's hardware target
    /// (Vulkan on the same GPU parakeet_cpp already uses). `999` is an
    /// intentionally-large layer count: this model has far fewer layers,
    /// so it just means "offload everything" without needing to know the
    /// exact layer count up front (same convention llama.cpp's own CLI
    /// uses for "-ngl 999").
    ///
    /// `loraPath`/`loraScale`: optional GGUF LoRA adapter applied on top of
    /// the base weights (see ModelDownload.swift's GEC_LORA_* pins and the
    /// rsLoRA scale derivation). An empty path passes no --lora flags,
    /// keeping the host on plain base weights.
    func start(modelPath: String,
               loraPath: String = "",
               loraScale: Double = 1.0,
               ctxSize: Int32 = 4096,
               useGPU: Bool = false,
               healthCheckTimeout: TimeInterval = 60) async -> Result<Void, LLMHostProcessError> {
        if isRunning {
            return .success(())
        }

        guard let binaryURL = Self.resolvedHelperBinaryURL(),
              FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return .failure(.helperBinaryNotFound)
        }
        guard let chosenPort = Self.pickFreeLoopbackPort() else {
            return .failure(.launchFailed("could not allocate a free loopback port"))
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = [
            "--model", modelPath,
            "--host", host,
            "--gpu-layers", useGPU ? "999" : "0",
            "--port", String(chosenPort),
            "--ctx-size", String(ctxSize),
        ]
        if !loraPath.isEmpty {
            proc.arguments! += ["--lora", loraPath, "--lora-scale", String(loraScale)]
        }
        proc.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        proc.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                log("SuperDictateLLMHost: \(line)")
            }
        }

        do {
            try proc.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        process = proc
        port = chosenPort

        let deadline = Date().addingTimeInterval(healthCheckTimeout)
        while Date() < deadline {
            if !proc.isRunning {
                let status = proc.terminationStatus
                cleanUp()
                return .failure(.processExitedDuringStartup(status))
            }
            if await Self.pollHealth(host: host, port: chosenPort) {
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        stop()
        return .failure(.healthCheckTimedOut)
    }

    func stop() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
        }
        cleanUp()
    }

    private func cleanUp() {
        if let pipe = process?.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process = nil
        port = 0
    }

    // MARK: - Helper binary resolution

    private static func resolvedHelperBinaryURL() -> URL? {
        let name = "SuperDictateLLMHost"
        // Packaged .app: scripts/build-app.sh copies the helper into
        // Contents/Helpers/ (NOT Contents/MacOS/ — it is not the app's
        // main executable and must not appear in Launch Services / Dock).
        let packaged = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: packaged.path) {
            return packaged
        }
        // `swift run` / self-test dev builds: SwiftPM places every product
        // of the package in the same .build/<config>/ directory, so the
        // helper is always a sibling of the currently-running Parakey
        // binary.
        if let selfURL = Bundle.main.executableURL {
            let sibling = selfURL.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return nil
    }

    // MARK: - Port allocation

    /// Binds to loopback port 0 (OS-assigned free port), reads back the
    /// assigned port, then closes the socket before returning it —
    /// SuperDictateLLMHost binds its own listening socket moments later.
    /// Same small TOCTOU window any "find a free port" helper has; loopback
    /// + single local user makes it a non-issue in practice.
    private static func pickFreeLoopbackPort() -> Int? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(sock, sockaddrPtr, &len)
            }
        }
        guard getResult == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    // MARK: - Health polling

    private static func pollHealth(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        // See OpenAICompatibleClient.swift's identical override for why a
        // loopback target needs this: a system-wide proxy has no route
        // back into this machine's own loopback interface, and macOS's
        // proxy exceptions list does not exempt 127.0.0.1 by default.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }
}
