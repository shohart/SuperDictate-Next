// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

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

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/SuperDictate.log.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let q = DispatchQueue(label: "ParakeyLogger")

    var fileURL: URL { url }

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("SuperDictate.log")
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        q.async { [url] in
            do {
                try appendPrivateLogData(data, to: url)
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}

func log(_ msg: String) { Logger.shared.log(msg) }

func superDictateApplicationSupportDirectory() throws -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

struct AgentRuntimeState: Codable {
    var status: String
    var detail: String
    var updatedAt: TimeInterval
    var pid: Int32
    var isReady: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    var speechModelReady: Bool
    var missingPermissions: [String]
    var hotkeyName: String
    var triggerMode: String
    var downloadProgressFraction: Double?
}

enum AgentRuntimeStateStore {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(AGENT_STATUS_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(AGENT_STATUS_FILE_NAME)
    }

    static func write(_ state: AgentRuntimeState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            log("agent state write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> AgentRuntimeState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AgentRuntimeState.self, from: data)
        } catch {
            return nil
        }
    }
}

enum SuperDictateControlPanelRegistry {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)
    }

    @MainActor
    static func activateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else {
            return false
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    static func terminateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else { return false }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.terminate() {
            return true
        }
        kill(pid, SIGTERM)
        return true
    }

    static func claimCurrentPanel() -> Bool {
        for _ in 0..<2 {
            let fd = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if fd >= 0 {
                do {
                    try writeAllData(Data("\(getpid())\n".utf8), to: fd)
                    guard Darwin.close(fd) == 0 else {
                        _ = Darwin.unlink(url.path)
                        log("control panel pid close failed")
                        return false
                    }
                    return true
                } catch {
                    _ = Darwin.close(fd)
                    _ = Darwin.unlink(url.path)
                    log("control panel pid write failed: \(error.localizedDescription)")
                    return false
                }
            }

            guard errno == EEXIST else {
                log("control panel pid claim failed: \(currentPOSIXError().localizedDescription)")
                return false
            }
            if currentPanelPID() != nil {
                return false
            }
            _ = Darwin.unlink(url.path)
        }
        return false
    }

    static func clearCurrentPanel() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func currentPanelPID() -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid(),
              processIsAlive(pid: pid) else {
            return nil
        }
        return pid
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

struct ProcessRunResult {
    let status: Int32
    let output: String
}

enum SuperDictateAgentService {
    static var launchAgentURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return directory.appendingPathComponent("\(AGENT_LABEL).plist")
    }

    static var launchDomain: String { "gui/\(getuid())" }
    static var launchService: String { "\(launchDomain)/\(AGENT_LABEL)" }

    static func agentExecutablePath() -> String {
        Bundle.main.executablePath ??
        "\(INSTALLED_APP_BUNDLE_PATH)/Contents/MacOS/SuperDictate"
    }

    static func installAndStart() throws {
        try writeLaunchAgentPlist()
        _ = runLaunchctl(["bootstrap", launchDomain, launchAgentURL.path])
        _ = runLaunchctl(["enable", launchService])
        if isAgentRunning() {
            return
        }
        // Never use `kickstart -k` here: opening the control panel while
        // CoreML is still loading must not kill the healthy agent and make
        // Neural Engine preparation start over.
        let kick = runLaunchctl(["kickstart", launchService])
        if kick.status != 0 && !isAgentRunning() {
            throw NSError(domain: "SuperDictateAgentService",
                          code: Int(kick.status),
                          userInfo: [NSLocalizedDescriptionKey: kick.output])
        }
    }

    static func restart() throws {
        stop()
        // Wait for the old agent to actually die before rebinding the
        // label. The old fixed 0.35s sleep raced a slow teardown
        // (recording cleanup, unmute, model unload can take longer):
        // bootstrapping/kickstarting against a still-dying instance —
        // or skipping the kickstart because isAgentRunning() still saw
        // the old pid — could leave the label with NO running agent at
        // all ("service stuck at stopping, model never loads"). Poll
        // briefly instead; if the old process somehow outlives the
        // deadline, proceed anyway — it received SIGTERM in stop() and
        // is on its way out.
        let deadline = Date().addingTimeInterval(5)
        while isAgentRunning() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        try installAndStart()
    }

    static func stop() {
        _ = runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        terminateAgentProcesses()
        try? FileManager.default.removeItem(at: launchAgentURL)
        writeStoppedState()
    }

    static func isAgentRunning() -> Bool {
        if let state = AgentRuntimeStateStore.read(),
           state.pid > 0,
           state.pid != getpid(),
           processIsAlive(pid: state.pid) {
            return true
        }
        return !agentProcessIDs().isEmpty
    }

    static func isAgentLoadedOrRunning() -> Bool {
        isAgentRunning() || runLaunchctl(["print", launchService]).status == 0
    }

    static func agentProcessIDs() -> [Int32] {
        let result = run("/usr/bin/pgrep",
                         ["-f", "\(agentExecutablePath()) \(AGENT_ARGUMENT)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != getpid() }
    }

    private static func writeLaunchAgentPlist() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let logPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SuperDictate-agent.launchd.log").path
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [agentExecutablePath(), AGENT_ARGUMENT],
            "RunAtLoad": true,
            // SuccessfulExit: false -- relaunch only after a crash (non-zero
            // exit), not after a clean exit(0). Plain `KeepAlive: true`
            // relaunches on ANY exit, including the user's own Quit menu
            // action (`quitClicked` -> `NSApp.terminate`), which made the
            // app immediately resurrect itself and blocked removing it from
            // /Applications. Verified on real hardware with an isolated,
            // unrelated LaunchAgent label: a clean exit runs once and stays
            // down; a crashing exit is relaunched (throttled) as before.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: launchAgentURL, options: [.atomic])
    }

    private static func terminateAgentProcesses() {
        for pid in agentProcessIDs() {
            kill(pid, SIGTERM)
        }
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func writeStoppedState() {
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: "stopped",
                              detail: "Dictation service is stopped.",
                              updatedAt: Date().timeIntervalSince1970,
                              pid: 0,
                              isReady: false,
                              isRecording: false,
                              isTranscribing: false,
                              speechModelReady: false,
                              missingPermissions: [],
                              hotkeyName: Settings.shared.configuredHotkey.name,
                              triggerMode: Settings.shared.triggerMode.rawValue)
        )
    }

    private static func runLaunchctl(_ arguments: [String]) -> ProcessRunResult {
        run("/bin/launchctl", arguments)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessRunResult(status: process.terminationStatus,
                                    output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessRunResult(status: 127, output: error.localizedDescription)
        }
    }
}

func privacySafeLogPath(_ path: String) -> String {
    privacySafeLogPath(URL(fileURLWithPath: path))
}

func privacySafeLogPath(_ url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "/" ? "<local path>" : name
}

func privacySafeBundlePath(_ path: String) -> String {
    switch path {
    case "/Applications/SuperDictate.app", "/tmp/SuperDictate-dev.app":
        return path
    default:
        return privacySafeLogPath(path)
    }
}

let PRIVATE_LOG_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)
let PRIVATE_HELPER_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)

func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
        throw currentPOSIXError()
    }

    try writeAllData(data, to: fd)
}

func validateSingleLinkRegularFileDescriptor(_ fd: Int32) throws {
    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw posixError(EFTYPE)
    }
    guard st.st_nlink == 1 else {
        throw posixError(EMLINK)
    }
}

func writeAllData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd,
                                       base.advanced(by: offset),
                                       rawBuffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

