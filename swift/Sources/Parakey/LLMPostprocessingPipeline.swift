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
// TWO independent stages (docs/specs/rewrite-tiered-correction-spec.md),
// deliberately replacing the old architecture note's "rewrite ON → GEC
// OFF" rule per the 2026-08-22 product decision:
//
//   1. correction — if textPostprocessingMode == .correction. Tiered:
//      .fast (VoiceScribe 0.8B+LoRA, this branch's fixed fast model) or
//      .quality (YandexGPT-5-Lite-8B). bundledLocal or customEndpoint.
//   2. rewrite — if rewriteEnabled. Bundled (YandexGPT-5-Lite-8B, the
//      same file the quality tier uses) or its own customEndpoint.
//
// Both may be enabled at once; correction runs first (fix ASR errors,
// then restructure), rewrite second.
//
// Host processes are keyed by identity "modelPath|loraPath": the fast
// tier gets its own 0.8B host, and the quality correction tier and the
// bundled rewrite SHARE one YandexGPT host (the host serializes requests
// internally, and the two stages are sequential anyway, so sharing is
// safe and saves a second 4.9 GB load).
//
// Failure policy (every branch below): postprocessing must NEVER lose or
// block the user's dictated text. Any failure — model not downloaded, host
// process wouldn't start, request timed out, malformed custom baseURL —
// falls back to returning the stage's input unchanged, logged but not
// surfaced as a blocking error.

