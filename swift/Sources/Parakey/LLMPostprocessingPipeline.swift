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
    /// The third and last stage, after correction and rewrite
    /// (PunctuationRestoration.swift).
    let punctuation = PunctuationRestorer()

    /// UI feedback for COLD host starts: loading a multi-GB model takes
    /// tens of seconds on first use, and without this the user stares at
    /// the correcting HUD with no idea anything is happening. Set by
    /// ParakeyApp at launch (state toast "Загружается модель …").
    /// @Sendable @MainActor: the closures hop to the main actor and touch
    /// UI only.
    var onHostLoadStage: (@Sendable @MainActor (String) -> Void)?
    var onHostLoadFinished: (@Sendable @MainActor () -> Void)?
    /// Told once when a GPU fault moves the bundled hosts to the CPU.
    var onGPUFallback: (@Sendable @MainActor () -> Void)?
    /// Told as each stage starts, so the HUD shows that stage's animation
    /// (correcting bars, rewrite letters, punctuation marks).
    var onStageStarted: (@Sendable @MainActor (RecordingHUDMode) -> Void)?

    func setStageUI(_ handler: @escaping @Sendable @MainActor (RecordingHUDMode) -> Void) {
        onStageStarted = handler
    }

    /// Set when a bundled host running on the GPU returned NaN logits (HTTP
    /// 503 from the host) or died mid-request. A broken GPU path does that
    /// on every request (MoltenVK on a Radeon Instinct MI50), and before
    /// this the host crashed on each dictation and was reloaded on the
    /// next one — which looked like the model being unloaded after every
    /// dictation, with no correction ever applied. From then on every
    /// bundled host runs on the CPU, and stays loaded there, until the GPU
    /// toggle is flipped (`stop()`) or the agent restarts.
    private var gpuFaulted = false
    /// The failure of the last correction/rewrite request, if any, so the
    /// bundled paths can tell a GPU fault from an ordinary failure.
    private var lastRequestFailure: LLMPostprocessError?

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
    /// shares one host. The pickers overlap (YandexGPT, Phi-4-mini,
    /// Ministral-3B and RuAdapt-4B are in both), and the host keeps a prefix
    /// snapshot per stage, so a shared host loses nothing.
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

    #if DEBUG
    /// Every text `finalizedText` was called with, in order — lets the
    /// `incremental-transcription` self-test pin that the LLM sees only
    /// the final assembled dictation, once.
    private(set) var finalizedTextInputsForTest: [String] = []
    #endif

    /// Applies the configured postprocessing stages to already-
    /// deterministically-corrected text. A no-op (returns `text`
    /// unchanged, no async work) when no stage is enabled or the text is
    /// empty. Order: correction, rewrite, punctuation restoration.
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
        #if DEBUG
        finalizedTextInputsForTest.append(text)
        #endif
        // Settings saved in the other process apply here first; drop hosts
        // for models or stages that are no longer selected.
        await unloadHostsNoLongerNeeded(settings: settings)
        guard !text.isEmpty else { return text }
        var result = text
        if settings.textPostprocessingMode == .correction {
            await onStageStarted?(.correcting)
            result = await correctedText(result, settings: settings)
        }
        if settings.rewriteEnabled {
            await onStageStarted?(.rewriting)
            result = await rewrittenText(result, settings: settings)
        }
        if settings.punctuationRestorationEnabled {
            await onStageStarted?(.punctuating)
            result = await punctuation.restore(result, settings: settings)
        }
        return result
    }

    func setHostLoadUI(stage: @escaping @Sendable @MainActor (String) -> Void,
                       finished: @escaping @Sendable @MainActor () -> Void,
                       gpuFallback: (@Sendable @MainActor () -> Void)? = nil) {
        onHostLoadStage = stage
        onHostLoadFinished = finished
        onGPUFallback = gpuFallback
    }

    /// Whether bundled hosts should be started on the GPU right now.
    private func useGPU(_ settings: Settings) -> Bool {
        settings.llmUseGPU && !gpuFaulted
    }

    var isGPUFaultedForTest: Bool { gpuFaulted }

    /// Whether `failure`, from a host that ran on the GPU, means the GPU
    /// path itself is broken: the host reported NaN logits, or the request
    /// died together with the host process.
    private func isGPUFault(_ failure: LLMPostprocessError?, host: LLMHostProcess) async -> Bool {
        guard let failure else { return false }
        if failure == .httpStatus(503) { return true }
        guard failure == .network else { return false }
        // The connection drops a moment before the process is reaped.
        for _ in 0..<10 {
            if !(await host.isRunning) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// One tiny request to a host freshly started on the GPU, which also
    /// warms the GPU path up. Any sane chat model answers «Привет, как
    /// дела?» starting with «Привет» (a corrector echoes it, an instruct
    /// model greets back); a GPU that computes garbage does not — on the
    /// MI50 it answered « обесп» or NaN. False means: do not trust this GPU.
    private func gpuCanaryPasses(baseURL: URL, model: BundledLLMModel) async -> Bool {
        let result = await OpenAICompatibleClient.chatCompletion(baseURL: baseURL,
                                                                 apiKey: nil,
                                                                 model: "canary-\(model.rawValue)",
                                                                 systemPrompt: "",
                                                                 userText: "Привет, как дела?",
                                                                 enableThinking: false,
                                                                 temperature: 0,
                                                                 maxTokens: 8)
        switch result {
        case .success(let answer):
            let passes = Self.canaryAnswerLooksSane(answer)
            if !passes {
                log("LLM postprocessing: GPU canary for \(model.displayName) answered \"\(answer.prefix(40))\"")
            }
            return passes
        case .failure(let error):
            log("LLM postprocessing: GPU canary for \(model.displayName) failed (\(error))")
            return false
        }
    }

    /// A host started on the GPU that dies of a crash signal before it is
    /// up: the GPU path cannot even start (mac-v0.8.4 shipped without the
    /// Vulkan shaders and crashed in pipeline creation on every start), so
    /// it is a GPU fault like NaN logits, not a reason to skip correction.
    static func isCrashDuringStartup(_ error: LLMHostProcessError) -> Bool {
        guard case .processExitedDuringStartup(let status) = error else { return false }
        return [SIGILL, SIGABRT, SIGBUS, SIGSEGV].contains(status)
    }

    static func canaryAnswerLooksSane(_ answer: String) -> Bool {
        let firstWord = answer
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map { $0.lowercased() } ?? ""
        return firstWord == "привет"
    }

    private func fallBackToCPU(after failure: LLMPostprocessError?) async {
        await fallBackToCPU(reason: failure.map { "\($0)" } ?? "garbage output")
    }

    private func fallBackToCPU(reason: String) async {
        gpuFaulted = true
        log("LLM postprocessing: the GPU host failed (\(reason)); running the LLM on the CPU until the GPU setting changes")
        for host in hostProcesses.values {
            await host.stop()
        }
        hostProcesses.removeAll()
        await onGPUFallback?()
    }

    /// Stops every bundled host subprocess immediately, if running. Call
    /// on app termination or the GPU toggle (hosts bake --gpu-layers into
    /// their arguments).
    func stop() async {
        for host in hostProcesses.values {
            await host.stop()
        }
        await punctuation.unload()
        hostProcesses.removeAll()
        // The GPU toggle stops the hosts before restarting them: a fresh
        // choice deserves a fresh try on the GPU.
        gpuFaulted = false
    }

    /// Stops, right now, every host the current `settings` don't use: a
    /// correction or rewrite stage that was switched off, or a model that
    /// was swapped for another. Each bundled host holds its whole model in
    /// VRAM, so a stale one is never kept warm. Called from the hotkey
    /// toggles, from a live settings save (SETTINGS_LIVE_CHANGED_NOTIFICATION)
    /// and before every dictation's postprocessing. Hosts still needed —
    /// e.g. a shared host while the other stage stays on — keep running.
    func unloadHostsNoLongerNeeded(settings: Settings) async {
        if !settings.punctuationRestorationEnabled {
            await punctuation.unload()
        }
        let needed = Self.neededHostIdentities(settings: settings)
        for (identity, host) in hostProcesses where !needed.contains(identity) {
            await host.stop()
            hostProcesses[identity] = nil
            log("LLM postprocessing: unloaded model host no longer in use (\(identity))")
        }
    }

    /// Starts, ahead of any dictation, the bundled hosts the enabled stages
    /// use, so a model stays resident from agent launch (or a live settings
    /// save) until its stage is switched off or the model is changed —
    /// never loaded on the first dictation. Each fresh host also gets one
    /// tiny request so the first real correction does not pay for the GPU
    /// warm-up. Silent and best-effort: a failure here just leaves the
    /// lazy start in `finalizedText` to try again.
    func prewarmNeededHosts(settings: Settings) async {
        await unloadHostsNoLongerNeeded(settings: settings)
        // Its own process on the CPU: loads alongside the LLM hosts.
        Task { [punctuation] in await punctuation.prewarm(settings: settings) }
        // One host per model: the same model picked for both stages serves
        // both, and is primed for both (`stages`).
        var models: [(identity: String, model: BundledLLMModel, stages: [Bool])] = []
        if settings.textPostprocessingMode == .correction, settings.llmEngineBackend == .bundledLocal {
            let model = settings.correctionBundledModel
            models.append((Self.correctionHostIdentity(model: model), model, [false]))
        }
        if settings.rewriteEnabled, settings.rewriteEngineBackend == .bundledLocal {
            let model = settings.rewriteBundledModel
            let identity = Self.rewriteHostIdentity(model: model)
            if let shared = models.firstIndex(where: { $0.identity == identity }) {
                models[shared].stages.append(true)
            } else {
                models.append((identity, model, [true]))
            }
        }
        let usedGPU = useGPU(settings)
        for (identity, model, stages) in models where bundledLLMModelExists(model) {
            let hostProcess = hostProcess(forIdentity: identity)
            guard !(await hostProcess.isRunning) else { continue }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let startResult = await hostProcess.start(modelPath: bundledLLMModelPath(model).path,
                                                      loraPath: bundledLLMLoraPath(model),
                                                      loraScale: bundledLLMLoraScale(model),
                                                      ctxSize: model.hostContextSize,
                                                      useGPU: usedGPU,
                                                      chatTemplateFile: bundledLLMChatTemplateFile(model)?.path)
            if usedGPU, case .failure(let error) = startResult, Self.isCrashDuringStartup(error) {
                await fallBackToCPU(reason: "\(error)")
                await prewarmNeededHosts(settings: settings)
                return
            }
            guard case .success = startResult, let baseURL = await hostProcess.baseURL else {
                log("LLM postprocessing: pre-warm of \(model.displayName) failed (\(startResult)); will retry on first use")
                continue
            }
            if usedGPU {
                // The canary doubles as the GPU warm-up request.
                guard await gpuCanaryPasses(baseURL: baseURL, model: model) else {
                    await fallBackToCPU(after: nil)
                    await prewarmNeededHosts(settings: settings)
                    return
                }
            } else {
                _ = await OpenAICompatibleClient.chatCompletion(baseURL: baseURL,
                                                                apiKey: nil,
                                                                model: "warmup-\(model.rawValue)",
                                                                systemPrompt: "",
                                                                userText: "Привет.",
                                                                maxTokens: 4)
            }
            // The host reuses the prompt opening a request shares with a
            // recent one (system prompt + few-shot turns, ~270 of ~295
            // tokens for correction; the style's system prompt, ~240 of
            // ~275, for rewrite), keeping several such snapshots: the first
            // request of a kind decodes in full, the second snapshots the
            // shared opening. Two requests shaped like the real ones per
            // stage do both here, so the very first dictation already
            // decodes only its own sentence, in each stage the host serves.
            for rewrite in stages {
                let primer = rewrite ? rewritePrompt(settings: settings)
                                     : correctionPrompt(model: model, settings: settings)
                for sample in ["Проверка связи.", "Раз, два, три."] {
                    _ = await OpenAICompatibleClient.chatCompletion(baseURL: baseURL,
                                                                    apiKey: nil,
                                                                    model: "primer-\(model.rawValue)",
                                                                    systemPrompt: primer.system,
                                                                    exampleTurns: primer.examples,
                                                                    userText: rewrite
                                                                        ? LLMRewritePrompt.userText(for: sample, token: primer.modeToken)
                                                                        : sample,
                                                                    temperature: 0,
                                                                    maxTokens: 1)
                }
            }
            log("LLM postprocessing: pre-warmed \(model.displayName) in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt)) s")
        }
    }

    /// Test-only hooks: register a never-started host under `identity`, and
    /// list the identities currently held.
    func registerIdleHostForTest(identity: String) {
        _ = hostProcess(forIdentity: identity)
    }

    var hostIdentitiesForTest: Set<String> { Set(hostProcesses.keys) }

    /// Test-only hook: whether any bundled host subprocess is currently
    /// running.
    /// Test-only: sends one correction-shaped request to the running
    /// correction host and returns how many prompt tokens the host served
    /// from its prefix snapshot (`usage.prompt_tokens_details.cached_tokens`).
    func correctionCachedTokensForTest(_ text: String, settings: Settings) async -> Int? {
        let model = settings.correctionBundledModel
        let prompt = correctionPrompt(model: model, settings: settings)
        let messages = [OpenAICompatibleMessage(role: .system, content: prompt.system)]
            + prompt.examples + [OpenAICompatibleMessage(role: .user, content: text)]
        return await cachedTokensForTest(identity: Self.correctionHostIdentity(model: model), messages: messages)
    }

    /// Test-only: the same, for a rewrite-shaped request to the rewrite host.
    func rewriteCachedTokensForTest(_ text: String, settings: Settings) async -> Int? {
        let model = settings.rewriteBundledModel
        let prompt = rewritePrompt(settings: settings)
        let messages = [OpenAICompatibleMessage(role: .system, content: prompt.system)]
            + prompt.examples
            + [OpenAICompatibleMessage(role: .user, content: LLMRewritePrompt.userText(for: text, token: prompt.modeToken))]
        return await cachedTokensForTest(identity: Self.rewriteHostIdentity(model: model), messages: messages)
    }

    private func cachedTokensForTest(identity: String, messages: [OpenAICompatibleMessage]) async -> Int? {
        guard let host = hostProcesses[identity],
              let baseURL = await host.baseURL else { return nil }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let encoded = try? JSONEncoder().encode(messages),
              let messagesJSON = try? JSONSerialization.jsonObject(with: encoded),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "messages": messagesJSON, "max_tokens": 1,
                  "chat_template_kwargs": ["enable_thinking": false],
              ]) else { return nil }
        req.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // loopback; see OpenAICompatibleClient
        guard let (data, _) = try? await URLSession(configuration: config).data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any],
              let details = usage["prompt_tokens_details"] as? [String: Any] else { return nil }
        return details["cached_tokens"] as? Int
    }

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
        let usedGPU = useGPU(settings)
        let coldStart = !(await hostProcess.isRunning)
        if coldStart {
            await onHostLoadStage?("Загружается модель \(model.displayName)…")
        }
        let startResult = await hostProcess.start(modelPath: bundledLLMModelPath(model).path,
                                                  loraPath: bundledLLMLoraPath(model),
                                                  loraScale: bundledLLMLoraScale(model),
                                                  ctxSize: model.hostContextSize,
                                                  useGPU: usedGPU,
                                                  chatTemplateFile: bundledLLMChatTemplateFile(model)?.path)
        if coldStart {
            await onHostLoadFinished?()
        }
        switch startResult {
        case .failure(let error):
            if usedGPU, Self.isCrashDuringStartup(error) {
                await fallBackToCPU(reason: "\(error)")
                return await correctedViaBundledHost(text, settings: settings)
            }
            log("LLM postprocessing: bundled host failed to start (\(error)); passing text through unchanged")
            return text
        case .success:
            break
        }
        guard let baseURL = await hostProcess.baseURL else {
            log("LLM postprocessing: bundled host has no reachable baseURL; passing text through unchanged")
            return text
        }
        if usedGPU, coldStart, !(await gpuCanaryPasses(baseURL: baseURL, model: model)) {
            await fallBackToCPU(after: nil)
            return await correctedViaBundledHost(text, settings: settings)
        }
        lastRequestFailure = nil
        let corrected = await requestCorrection(baseURL: baseURL,
                                                apiKey: nil,
                                                model: "gec-\(model.rawValue)",
                                                bundledModel: model,
                                                text: text,
                                                settings: settings)
        if usedGPU, let failure = lastRequestFailure,
           await isGPUFault(failure, host: hostProcess) {
            await fallBackToCPU(after: failure)
            // Once: gpuFaulted now keeps this call on the CPU.
            return await correctedViaBundledHost(text, settings: settings)
        }
        return corrected
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

    private typealias StagePrompt = (system: String, examples: [OpenAICompatibleMessage], modeToken: String)

    private func correctionPrompt(model: BundledLLMModel, settings: Settings) -> StagePrompt {
        // A user-edited system prompt replaces the built-in default —
        // EXCEPT for models with a mandatory prompt (Loqira): the lock is
        // enforced here, at the single point where prompts are built.
        let override = model.allowsCustomSystemPrompt
            ? settings.correctionSystemPromptOverride
            : ""
        let system = override.isEmpty
            ? LLMCorrectionPrompt.systemPrompt(vocabulary: settings.transcriptCorrections, model: model)
            : override
        return (system, LLMCorrectionPrompt.exampleTurns(vocabulary: settings.transcriptCorrections, model: model), "")
    }

    private func rewritePrompt(settings: Settings) -> StagePrompt {
        // Active style: built-in or user-created
        // (docs/specs/custom-rewrite-styles-spec.md). Per-style user-edited
        // system prompt; empty = the built-in default. The «Режим:»
        // user-turn suffix is NOT editable for built-ins (benchmark
        // contract); user-created modes use their uppercased name.
        let examples = LLMRewritePrompt.exampleTurns(style: .polish)
        switch settings.rewriteStyleSelection() {
        case .builtin(let style):
            let override = settings.rewriteSystemPromptOverride(for: style)
            return (override.isEmpty ? LLMRewritePrompt.systemPrompt(style: style) : override,
                    examples, LLMRewritePrompt.modeToken(style))
        case .custom(let custom):
            let override = settings.rewriteSystemPromptOverride(forStyleID: custom.id)
            return (override.isEmpty ? LLMRewritePrompt.systemPrompt(custom: custom) : override,
                    examples, custom.name.uppercased())
        }
    }

    private func requestCorrection(baseURL: URL,
                                   apiKey: String?,
                                   model: String,
                                   bundledModel: BundledLLMModel,
                                   text: String,
                                   settings: Settings) async -> String {
        let (systemPrompt, exampleTurns, _) = correctionPrompt(model: bundledModel, settings: settings)
        // One request per sentence-bounded chunk (see
        // LLMCorrectionGuardrail.correctionChunks): a long dictation in one
        // request is where the model loses or replaces text, and the
        // guardrail then reverts each chunk on its own.
        let chunks = LLMCorrectionGuardrail.correctionChunks(text)
        var correctedChunks: [String] = []
        var keptOriginal = 0
        for (index, chunk) in chunks.enumerated() {
            // Correction output is roughly the same length as the input,
            // never longer in any meaningful way -- a generous multiple of
            // the raw UTF-8 byte count is a safe token-budget heuristic
            // without needing a real tokenizer on the Swift side.
            let maxTokens = min(2048, max(64, chunk.utf8.count))
            let result = await OpenAICompatibleClient.chatCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                exampleTurns: exampleTurns,
                userText: chunk,
                enableThinking: false,
                temperature: 0,
                maxTokens: maxTokens,
                useSystemProxy: settings.llmUseSystemProxy
            )
            switch result {
            case .success(let corrected):
                let sanitized = LLMCorrectionGuardrail.sanitizedCorrection(input: chunk, output: corrected)
                if sanitized == chunk { keptOriginal += 1 }
                correctedChunks.append(sanitized)
            case .failure(let error):
                // A failed request (host down, timeout) would fail the same
                // way for every remaining chunk; don't wait it out N times.
                lastRequestFailure = error
                log("LLM postprocessing: correction request failed (\(error)); passing the remaining \(chunks.count - index) chunk(s) through unchanged")
                keptOriginal += chunks.count - index
                correctedChunks.append(contentsOf: chunks[index...])
            }
            if correctedChunks.count == chunks.count { break }
        }
        guard !correctedChunks.isEmpty else { return text }
        let corrected = correctedChunks.joined(separator: " ")
        log("LLM postprocessing: applied correction (\(text.count) → \(corrected.count) chars, \(chunks.count) chunk(s), \(keptOriginal) unchanged)")
        return corrected
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
        let usedGPU = useGPU(settings)
        let coldStart = !(await hostProcess.isRunning)
        if coldStart {
            await onHostLoadStage?("Загружается модель \(model.displayName)…")
        }
        let startResult = await hostProcess.start(modelPath: bundledLLMModelPath(model).path,
                                                  loraPath: bundledLLMLoraPath(model),
                                                  loraScale: bundledLLMLoraScale(model),
                                                  ctxSize: model.hostContextSize,
                                                  useGPU: usedGPU,
                                                  chatTemplateFile: bundledLLMChatTemplateFile(model)?.path)
        if coldStart {
            await onHostLoadFinished?()
        }
        switch startResult {
        case .failure(let error):
            if usedGPU, Self.isCrashDuringStartup(error) {
                await fallBackToCPU(reason: "\(error)")
                return await rewrittenViaBundledHost(text, settings: settings)
            }
            log("LLM postprocessing: bundled rewrite host failed to start (\(error)); passing text through unchanged")
            return text
        case .success:
            break
        }
        guard let baseURL = await hostProcess.baseURL else {
            log("LLM postprocessing: bundled rewrite host has no reachable baseURL; passing text through unchanged")
            return text
        }
        if usedGPU, coldStart, !(await gpuCanaryPasses(baseURL: baseURL, model: model)) {
            await fallBackToCPU(after: nil)
            return await rewrittenViaBundledHost(text, settings: settings)
        }
        lastRequestFailure = nil
        let rewritten = await requestRewrite(baseURL: baseURL,
                                             apiKey: nil,
                                             model: "rewrite-\(model.rawValue)",
                                             text: text,
                                             settings: settings)
        if usedGPU, let failure = lastRequestFailure,
           await isGPUFault(failure, host: hostProcess) {
            await fallBackToCPU(after: failure)
            return await rewrittenViaBundledHost(text, settings: settings)
        }
        return rewritten
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
        let selection = settings.rewriteStyleSelection()
        let (systemPrompt, exampleTurns, modeToken) = rewritePrompt(settings: settings)
        let result = await OpenAICompatibleClient.chatCompletion(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            exampleTurns: exampleTurns,
            userText: LLMRewritePrompt.userText(for: text, token: modeToken),
            enableThinking: false,
            temperature: 0,
            // Rewrite may legitimately EXPAND text (task structuring adds
            // section headers; benchmark rewrite runs used 1024 tokens for
            // typical inputs) — 3x the input's UTF-8 bytes, clamped to the
            // same 3072 ceiling the 8192-token host context fits next to a
            // long prompt.
            maxTokens: min(3072, max(256, text.utf8.count * 3)),
            useSystemProxy: settings.llmUseSystemProxy,
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
            lastRequestFailure = error
            log("LLM postprocessing: rewrite request failed (\(error)); passing text through unchanged")
            return text
        }
    }
}
