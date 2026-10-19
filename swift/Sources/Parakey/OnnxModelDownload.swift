// SuperDictate — ONNX ASR model catalog + multi-file download
// (docs/specs/cross-platform-onnx-asr-spec.md §7).
//
// Unlike the single-file GGUF pins in ModelDownload.swift, an ONNX model is
// a directory of graphs plus a tokenizer. The pinned catalog
// (native/asr-runtime/catalog/onnx-models.json) and the bundled
// preprocessor graphs (nemo128.onnx, gigaam_v3.onnx) ship inside the app at
// Contents/Resources/onnx-asr/, so URLs, sizes and SHA-256 digests are
// versioned with the code, never taken from the environment. Each file is
// downloaded to a same-volume temp file, size- and SHA-256-verified, then
// atomically renamed; manifest.json is written LAST, so its presence marks
// a complete, verified install (same contract as tools/make_manifest.py).

import Foundation

let PARAKEET_ULTRA_ONNX_MODEL_ID = "parakeet-ultra-int8"
/// Sum of the four downloaded files in the pinned catalog entry (encoder,
/// decoder, joiner, tokens) — used for the disk-space precheck and UI text
/// before the catalog is read.
let PARAKEET_ULTRA_ONNX_SIZE_BYTES: Int64 = 611_879_344 + 12_257_685 + 5_281_747 + 93_939

let GIGAAM_V3_ONNX_MODEL_ID = "gigaam-v3-e2e-rnnt-int8"
/// Same for the GigaAM v3 e2e RNN-T entry (its gigaam_v3.onnx preprocessor
/// is bundled, not downloaded).
let GIGAAM_V3_ONNX_SIZE_BYTES: Int64 = 224_570_477 + 1_159_170 + 687_791 + 13_354

