// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor (corrections transfer & sync).
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

// MARK: - Text correction transfer

struct TranscriptCorrectionsDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let corrections: [TranscriptCorrection]
}

enum TranscriptCorrectionsDocumentError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This corrections file uses schema version \(version), which this version of Parakey cannot read."
        }
    }
}

enum TranscriptCorrectionsTransferError: LocalizedError {
    case fileTooLarge(Int, Int)
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "This corrections file is \(actual), which is larger than Parakey's \(maximum) import limit."
        case .notRegularFile:
            return "The selected corrections path is not a regular file."
        }
    }
}

enum TranscriptCorrectionsTransfer {
    static let schemaVersion = 1
    /// Hard cap for corrections files and in-memory transfers.
    /// Derivation: the worst-case legal set is MAX_TRANSCRIPT_CORRECTIONS
    /// (512) entries at the per-field caps (512 B source + 4096 B
    /// replacement) ≈ 2.25 MiB of raw field bytes, ~2.4 MB once JSON
    /// keys, quoting, and pretty-printing are added — already over the
    /// old 2 MiB cap, which made a full legal set silently unsaveable.
    /// 4 MiB fits that worst case with headroom for JSON escaping while
    /// still rejecting runaway files.
    static let maxFileBytes = 4 * 1024 * 1024

    static var contentType: UTType {
        UTType(filenameExtension: CORRECTIONS_FILE_EXTENSION)
            ?? UTType(exportedAs: CORRECTIONS_FILE_UTI, conformingTo: .json)
    }

    static func encode(_ corrections: [TranscriptCorrection]) throws -> Data {
        let document = TranscriptCorrectionsDocument(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: normalizedTranscriptCorrections(corrections)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// Decode result that also reports how many entries the file held
    /// BEFORE normalization, so the import dialog can disclose
    /// truncation (over-cap, invalid, or duplicate entries) instead of
    /// presenting the capped count as the file's content.
    struct CountedDecodeResult: Sendable, Equatable {
        let corrections: [TranscriptCorrection]
        let originalCount: Int
    }

    static func decode(_ data: Data) throws -> [TranscriptCorrection] {
        try decodeCounted(data).corrections
    }

    static func decodeCounted(_ data: Data) throws -> CountedDecodeResult {
        try validateTransferSize(data.count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(TranscriptCorrectionsDocument.self, from: data) {
            guard document.schemaVersion == schemaVersion else {
                throw TranscriptCorrectionsDocumentError.unsupportedSchema(document.schemaVersion)
            }
            return CountedDecodeResult(
                corrections: normalizedTranscriptCorrections(document.corrections),
                originalCount: document.corrections.count
            )
        }

        // Early internal builds stored the bare array. Keeping the
        // fallback costs almost nothing and makes hand-authored files
        // forgiving while the public file format settles.
        let legacy = try decoder.decode([TranscriptCorrection].self, from: data)
        return CountedDecodeResult(
            corrections: normalizedTranscriptCorrections(legacy),
            originalCount: legacy.count
        )
    }

    static func validateTransferSize(_ bytes: Int) throws {
        guard bytes <= maxFileBytes else {
            throw TranscriptCorrectionsTransferError.fileTooLarge(bytes, maxFileBytes)
        }
    }

    /// Writes the encoded document and returns the exact bytes that
    /// landed on disk, so callers can fingerprint what was written
    /// without re-reading the file (a re-read races with sync
    /// providers replacing the file behind us).
    @discardableResult
    static func write(_ corrections: [TranscriptCorrection], to url: URL) throws -> Data {
        let data = try encode(corrections)
        try validateTransferSize(data.count)
        try validateWritablePath(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func read(from url: URL) throws -> [TranscriptCorrection] {
        try decode(try readData(from: url))
    }

    static func readCounted(from url: URL) throws -> CountedDecodeResult {
        try decodeCounted(try readData(from: url))
    }

    private static func readData(from url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw TranscriptCorrectionsTransferError.notRegularFile
            }
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
        if st.st_size > off_t(maxFileBytes) {
            throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size), maxFileBytes)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            try validateTransferSize(data.count)
        }
        return data
    }

    private static func validateWritablePath(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw currentPOSIXError()
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TranscriptCorrectionsTransferError.notRegularFile
        }
    }
}

// MARK: - Correction sync path safety
//
// The corrections sync-file path is persisted in UserDefaults and used
// by the periodic timer to read and write without further user
// confirmation. If an attacker can plant a leaf symlink at that path
// (e.g. via prior local code execution), each subsequent sync would
// follow it and either read or overwrite an unrelated file. Reject
// leaf-symlinks at the boundary. Parent-directory symlinks are not
// blocked — those are legitimate sync-provider layouts the user has
// already chosen.

enum TranscriptCorrectionsSyncPathError: LocalizedError {
    case isSymbolicLink

    var errorDescription: String? {
        switch self {
        case .isSymbolicLink:
            return "The text correction sync file is a symbolic link. Parakey refuses to sync through symlinks. Reconnect Parakey to a regular file."
        }
    }
}

func normalizedCorrectionSyncFilePath(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_CORRECTION_SYNC_PATH_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          (trimmed as NSString).isAbsolutePath else {
        return nil
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
}

func validateCorrectionSyncPath(_ url: URL) throws {
    var st = stat()
    // lstat (not stat) so we inspect the link itself rather than its
    // target. Missing files are fine — first-time writes are allowed.
    guard lstat(url.path, &st) == 0 else { return }
    if (st.st_mode & S_IFMT) == S_IFLNK {
        throw TranscriptCorrectionsSyncPathError.isSymbolicLink
    }
}

func shouldStopCorrectionSync(afterPathValidationError error: Error) -> Bool {
    error is TranscriptCorrectionsSyncPathError
}