// A plain actor, not @MainActor -- see LLMHostProcess's own doc comment
// for why (the self-test sync bridge deadlocks against MainActor-isolated
// work). ParakeyApp (itself @MainActor) already awaits every call into
// this type, so the cross-actor hop is free from the caller's point of
// view.
actor LLMPostprocessingCoordinator {
    private var hostProcesses: [String: LLMHostProcess] = [:]
    private var pendingUnloadTask: Task<Void, Never>?

    /// UI feedback for COLD host starts: loading a multi-GB model takes
    /// tens of seconds on first use, and without this the user stares at
    /// the correcting HUD with no idea anything is happening. Set by
    /// ParakeyApp at launch (state toast "Загружается модель …").
    /// @Sendable @MainActor: the closures hop to the main actor and touch
    /// UI only.
    var onHostLoadStage: (@Sendable @MainActor (String) -> Void)?
    var onHostLoadFinished: (@Sendable @MainActor () -> Void)?

    /// Host identity for the bundled correction model — the cache-key under
    /// which its LLMHostProcess lives. Models without a LoRA contribute an
    /// empty trailing component (NB: never build this from
    /// `URL(fileURLWithPath: "").path` — that resolves to the process's
    /// current working directory, not the empty string).
    static func correctionHostIdentity(model: BundledLLMModel) -> String {
        bundledLLMModelPath(model).path + "|" + bundledLLMLoraPath(model)
    }

    /// Host identity for the bundled rewrite model — same path-based rule
    /// as correction, so picking the SAME bundled model for both passes
    /// would share one host (the pickers offer disjoint model lists, so in
    /// practice each pass runs its own host).
    static func rewriteHostIdentity(model: BundledLLMModel) -> String {
        bundledLLMModelPath(model).path + "|" + bundledLLMLoraPath(model)
    }

    /// The set of host identities the still-enabled functions need under
    /// `settings` right now — the keep-set the delayed-unload logic trims
    /// against (a host nobody needs gets stopped).
    static func neededHostIdentities(settings: Settings) -> Set<String> {
        var needed = Set<String>()
        if settings.textPostprocessingMode == .correction,
           settings.llmEngineBackend == .bundledLocal {
            needed.insert(correctionHostIdentity(model: settings.correctionBundledModel))
        }
        if settings.rewriteEnabled,
           settings.rewriteEngineBackend == .bundledLocal {
            needed.insert(rewriteHostIdentity(model: settings.rewriteBundledModel))
        }
        return needed
    }

    private func hostProcess(forIdentity identity: String) -> LLMHostProcess {
        if let existing = hostProcesses[identity] {
            return existing
        }
        let created = LLMHostProcess()
        hostProcesses[identity] = created
        return created
    }

    /// Applies the configured postprocessing stages to already-
    /// deterministically-corrected text. A no-op (returns `text`
    /// unchanged, no async work) when neither stage is enabled or the
    /// text is empty.
    ///
    /// Foreign-term/script normalization (atom §14.1) is NOT done here.
    /// It already ran, before this function was ever called, as part of
    /// RecordingLifecycle.swift's processedDictationText -- the app's
    /// existing machine-learned-correction mechanism
    /// (TranscriptCorrector + VocabularyStore, growing from the user's
    /// own corrections). See LLMPostprocessingPrompts.swift's own doc
    /// comment for why a second, parallel, hardcoded dictionary was
    /// tried and explicitly rejected here.
    func finalizedText(_ text: String, settings: Settings) async -> String {
        guard !text.isEmpty else { return text }
        var result = text
        if settings.textPostprocessingMode == .correction {
            result = await correctedText(result, settings: settings)
        }
        if settings.rewriteEnabled {
            result = await rewrittenText(result, settings: settings)
        }
        return result
    }

    func setHostLoadUI(stage: @escaping @Sendable @MainActor (String) -> Void,
                       finished: @escaping @Sendable @MainActor () -> Void) {
        onHostLoadStage = stage
        onHostLoadFinished = finished
    }

    /// Stops every bundled host subprocess immediately, if running, and
    /// cancels any pending delayed unload. Call on app termination or the
    /// GPU toggle — the background service restarting after a Settings-
    /// window save already tears down the whole process (and these
    /// subprocesses with it) on its own, so this is only reached for those
    /// two immediate cases; the hotkey toggle path uses
    /// scheduleDelayedUnload()/cancelScheduledUnload() below instead.
    func stop() async {
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        for host in hostProcesses.values {
            await host.stop()
        }
        hostProcesses.removeAll()
    }

    /// Schedules the delayed unload of every bundled host that no
    /// enabled function still needs under `settings` — called from the
    /// correction hotkey's toggle-OFF path (ParakeyApp.
    /// toggleTextCorrectionMode), NOT from the Settings window's Save
    /// button (that already restarts the whole background service, killing
    /// these subprocesses immediately, on every save). The delay exists
    /// so quick hotkey on/off toggles reuse an already-warm model
    /// (avoiding its multi-second Vulkan reload) instead of paying that
    /// cost on every re-enable, while still freeing the memory/VRAM after
    /// sustained disuse. Superseding a still-pending unload (rapid off/off)
    /// just restarts the clock, matching "10 minutes after the [most
    /// recent] disable." Hosts still needed at fire time — e.g. the shared
    /// YandexGPT host while rewrite stays enabled — are left running.
    /// Bumped on every schedule/cancel so a completed task can tell
    /// whether it's still the current one before clearing pendingUnloadTask
    /// -- Task itself isn't Equatable, so this is the disambiguator.
    private var unloadGeneration = 0

    func scheduleDelayedUnload(after seconds: UInt64 = 10 * 60,
                               settings: Settings) {
        pendingUnloadTask?.cancel()
        unloadGeneration += 1
        let generation = unloadGeneration
        pendingUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadUnneededHosts(settings: settings,
                                            generation: generation)
        }
    }

    /// Cancels a pending scheduleDelayedUnload(), keeping every host
    /// process (and its already-loaded model) alive. Called from the
    /// correction hotkey's toggle-ON path before the model is warm again.
    func cancelScheduledUnload() {
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        unloadGeneration += 1
    }

    /// Stops every host whose identity is not in
    /// neededHostIdentities(settings:) and drops it from the table, then
    /// clears the pending flag if this task is still the current
    /// generation.
    private func unloadUnneededHosts(settings: Settings, generation: Int) async {
        let needed = Self.neededHostIdentities(settings: settings)
        for (identity, host) in hostProcesses where !needed.contains(identity) {
            await host.stop()
            hostProcesses[identity] = nil
            log("LLM postprocessing: unloaded model host no longer in use (\(identity))")
        }
        clearPendingUnloadTask(ifGeneration: generation)
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

    /// Test-only hook: whether any bundled host subprocess is currently
    /// running.
    func isHostProcessRunningForTest() async -> Bool {
        for host in hostProcesses.values where await host.isRunning {
            return true
        }
        return false
    }

    // MARK: - Correction stage

    private func correctedText(_ text: String, settings: Settings) async -> String {
        switch settings.llmEngineBackend {
        case .customEndpoint:
            return await correctedViaCustomEndpoint(text, settings: settings)
        case .bundledLocal:
            return await correctedViaBundledHost(text, settings: settings)
        }
    }

    private func correctedViaBundledHost(_ text: String, settings: Settings) async -> String {
        let model = settings.correctionBundledModel
        guard bundledLLMModelExists(model) else {
            log("LLM postprocessing: correction model (\(model.rawValue)) not downloaded yet; passing text through unchanged")
            return text
        }
        let identity = Self.correctionHostIdentity(model: model)
        let hostProcess = hostProcess(forIdentity: identity)
        let coldStart = !(await hostProcess.isRunning)
        if coldStart {
            await onHostLoadStage?("Загружается модель \(model.displayName)…")
        }
        let startResult = await hostProcess.start(modelPath: bundledLLMModelPath(model).path,
                                                  loraPath: bundledLLMLoraPath(model),
                                                  loraScale: bundledLLMLoraScale(model),
                                                  ctxSize: model.hostContextSize,
                                                  useGPU: settings.llmUseGPU,
                                                  chatTemplateFile: bundledLLMChatTemplateFile(model)?.path)
        if coldStart {
            await onHostLoadFinished?()
        }
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
        return await requestCorrection(baseURL: baseURL,
                                       apiKey: nil,
                                       model: "gec-\(model.rawValue)",
                                       bundledModel: model,
                                       text: text,
                                       settings: settings)
    }

    private func correctedViaCustomEndpoint(_ text: String, settings: Settings) async -> String {
        let raw = settings.llmCustomBaseURL
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            log("LLM postprocessing: custom baseURL is empty or invalid; passing text through unchanged")
            return text
        }
        let apiKey = settings.llmCustomAPIKey.isEmpty ? nil : settings.llmCustomAPIKey
        let model = settings.llmCustomModelName.isEmpty ? "gpt-4o-mini" : settings.llmCustomModelName
        return await requestCorrection(baseURL: url,
                                       apiKey: apiKey,
                                       model: model,
                                       // A custom endpoint serves whichever
                                       // model the user named there; the
                                       // bundled picker only picks OUR file,
                                       // so its prompt flavor is moot — but
                                       // the zero-shot instruct prompt is
                                       // the safer default for an arbitrary
                                       // instruct model.
                                       bundledModel: .qwen35_4b,
                                       text: text,
                                       settings: settings)
    }

    private func requestCorrection(baseURL: URL,
                                   apiKey: String?,
                                   model: String,
                                   bundledModel: BundledLLMModel,
                                   text: String,
                                   settings: Settings) async -> String {
        // A user-edited system prompt replaces the built-in default —
        // EXCEPT for models with a mandatory prompt (Loqira): the lock is
        // enforced here, at the single point where prompts are built.
        let override = bundledModel.allowsCustomSystemPrompt
            ? settings.correctionSystemPromptOverride
            : ""
        let systemPrompt = override.isEmpty
            ? LLMCorrectionPrompt.systemPrompt(vocabulary: settings.transcriptCorrections,
                                               model: bundledModel)
            : override
        let exampleTurns = LLMCorrectionPrompt.exampleTurns(vocabulary: settings.transcriptCorrections,
                                                            model: bundledModel)
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
            log("LLM postprocessing: applied correction (\(text.count) → \(sanitized.count) chars)")
            return sanitized
        case .failure(let error):
            log("LLM postprocessing: correction request failed (\(error)); passing text through unchanged")
            return text
        }
    }

    // MARK: - Rewrite stage
    //
    // Runs AFTER the correction stage when both are enabled. No
    // LLMCorrectionGuardrail here by design: rewrite is ALLOWED to
    // restructure (drop repeats, reorder into task sections, change
    // register), so leading-word preservation would reject legitimate
    // output. The stage's own safety net is the never-empty fallback
    // below plus the prompt's fact-preservation constraints.

    private func rewrittenText(_ text: String, settings: Settings) async -> String {
        switch settings.rewriteEngineBackend {
        case .bundledLocal:
            return await rewrittenViaBundledHost(text, settings: settings)
        case .customEndpoint:
            return await rewrittenViaCustomEndpoint(text, settings: settings)
        }
    }

    private func rewrittenViaBundledHost(_ text: String, settings: Settings) async -> String {
        let model = settings.rewriteBundledModel
        guard bundledLLMModelExists(model) else {
            log("LLM postprocessing: bundled rewrite model (\(model.rawValue)) not downloaded yet; passing text through unchanged")
            return text
        }
        let identity = Self.rewriteHostIdentity(model: model)
        let hostProcess = hostProcess(forIdentity: identity)
        let coldStart = !(await hostProcess.isRunning)
        if coldStart {
            await onHostLoadStage?("Загружается модель \(model.displayName)…")
        }
        let startResult = await hostProcess.start(modelPath: bundledLLMModelPath(model).path,
                                                  loraPath: bundledLLMLoraPath(model),
                                                  loraScale: bundledLLMLoraScale(model),
                                                  ctxSize: model.hostContextSize,
                                                  useGPU: settings.llmUseGPU,
                                                  chatTemplateFile: bundledLLMChatTemplateFile(model)?.path)
        if coldStart {
            await onHostLoadFinished?()
        }
        switch startResult {
        case .failure(let error):
            log("LLM postprocessing: bundled rewrite host failed to start (\(error)); passing text through unchanged")
            return text
        case .success:
            break
        }
        guard let baseURL = await hostProcess.baseURL else {
            log("LLM postprocessing: bundled rewrite host has no reachable baseURL; passing text through unchanged")
            return text
        }
        return await requestRewrite(baseURL: baseURL,
                                    apiKey: nil,
                                    model: "rewrite-\(model.rawValue)",
                                    text: text,
                                    settings: settings)
    }

    private func rewrittenViaCustomEndpoint(_ text: String, settings: Settings) async -> String {
        let raw = settings.rewriteCustomBaseURL
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            log("LLM postprocessing: rewrite custom baseURL is empty or invalid; passing text through unchanged")
            return text
        }
        let apiKey = settings.rewriteCustomAPIKey.isEmpty ? nil : settings.rewriteCustomAPIKey
        let model = settings.rewriteCustomModelName.isEmpty ? "gpt-4o-mini" : settings.rewriteCustomModelName
        return await requestRewrite(baseURL: url,
                                    apiKey: apiKey,
                                    model: model,
                                    text: text,
                                    settings: settings)
    }

    private func requestRewrite(baseURL: URL,
                                apiKey: String?,
                                model: String,
                                text: String,
                                settings: Settings) async -> String {
        // Active style: built-in or user-created
        // (docs/specs/custom-rewrite-styles-spec.md). Per-style user-edited
        // system prompt; empty = the built-in default. The «Режим:»
        // user-turn suffix is NOT editable for built-ins (benchmark
        // contract); user-created modes use their uppercased name.
        let selection = settings.rewriteStyleSelection()
        let override: String
        let systemPrompt: String
        let modeToken: String
        switch selection {
        case .builtin(let style):
            override = settings.rewriteSystemPromptOverride(for: style)
            systemPrompt = override.isEmpty ? LLMRewritePrompt.systemPrompt(style: style) : override
            modeToken = LLMRewritePrompt.modeToken(style)
        case .custom(let custom):
            override = settings.rewriteSystemPromptOverride(forStyleID: custom.id)
            systemPrompt = override.isEmpty ? LLMRewritePrompt.systemPrompt(custom: custom) : override
            modeToken = custom.name.uppercased()
        }
        let result = await OpenAICompatibleClient.chatCompletion(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            exampleTurns: LLMRewritePrompt.exampleTurns(style: .polish),
            userText: LLMRewritePrompt.userText(for: text, token: modeToken),
            enableThinking: false,
            temperature: 0,
            // Rewrite may legitimately EXPAND text (task structuring adds
            // section headers; benchmark rewrite runs used 1024 tokens for
            // typical inputs) — 3x the input's UTF-8 bytes, clamped to the
            // same 3072 ceiling the 8192-token host context fits next to a
            // long prompt.
            maxTokens: min(3072, max(256, text.utf8.count * 3)),
            // Long structured rewrites on the 8B model (~35 tok/s on this
            // hardware) can outlast the correction-tuned 60 s default.
            timeoutInterval: 90
        )
        switch result {
        case .success(let rewritten):
            let trimmed = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                log("LLM postprocessing: rewrite returned empty output; passing text through unchanged")
                return text
            }
            log("LLM postprocessing: applied rewrite [\(selection.id)] (\(text.count) → \(trimmed.count) chars)")
            return trimmed
        case .failure(let error):
            log("LLM postprocessing: rewrite request failed (\(error)); passing text through unchanged")
            return text
        }
    }
}