enum OnnxModelDownloadError: LocalizedError {
    case resourcesUnavailable
    case catalogInvalid(String)
    case modelNotInCatalog(String)
    case unsafePath(String)
    case unsafeURL(String)
    case httpError(file: String, statusCode: Int)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case checksumMismatch(file: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .resourcesUnavailable:
            return "ONNX ASR resources (catalog, preprocessor) are missing from the app bundle"
        case .catalogInvalid(let detail):
            return "ONNX model catalog is invalid: \(detail)"
        case .modelNotInCatalog(let id):
            return "ONNX model \(id) is not in the bundled catalog"
        case .unsafePath(let detail):
            return "Refusing unsafe ONNX model path: \(detail)"
        case .unsafeURL(let url):
            return "Refusing ONNX model download from unexpected URL: \(url)"
        case .httpError(let file, let statusCode):
            return "ONNX model download of \(file) failed with HTTP \(statusCode)"
        case .sizeMismatch(let file, let expected, let actual):
            return "Downloaded ONNX model file \(file) size mismatch: expected \(expected) bytes, got \(actual) bytes"
        case .checksumMismatch(let file, let expected, let actual):
            return "Downloaded ONNX model file \(file) checksum mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Where the bundled ONNX ASR resources live. In the packaged app both the
/// catalog and the preprocessor graph sit in Contents/Resources/onnx-asr/.
/// DEBUG builds (swift build / self-tests) fall back to the source tree so
/// diagnostics work without packaging; release builds never do.
struct OnnxAsrResources: Sendable {
    let catalogURL: URL
    let assetsDirectory: URL
}

func resolvedOnnxAsrResources() -> OnnxAsrResources? {
    let fm = FileManager.default
    if let resources = Bundle.main.resourceURL {
        let directory = resources.appendingPathComponent("onnx-asr", isDirectory: true)
        let catalog = directory.appendingPathComponent("onnx-models.json", isDirectory: false)
        if isPlainRegularFile(catalog.path),
           isPlainRegularFile(directory.appendingPathComponent("nemo128.onnx").path) {
            return OnnxAsrResources(catalogURL: catalog, assetsDirectory: directory)
        }
    }
    #if DEBUG
    let runtime = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Parakey
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("native/asr-runtime", isDirectory: true)
    let catalog = runtime.appendingPathComponent("catalog/onnx-models.json")
    let assets = runtime.appendingPathComponent("assets", isDirectory: true)
    if fm.fileExists(atPath: catalog.path),
       fm.fileExists(atPath: assets.appendingPathComponent("nemo128.onnx").path) {
        return OnnxAsrResources(catalogURL: catalog, assetsDirectory: assets)
    }
    #endif
    return nil
}

/// `~/Library/Application Support/SuperDictate/onnx/<model_id>/` (spec §7).
func onnxModelCacheDirectory(modelID: String) -> URL {
    speechModelCacheBaseDirectory()
        .appendingPathComponent("onnx", isDirectory: true)
        .appendingPathComponent(modelID, isDirectory: true)
}

func onnxModelManifestURL(modelID: String) -> URL {
    onnxModelCacheDirectory(modelID: modelID).appendingPathComponent("manifest.json", isDirectory: false)
}

/// One downloadable file of a catalog entry.
struct OnnxCatalogFile: Sendable {
    let role: String
    let path: String
    let url: URL
    let size: Int64
    let sha256: String
}

/// A parsed catalog entry: the raw dictionary (to derive manifest.json
/// from) plus the validated downloadable files.
struct OnnxCatalogEntry: @unchecked Sendable {
    let modelID: String
    let revision: String
    let raw: [String: Any]
    let files: [OnnxCatalogFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Same rules as the native loader (spec §7): a plain file name, never
/// absolute, never a separator or `..`.
func isSafeOnnxModelFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".."
        && !name.contains("/") && !name.contains("\\")
        && !name.hasPrefix(".") && name != "manifest.json"
}

func loadOnnxCatalogEntry(modelID: String,
                          catalogURL: URL) throws -> OnnxCatalogEntry {
    let data = try Data(contentsOf: catalogURL)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["schema"] as? Int == 1,
          let models = root["models"] as? [[String: Any]] else {
        throw OnnxModelDownloadError.catalogInvalid("expected {\"schema\": 1, \"models\": [...]}")
    }
    guard let entry = models.first(where: { $0["model_id"] as? String == modelID }) else {
        throw OnnxModelDownloadError.modelNotInCatalog(modelID)
    }
    guard let revision = entry["revision"] as? String,
          let files = entry["files"] as? [String: [String: Any]] else {
        throw OnnxModelDownloadError.catalogInvalid("\(modelID): missing revision/files")
    }
    var parsed: [OnnxCatalogFile] = []
    for role in files.keys.sorted() {
        let spec = files[role]!
        guard let path = spec["path"] as? String else { continue }  // bundled asset
        guard isSafeOnnxModelFileName(path) else {
            throw OnnxModelDownloadError.unsafePath("\(role): \(path)")
        }
        guard let urlString = spec["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "https", url.host == "huggingface.co" else {
            throw OnnxModelDownloadError.unsafeURL("\(role): \(spec["url"] ?? "nil")")
        }
        guard let size = (spec["size"] as? NSNumber)?.int64Value, size > 0,
              let sha = spec["sha256"] as? String, sha.count == 64 else {
            throw OnnxModelDownloadError.catalogInvalid("\(role): missing size/sha256")
        }
        parsed.append(OnnxCatalogFile(role: role, path: path, url: url, size: size, sha256: sha.lowercased()))
    }
    guard !parsed.isEmpty else {
        throw OnnxModelDownloadError.catalogInvalid("\(modelID): no downloadable files")
    }
    return OnnxCatalogEntry(modelID: modelID, revision: revision, raw: entry, files: parsed)
}

/// manifest.json for an installed model: the catalog entry minus the
/// download URLs and catalog-only presentation keys (mirrors
/// tools/make_manifest.py exactly).
func onnxManifestData(for entry: OnnxCatalogEntry) throws -> Data {
    let catalogOnlyKeys: Set<String> = ["display_name", "source", "base_model", "attribution"]
    var manifest: [String: Any] = ["schema": 1]
    for (key, value) in entry.raw where !catalogOnlyKeys.contains(key) {
        if key == "files", let files = value as? [String: [String: Any]] {
            manifest[key] = files.mapValues { $0.filter { $0.key != "url" } }
        } else {
            manifest[key] = value
        }
    }
    return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
}

/// True when manifest.json is present, belongs to the pinned revision and
/// every listed file still has the expected size. Hashes are NOT recomputed
/// here: the manifest is written only after every file was verified.
func onnxInstalledModelMatchesCatalog(_ entry: OnnxCatalogEntry, directory: URL) -> Bool {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard isPlainRegularFile(manifestURL.path),
          let data = try? Data(contentsOf: manifestURL),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          manifest["model_id"] as? String == entry.modelID,
          manifest["revision"] as? String == entry.revision else {
        return false
    }
    return entry.files.allSatisfy { file in
        let path = directory.appendingPathComponent(file.path).path
        guard isPlainRegularFile(path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value == file.size
    }
}

/// Delegate-backed single-file download that moves the finished file to a
/// caller-chosen same-volume path INSIDE `didFinishDownloadingTo` (the
/// system deletes the temp file as soon as that callback returns).
private final class OnnxFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let fileName: String
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var moved = false

    init(destination: URL, fileName: String, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.fileName = fileName
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = OnnxModelDownloadError.httpError(file: fileName, statusCode: http.statusCode)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error = error ?? failure {
            continuation.resume(throwing: error)
        } else if moved {
            continuation.resume()
        } else {
            continuation.resume(throwing: OnnxModelDownloadError.httpError(file: fileName, statusCode: -1))
        }
    }
}

private func downloadOnnxFile(_ file: OnnxCatalogFile,
                              into directory: URL,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
    let destination = directory.appendingPathComponent(file.path, isDirectory: false)
    let temp = directory.appendingPathComponent(".\(file.path).download-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: temp) }

    let delegate = OnnxFileDownloadDelegate(destination: temp, fileName: file.path, progress: progress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        delegate.setContinuation(continuation)
        session.downloadTask(with: file.url).resume()
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
    let actualSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    guard actualSize == file.size else {
        throw OnnxModelDownloadError.sizeMismatch(file: file.path, expected: file.size, actual: actualSize)
    }
    let actualHash = try sha256Hex(ofFileAt: temp)
    guard actualHash == file.sha256 else {
        throw OnnxModelDownloadError.checksumMismatch(file: file.path, expected: file.sha256, actual: actualHash)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
    } else {
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

/// Ensures the profile's pinned ONNX model is installed and verified;
/// returns its directory. Files already present with the right size AND hash are kept
/// (an interrupted install resumes per file); everything else is fetched.
@discardableResult
func downloadOnnxModelIfNeeded(profile: SpeechModelProfile,
                               progressHandler: SpeechModelDownloadProgressHandler? = nil) async throws -> URL {
    let modelID = profile.onnxModelID
    guard let resources = resolvedOnnxAsrResources() else {
        throw OnnxModelDownloadError.resourcesUnavailable
    }
    let entry = try loadOnnxCatalogEntry(modelID: modelID, catalogURL: resources.catalogURL)
    let directory = onnxModelCacheDirectory(modelID: modelID)
    if onnxInstalledModelMatchesCatalog(entry, directory: directory) {
        return directory
    }

    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) && !isExistingPlainDirectory(directory.path) {
        throw OnnxModelDownloadError.unsafePath("cache path is not a plain directory: \(directory.path)")
    }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    // A stale manifest (other revision / damaged file) must not mark the
    // directory complete while files are being replaced.
    try? fm.removeItem(at: directory.appendingPathComponent("manifest.json"))

    var missing: [OnnxCatalogFile] = []
    for file in entry.files {
        let path = directory.appendingPathComponent(file.path)
        if isPlainRegularFile(path.path),
           ((try? fm.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.int64Value == file.size,
           (try? sha256Hex(ofFileAt: path)) == file.sha256 {
            continue
        }
        if fm.fileExists(atPath: path.path) {
            guard isPlainRegularFile(path.path) else {
                throw OnnxModelDownloadError.unsafePath("not a plain file: \(path.path)")
            }
            try fm.removeItem(at: path)
        }
        missing.append(file)
    }

    if !missing.isEmpty {
        try assertSufficientDiskSpaceForSpeechModelDownload(profile: profile)
        let totalBytes = Double(max(1, missing.reduce(0) { $0 + $1.size }))
        var completedBytes: Int64 = 0
        log("ASR: downloading ONNX model \(modelID) (\(missing.map(\.path).joined(separator: ", ")))")
        for file in missing {
            let base = completedBytes
            try await downloadOnnxFile(file, into: directory) { written in
                progressHandler?(min(1, Double(base + written) / totalBytes))
            }
            completedBytes += file.size
            progressHandler?(min(1, Double(completedBytes) / totalBytes))
        }
    }

    let manifestTemp = directory.appendingPathComponent(".manifest.json.tmp-\(UUID().uuidString)")
    try onnxManifestData(for: entry).write(to: manifestTemp)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    if fm.fileExists(atPath: manifestURL.path) {
        _ = try fm.replaceItemAt(manifestURL, withItemAt: manifestTemp)
    } else {
        try fm.moveItem(at: manifestTemp, to: manifestURL)
    }
    return directory
}
