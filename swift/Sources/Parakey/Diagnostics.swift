// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
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

// MARK: - Diagnostics
//
// User-triggered local diagnostics for GitHub issue triage. Keep the
// report useful but metadata-only: no transcript text and no text
// correction contents.

struct DiagnosticsReportSnapshot {
    let generated: String
    let appVersion: String
    let appBuild: String
    let macOS: String
    let bundleID: String
    let bundlePath: String
    let installKind: String
    let status: String
    let startup: String
    let speechModelReady: Bool
    let coreRuntimeReady: Bool
    let readyForDictation: Bool
    let recordingActive: Bool
    let transcribing: Bool
    let memoryLines: [String]
    let permissionLines: [String]
    let settingLines: [String]
    let updateLines: [String]
    let microphoneLines: [String]
    let logPath: String
    let recentLogLines: [String]
}

private func diagnosticBulletLines(_ lines: [String], emptyText: String) -> String {
    guard !lines.isEmpty else { return "- \(emptyText)" }
    return lines.map { "- \($0)" }.joined(separator: "\n")
}

func diagnosticsReportText(from snapshot: DiagnosticsReportSnapshot) -> String {
    """
    Parakey diagnostics
    Generated: \(snapshot.generated)
    App version: \(snapshot.appVersion) (\(snapshot.appBuild))
    macOS: \(snapshot.macOS)
    Bundle ID: \(snapshot.bundleID)
    Bundle path: \(snapshot.bundlePath)
    Install kind: \(snapshot.installKind)

    Status:
    - Menu: \(snapshot.status)
    - Startup: \(snapshot.startup)
    - Speech model ready: \(snapshot.speechModelReady)
    - Core runtime ready: \(snapshot.coreRuntimeReady)
    - Ready for dictation: \(snapshot.readyForDictation)
    - Recording active: \(snapshot.recordingActive)
    - Transcribing: \(snapshot.transcribing)

    Memory:
    \(diagnosticBulletLines(snapshot.memoryLines, emptyText: "Unavailable"))

    Permissions:
    \(diagnosticBulletLines(snapshot.permissionLines, emptyText: "Unavailable"))

    Settings:
    \(diagnosticBulletLines(snapshot.settingLines, emptyText: "Unavailable"))

    Update:
    \(diagnosticBulletLines(snapshot.updateLines, emptyText: "Unavailable"))

    Microphone:
    \(diagnosticBulletLines(snapshot.microphoneLines, emptyText: "Unavailable"))

    Recent log lines:
    \(diagnosticBulletLines(snapshot.recentLogLines, emptyText: "No recent log lines available"))

    Logs: \(snapshot.logPath)
    Privacy: transcript text and text-correction contents are not included.
    """
}

func recentDiagnosticLogLines(from url: URL = Logger.shared.fileURL,
                              maxBytes: Int = DIAGNOSTICS_LOG_MAX_BYTES,
                              maxLines: Int = DIAGNOSTICS_LOG_MAX_LINES) throws -> [String] {
    guard maxBytes > 0, maxLines > 0 else { return [] }

    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        if errno == ENOENT { return [] }
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
    guard st.st_size > 0 else { return [] }

    let startOffset = max(Int64(0), Int64(st.st_size) - Int64(maxBytes))
    guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) >= 0 else {
        throw currentPOSIXError()
    }

    var data = Data()
    data.reserveCapacity(min(maxBytes, Int(st.st_size)))
    while data.count < maxBytes {
        let remaining = maxBytes - data.count
        var buffer = [UInt8](repeating: 0, count: min(8192, remaining))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
        guard bytesRead > 0 else { break }
        data.append(buffer, count: bytesRead)
    }

    var text = String(decoding: data, as: UTF8.self)
    if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
    }

    let sanitized = text
        .components(separatedBy: .newlines)
        .map(sanitizedDiagnosticLogLine)
        .filter { !$0.isEmpty }
    return Array(sanitized.suffix(maxLines))
}

private func sanitizedDiagnosticLogLine(_ line: String) -> String {
    var result = String()
    result.reserveCapacity(min(line.count, DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS))
    for scalar in line.unicodeScalars {
        guard result.count < DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS else { break }
        if scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f) {
            result.unicodeScalars.append(scalar)
        } else {
            result.append(" ")
        }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

func parseSemver(_ s: String) -> [Int] {
    // Strip leading whitespace + 'v', split on '.', take leading
    // digit run from each chunk. Tolerant by design; "" returns []
    // which compares less than any real version.
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .drop(while: { $0 == "v" || $0 == "V" })
    return trimmed.split(separator: ".").map { chunk in
        var n = 0
        var seen = false
        for c in chunk {
            guard let d = c.wholeNumberValue else { break }
            let multiplied = n.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return Int.max }
            let added = multiplied.partialValue.addingReportingOverflow(d)
            if added.overflow { return Int.max }
            n = added.partialValue
            seen = true
        }
        return seen ? n : 0
    }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = parseSemver(candidate)
    let b = parseSemver(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

