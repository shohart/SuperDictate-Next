// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import Foundation

// MARK: - LLM postprocessing orchestration
//
// Sits AFTER processedDictationText (RecordingLifecycle.swift) in the
// dictation pipeline, never inside it — that function stays synchronous
// and untouched, per this feature's own design constraint (extensive
// self-test coverage already depends on its exact signature). Callers
// (ParakeyApp.swift) run `finalizedText(_:settings:)` as one more async
// step after the existing synchronous postprocessing, inside the same
// `Task { @MainActor in ... }` that already awaits transcription.
//
// Failure policy (every branch below): postprocessing must NEVER lose or
// block the user's dictated text. Any failure — model not downloaded, host
// process wouldn't start, request timed out, malformed custom baseURL —
// falls back to returning the input unchanged, logged but not surfaced as
// a blocking error.

// A plain actor, not @MainActor -- see LLMHostProcess's own doc comment
// for why (the self-test sync bridge deadlocks against MainActor-isolated
// work). ParakeyApp (itself @MainActor) already awaits every call into
// this type, so the cross-actor hop is free from the caller's point of
// view.
actor LLMPostprocessingCoordinator {
    private let hostProcess = LLMHostProcess()
    private var pendingUnloadTask: Task<Void, Never>?

    /// Applies the configured postprocessing mode to already-deterministically-
    /// corrected text. A no-op (returns `text` unchanged, no async work) when
    /// the mode is off or the text is empty.
    func finalizedText(_ text: String, settings: Settings) async -> String {
        guard settings.textPostprocessingMode == .correction, !text.isEmpty else {
            return text
        }

        // Foreign-term/script normalization (atom §14.1) is NOT done here.
        // It already ran, before this function was ever called, as part of
        // RecordingLifecycle.swift's processedDictationText -- the app's
        // existing machine-learned-correction mechanism
        // (TranscriptCorrector + VocabularyStore, growing from the user's
        // own corrections). See LLMPostprocessingPrompts.swift's own doc
        // comment for why a second, parallel, hardcoded dictionary was
        // tried and explicitly rejected here.
        switch settings.llmEngineBackend {
        case .customEndpoint:
            return await correctedViaCustomEndpoint(text, settings: settings)
        case .bundledLocal:
            return await correctedViaBundledHost(text, settings: settings)
        }
    }

    /// Stops the bundled host subprocess immediately, if running, and
    /// cancels any pending delayed unload. Call on app termination or the
    /// GPU toggle — the background service restarting after a Settings-
    /// window save already tears down the whole process (and this
    /// subprocess with it) on its own, so this is only reached for those
    /// two immediate cases; the hotkey toggle path uses
    /// scheduleDelayedUnload()/cancelScheduledUnload() below instead.
    func stop() async {
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        await hostProcess.stop()
    }

    /// Schedules the bundled host subprocess to unload after `seconds` of
    /// correction staying disabled. Called from the correction hotkey's
    /// toggle-OFF path (ParakeyApp.toggleTextCorrectionMode), NOT from the
    /// Settings window's Save button -- that already restarts the whole
    /// background service (killing this subprocess immediately) on every
    /// save, so a grace period there would never actually be observed.
    /// The delay exists specifically so quick hotkey on/off toggles reuse
    /// an already-warm model (avoiding its multi-second Vulkan reload)
    /// instead of paying that cost on every re-enable, while still freeing
    /// the memory/VRAM after sustained disuse. Superseding a still-pending
    /// unload (rapid off/off) just restarts the clock, matching "10
    /// minutes after the [most recent] disable."
    /// Bumped on every schedule/cancel so a completed task can tell
    /// whether it's still the current one before clearing pendingUnloadTask
    /// -- Task itself isn't Equatable, so this is the disambiguator.
    private var unloadGeneration = 0

    func scheduleDelayedUnload(after seconds: UInt64 = 10 * 60) {
        pendingUnloadTask?.cancel()
        unloadGeneration += 1
        let generation = unloadGeneration
        pendingUnloadTask = Task { [weak self, hostProcess] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await hostProcess.stop()
            log("LLM postprocessing: unloaded correction model after \(seconds)s of correction being disabled")
            await self?.clearPendingUnloadTask(ifGeneration: generation)
        }
    }

    /// Cancels a pending scheduleDelayedUnload(), keeping the host process
    /// (and its already-loaded model) alive. Called from the correction
    /// hotkey's toggle-ON path before the model is warm again.
    func cancelScheduledUnload() {
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        unloadGeneration += 1
    }

    private func clearPendingUnloadTask(ifGeneration generation: Int) {
        // A newer scheduleDelayedUnload()/cancelScheduledUnload() call may
        // have already bumped unloadGeneration and replaced/cleared
        // pendingUnloadTask by the time this (now-finished) task gets back
        // on the actor -- only clear it if it's still the same generation.
        guard generation == unloadGeneration else { return }
        pendingUnloadTask = nil
    }

    /// Test-only hook: whether a delayed unload is currently scheduled.
    var hasPendingUnloadForTest: Bool { pendingUnloadTask != nil }

    /// Test-only hook: whether the bundled host subprocess is currently
    /// running.
    func isHostProcessRunningForTest() async -> Bool { await hostProcess.isRunning }

    private func correctedViaBundledHost(_ text: String, settings: Settings) async -> String {
        guard gecModelCacheExists() else {
            log("LLM postprocessing: correction model not downloaded yet; passing text through unchanged")
            return text
        }
        let startResult = await hostProcess.start(modelPath: gecModelPath().path,
                                                  loraPath: gecLoraPath().path,
                                                  loraScale: GEC_LORA_SCALE,
                                                  useGPU: settings.useGPU)
        switch startResult {
        case .failure(let error):
            log("LLM postprocessing: bundled host failed to start (\(error)); passing text through unchanged")
            return text
        case .success:
            break
        }
        guard let baseURL = await hostProcess.baseURL else {
            log("LLM postprocessing: bundled host has no reachable baseURL; passing text through unchanged")
            return text
        }
        return await requestCorrection(baseURL: baseURL, apiKey: nil, model: "gec", text: text, settings: settings)
    }

    private func correctedViaCustomEndpoint(_ text: String, settings: Settings) async -> String {
        let raw = settings.llmCustomBaseURL
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            log("LLM postprocessing: custom baseURL is empty or invalid; passing text through unchanged")
            return text
        }
        let apiKey = settings.llmCustomAPIKey.isEmpty ? nil : settings.llmCustomAPIKey
        let model = settings.llmCustomModelName.isEmpty ? "gpt-4o-mini" : settings.llmCustomModelName
        return await requestCorrection(baseURL: url, apiKey: apiKey, model: model, text: text, settings: settings)
    }

    private func requestCorrection(baseURL: URL,
                                   apiKey: String?,
                                   model: String,
                                   text: String,
                                   settings: Settings) async -> String {
        let systemPrompt = LLMCorrectionPrompt.systemPrompt(vocabulary: settings.transcriptCorrections)
        let exampleTurns = LLMCorrectionPrompt.exampleTurns(vocabulary: settings.transcriptCorrections)
        // Correction output is roughly the same length as the input, never
        // longer in any meaningful way -- a generous multiple of the raw
        // UTF-8 byte count is a safe token-budget heuristic without needing
        // a real tokenizer on the Swift side.
        let maxTokens = min(2048, max(64, text.utf8.count))
        let result = await OpenAICompatibleClient.chatCompletion(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            exampleTurns: exampleTurns,
            userText: text,
            enableThinking: false,
            temperature: 0,
            maxTokens: maxTokens
        )
        switch result {
        case .success(let corrected):
            let sanitized = LLMCorrectionGuardrail.sanitizedCorrection(input: text, output: corrected)
            log("LLM postprocessing: applied (\(text.count) → \(sanitized.count) chars)")
            return sanitized
        case .failure(let error):
            log("LLM postprocessing: request failed (\(error)); passing text through unchanged")
            return text
        }
    }
}
