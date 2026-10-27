import Foundation

// MARK: - Punctuation restoration
//
// The last text stage of a dictation: speech recognition, then correction,
// then rewrite (when enabled), then this. A ModernBERT token classifier
// (Horizon-Labs/punctuation-restoration-{small,base}, Apache-2.0) predicts
// a mark after every word; the merge with the marks the earlier stages
// already set lives in native/asr-runtime/src/families/punct_text.cpp. It
// runs on the CPU inside its own SuperDictateOnnxHost process.
//
// Like the LLM stages it must never lose or block the dictated text: a
// model that is not downloaded, a host that would not start or a failed
// request all return the input unchanged.

enum PunctuationModel: String, CaseIterable, Sendable {
    case small
    case base

    /// Entry in native/asr-runtime/catalog/onnx-models.json.
    var onnxModelID: String { "punct-\(rawValue)-int8" }

    var displayName: String {
        switch self {
        case .small: return "Small (140M)"
        case .base: return "Base (307M)"
        }
    }

    /// Model + tokenizer, as pinned in the catalog.
    var downloadBytes: Int64 {
        switch self {
        case .small: return 268_414_381 + 34_363_286
        case .base: return 641_137_205 + 34_363_286
        }
    }
}

/// Whether the model's pinned files are installed (sizes and manifest; the
/// hashes were checked when they were downloaded).
func punctuationModelInstalled(_ model: PunctuationModel) -> Bool {
    guard let resources = resolvedOnnxAsrResources(),
          let entry = try? loadOnnxCatalogEntry(modelID: model.onnxModelID, catalogURL: resources.catalogURL) else {
        return false
    }
    return onnxInstalledModelMatchesCatalog(entry, directory: onnxModelCacheDirectory(modelID: model.onnxModelID))
}

@discardableResult
func downloadPunctuationModelIfNeeded(_ model: PunctuationModel,
                                      progressHandler: SpeechModelDownloadProgressHandler? = nil) async throws -> URL {
    try await downloadOnnxModelIfNeeded(
        modelID: model.onnxModelID,
        checkDiskSpace: {
            let required = model.downloadBytes + MODEL_DOWNLOAD_HEADROOM_BYTES
            let available = availableImportantDiskSpaceBytes(containing: speechModelCacheBaseDirectory())
            if let available, available < required {
                throw NSError(domain: "Parakey", code: -8, userInfo: [
                    NSLocalizedDescriptionKey: "Not enough free disk space for the punctuation model: \(formattedByteCount(UInt64(required))) needed, \(formattedByteCount(UInt64(available))) available.",
                ])
            }
        },
        progressHandler: progressHandler
    )
}

actor PunctuationRestorer {
    private var engine: OnnxAsrEngine?
    private var loadedModel: PunctuationModel?
    /// One "not downloaded" line per model and run, not one per dictation.
    private var reportedMissing: Set<PunctuationModel> = []

    /// ~60 ms per sentence with Base at 4 threads; more threads barely help
    /// a model this size and would compete with the ASR host.
    static let threadCount = 4

    func restore(_ text: String, settings: Settings) async -> String {
        guard settings.punctuationRestorationEnabled else {
            await unload()
            return text
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let engine = await engine(for: settings.punctuationModel) else { return text }
        do {
            let result = try await engine.punctuate(text: text)
            log("Punctuation: \(settings.punctuationModel.rawValue) in \(String(format: "%.0f", result.processingSeconds * 1000)) ms")
            return result.text.isEmpty ? text : result.text
        } catch {
            log("Punctuation: request failed (\(error.localizedDescription)); keeping the text as it was")
            if !(await engine.isAlive) { await unload() }
            return text
        }
    }

    /// Loads the selected model ahead of the first dictation, or frees it
    /// when the stage is off.
    func prewarm(settings: Settings) async {
        if settings.punctuationRestorationEnabled {
            _ = await engine(for: settings.punctuationModel)
        } else {
            await unload()
        }
    }

    func unload() async {
        guard let engine else { return }
        await engine.shutdown()
        self.engine = nil
        if let loadedModel { log("Punctuation: unloaded \(loadedModel.rawValue)") }
        loadedModel = nil
    }

    var isLoadedForTest: Bool { engine != nil }

    private func engine(for model: PunctuationModel) async -> OnnxAsrEngine? {
        if loadedModel == model, let engine, await engine.isAlive { return engine }
        await unload()
        guard punctuationModelInstalled(model) else {
            if !reportedMissing.contains(model) {
                reportedMissing.insert(model)
                log("Punctuation: model \(model.onnxModelID) is not downloaded; skipping (download it in Settings)")
            }
            return nil
        }
        do {
            let launched = try await OnnxAsrEngine.launch(
                modelDirectory: onnxModelCacheDirectory(modelID: model.onnxModelID),
                threadCount: Self.threadCount,
                expectedModelID: model.onnxModelID
            )
            log("Punctuation: loaded \(model.onnxModelID) in \(String(format: "%.1f", await launched.loadSeconds)) s")
            engine = launched
            loadedModel = model
            return launched
        } catch {
            log("Punctuation: could not load \(model.onnxModelID) (\(error.localizedDescription))")
            return nil
        }
    }
}
