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

// MARK: - Update check
//
// Hits the GitHub Releases API once at boot + every 6 h. Users can
// also force the same lookup from the menu. When a newer version is
// found AND it's not in the user's skipped list, a submenu inserts
// itself at the top of the menu: What's new / Update now / Remind me
// in 24 hours / Skip vX.Y.Z.

struct GitHubRelease: Sendable, Equatable {
    let tagName: String      // 'v0.1.7'
    let version: String      // '0.1.7' (no v)
    let body: String         // release notes, raw markdown
    let htmlURL: String
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let body: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
    }
}

/// Why an update check failed. Carried as a value (not a string) so
/// the manual-check alert can explain the actual problem instead of
/// blaming the network for everything; automatic ticks ignore it and
/// stay silent.
enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// The HTTPS request itself failed (offline, DNS, timeout).
    case network
    /// GitHub answered with a non-2xx status (403 → likely API rate
    /// limiting).
    case httpStatus(Int)
    /// A response arrived but was oversized, malformed, or carried an
    /// unusable tag.
    case unexpectedResponse
}

/// User-facing explanation for a failed *manual* update check. Only
/// the alert behind "Check for Updates…" uses this — automatic and
/// settings-toggle checks never alert.
func manualUpdateCheckFailureText(_ failure: UpdateCheckFailure) -> String {
    switch failure {
    case .network:
        return "SuperDictate Next couldn't reach GitHub. Check your internet connection and try again."
    case .httpStatus(403):
        return "GitHub declined the update check (HTTP 403). This is usually temporary rate limiting — try again in a few minutes."
    case .httpStatus(let code):
        return "GitHub returned an error (HTTP \(code)). Try again later."
    case .unexpectedResponse:
        return "GitHub returned a response SuperDictate couldn't read. Try again later, or check the releases page on GitHub directly."
    }
}

enum UpdateCheck {
    private static let githubReleaseURLPathPrefix = "/shohart/SuperDictate-Next/releases/tag/"
    static let maxReleaseResponseBytes = 512 * 1024

    static func fetchLatest() async -> Result<GitHubRelease, UpdateCheckFailure> {
        var req = URLRequest(url: GITHUB_LATEST_RELEASE_URL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The privacy docs promise exactly this fixed token — no
        // version, device, or user identifiers. Must stay in sync with
        // docs/privacy/network-calls.json.
        req.setValue("superdictate-update-check", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: req)
            return parseLatest(data: data, response: response)
        } catch {
            return .failure(.network)
        }
    }

    static func parseLatest(data: Data, response: URLResponse) -> Result<GitHubRelease, UpdateCheckFailure> {
        guard let http = response as? HTTPURLResponse else {
            return .failure(.unexpectedResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard data.count <= maxReleaseResponseBytes,
              let payload = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: data) else {
            return .failure(.unexpectedResponse)
        }

        let tag = payload.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = normalizedReleaseVersion(from: tag) else {
            return .failure(.unexpectedResponse)
        }

        return .success(GitHubRelease(
            tagName: tag,
            version: version,
            body: payload.body ?? "",
            htmlURL: sanitizedReleaseURL(payload.htmlURL, expectedTag: tag)
        ))
    }

    static func normalizedReleaseVersion(from tag: String) -> String? {
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = version.first, first == "v" || first == "V" {
            version.removeFirst()
        }

        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  part == "0" || !part.hasPrefix("0"),
                  Int(part) != nil else {
                return nil
            }
        }
        return parts.joined(separator: ".")
    }

    static func sanitizedReleaseURL(_ value: String?, expectedTag: String) -> String {
        guard let value else { return GITHUB_RELEASES_PAGE.absoluteString }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host == "github.com",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "\(githubReleaseURLPathPrefix)\(expectedTag)" else {
            return GITHUB_RELEASES_PAGE.absoluteString
        }
        return trimmed
    }
}

struct SuperDictateUpdateManifest: Decodable, Equatable, Sendable {
    let version: String
    let sha256: String
}

struct PreparedSuperDictateUpdate: Sendable {
    let version: String
    let workDirectory: URL
    let stagedAppURL: URL
}

enum SuperDictateUpdateInstallerError: LocalizedError, Equatable, Sendable {
    case network
    case httpStatus(Int)
    case invalidManifest
    case manifestVersionMismatch(expected: String, actual: String)
    case archiveTooLarge
    case checksumMismatch
    case extractionFailed(String)
    case invalidBundle(String)
    case appNotWritable

    var errorDescription: String? { message(language: .russian) }

    func message(language: InterfaceLanguage) -> String {
        if language == .english {
            switch self {
            case .network:
                return "The update could not be downloaded. Check your internet connection."
            case .httpStatus(let code):
                return "The update server returned HTTP \(code)."
            case .invalidManifest:
                return "The update manifest is damaged or has an unknown format."
            case .manifestVersionMismatch(let expected, let actual):
                return "GitHub reports version \(expected), but the manifest reports \(actual). The update was stopped."
            case .archiveTooLarge:
                return "The update archive exceeds the allowed size."
            case .checksumMismatch:
                return "The archive checksum did not match. The application was not replaced."
            case .extractionFailed(let detail):
                return "The update could not be extracted: \(detail)"
            case .invalidBundle(let detail):
                return "The new application failed verification: \(detail)"
            case .appNotWritable:
                return "SuperDictate Next cannot replace the application in Applications. Run the regular installer once."
            }
        }
        switch self {
        case .network:
            return "Не удалось скачать обновление. Проверьте подключение к интернету."
        case .httpStatus(let code):
            return "Сервер обновлений вернул ошибку HTTP \(code)."
        case .invalidManifest:
            return "Манифест обновления повреждён или имеет неизвестный формат."
        case .manifestVersionMismatch(let expected, let actual):
            return "GitHub сообщает о версии \(expected), а манифест — о версии \(actual). Обновление остановлено."
        case .archiveTooLarge:
            return "Архив обновления превышает допустимый размер."
        case .checksumMismatch:
            return "Контрольная сумма архива не совпала. Приложение не будет заменено."
        case .extractionFailed(let detail):
            return "Не удалось распаковать обновление: \(detail)"
        case .invalidBundle(let detail):
            return "Проверка нового приложения не пройдена: \(detail)"
        case .appNotWritable:
            return "SuperDictate Next не может заменить приложение в папке Applications. Запустите обычный установщик один раз."
        }
    }
}

enum SuperDictateUpdateInstaller {
    private static let manifestMaxBytes = 16 * 1024

    static func fetchManifest(expectedVersion: String) async throws -> SuperDictateUpdateManifest {
        var request = URLRequest(url: GITHUB_UPDATE_MANIFEST_URL)
        request.setValue("superdictate-in-app-update", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 15
        let (data, response) = try await fetch(request: request, maxBytes: manifestMaxBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw SuperDictateUpdateInstallerError.httpStatus(response.statusCode)
        }
        return try parseManifest(data, expectedVersion: expectedVersion)
    }

    static func parseManifest(_ data: Data,
                              expectedVersion: String) throws -> SuperDictateUpdateManifest {
        guard let manifest = try? JSONDecoder().decode(SuperDictateUpdateManifest.self, from: data),
              UpdateCheck.normalizedReleaseVersion(from: manifest.version) == manifest.version,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw SuperDictateUpdateInstallerError.invalidManifest
        }
        guard manifest.version == expectedVersion else {
            throw SuperDictateUpdateInstallerError.manifestVersionMismatch(
                expected: expectedVersion,
                actual: manifest.version
            )
        }
        return manifest
    }

    static func prepare(manifest: SuperDictateUpdateManifest) async throws -> PreparedSuperDictateUpdate {
        guard appCanBeReplaced(at: Bundle.main.bundleURL) else {
            throw SuperDictateUpdateInstallerError.appNotWritable
        }

        let archiveURL = URL(string: "https://github.com/shohart/SuperDictate-Next/releases/download/v\(manifest.version)/SuperDictate.zip")!
        var request = URLRequest(url: archiveURL)
        request.setValue("superdictate-in-app-update", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (archiveData, response) = try await fetch(request: request,
                                                      maxBytes: UPDATE_ARCHIVE_MAX_BYTES)
        guard (200..<300).contains(response.statusCode) else {
            throw SuperDictateUpdateInstallerError.httpStatus(response.statusCode)
        }

        var hasher = SHA256()
        hasher.update(data: archiveData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw SuperDictateUpdateInstallerError.checksumMismatch
        }

        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SuperDictate-update-\(UUID().uuidString)", isDirectory: true)
        let archiveFile = workDirectory.appendingPathComponent("SuperDictate.zip")
        let extractedDirectory = workDirectory.appendingPathComponent("release", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractedDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try archiveData.write(to: archiveFile, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.extractionFailed(error.localizedDescription)
        }

        let extraction = await Task.detached(priority: .userInitiated) {
            SuperDictateAgentService.run("/usr/bin/ditto",
                                         ["-x", "-k", archiveFile.path, extractedDirectory.path])
        }.value
        guard extraction.status == 0 else {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.extractionFailed(extraction.output)
        }

        let stagedAppURL = extractedDirectory.appendingPathComponent("SuperDictate.app",
                                                                      isDirectory: true)
        do {
            try validateApp(at: stagedAppURL, expectedVersion: manifest.version)
        } catch let error as SuperDictateUpdateInstallerError {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.invalidBundle(error.localizedDescription)
        }
        return PreparedSuperDictateUpdate(version: manifest.version,
                                          workDirectory: workDirectory,
                                          stagedAppURL: stagedAppURL)
    }

    static func appCanBeReplaced(at appURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard appURL.pathExtension == "app",
              fileManager.fileExists(atPath: appURL.path) else { return false }
        return fileManager.isWritableFile(atPath: appURL.path)
            && fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    static func validateApp(at appURL: URL, expectedVersion: String) throws {
        let fileManager = FileManager.default
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/SuperDictate")
        guard appURL.lastPathComponent == "SuperDictate.app",
              fileManager.fileExists(atPath: infoURL.path),
              fileManager.isExecutableFile(atPath: executableURL.path),
              let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData,
                                                                     format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.local.superdictate",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw SuperDictateUpdateInstallerError.invalidBundle("неверный идентификатор или версия")
        }

        if let enumerator = fileManager.enumerator(at: appURL,
                                                   includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                   options: []) {
            for case let itemURL as URL in enumerator {
                if (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw SuperDictateUpdateInstallerError.invalidBundle("архив содержит символическую ссылку")
                }
            }
        }

        let signature = SuperDictateAgentService.run("/usr/bin/codesign",
                                                      ["--verify", "--deep", "--strict", appURL.path])
        guard signature.status == 0 else {
            throw SuperDictateUpdateInstallerError.invalidBundle("codesign: \(signature.output)")
        }
    }

    private static func fetch(request: URLRequest,
                              maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SuperDictateUpdateInstallerError.network
            }
            guard data.count <= maxBytes else {
                throw SuperDictateUpdateInstallerError.archiveTooLarge
            }
            return (data, http)
        } catch let error as SuperDictateUpdateInstallerError {
            throw error
        } catch {
            throw SuperDictateUpdateInstallerError.network
        }
    }
}

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func sanitizedEnvironmentValue(_ value: String?) -> String? {
    guard let value,
          !value.isEmpty,
          !value.utf8.contains(0),
          !value.contains(where: { $0.isNewline }) else {
        return nil
    }
    return value
}

private func trustedProcessEnvironment(path: String,
                                       current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [
        "HOME": NSHomeDirectory(),
        "PATH": path,
        "SHELL": "/bin/zsh",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": sanitizedEnvironmentValue(current["LANG"]) ?? "en_US.UTF-8",
    ]

    if let user = sanitizedEnvironmentValue(current["USER"]) {
        env["USER"] = user
    }
    if let logname = sanitizedEnvironmentValue(current["LOGNAME"]) ?? env["USER"] {
        env["LOGNAME"] = logname
    }
    if let encoding = sanitizedEnvironmentValue(current["__CF_USER_TEXT_ENCODING"]) {
        env["__CF_USER_TEXT_ENCODING"] = encoding
    }

    return env
}

func systemToolProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/usr/bin:/bin:/usr/sbin:/sbin", current: current)
}

func updateProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                              current: current)
}

func updateHelperScript(pid: pid_t,
                        brewPath: String,
                        targetVersion: String,
                        statePath: String,
                        appPath: String = INSTALLED_APP_BUNDLE_PATH,
                        releasesPageURL: String = GITHUB_RELEASES_PAGE.absoluteString) -> String {
    #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    BREW=\#(shellSingleQuoted(brewPath))
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    RELEASES_PAGE=\#(shellSingleQuoted(releasesPageURL))
    PARAKEY_PID=\#(pid)
    CASK_TAP=\#(shellSingleQuoted(HOMEBREW_CASK_TAP))
    CASK_TOKEN=\#(shellSingleQuoted(HOMEBREW_CASK_TOKEN))
    CASK_INSTALLED_TOKEN=\#(shellSingleQuoted(HOMEBREW_CASK_INSTALLED_TOKEN))
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    APP_DIR="$(/usr/bin/dirname "$APP_PATH")"

    cleanup() {
        if [ -n "${SCRIPT_PATH:-}" ]; then
            /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp
        log "$message"
        [ -n "$STATE_PATH" ] || return 0
        tmp="${STATE_PATH}.$$"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    fail() {
        state "failed" "$*"
        /usr/bin/open "$RELEASES_PAGE"
        exit 1
    }

    app_version() {
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true
    }

    version_at_least() {
        /usr/bin/awk -v actual="$1" -v target="$2" '
            BEGIN {
                actual_count = split(actual, actual_parts, ".")
                target_count = split(target, target_parts, ".")
                for (i = 1; i <= 4; i++) {
                    actual_part = i <= actual_count ? actual_parts[i] : "0"
                    target_part = i <= target_count ? target_parts[i] : "0"
                    sub(/[^0-9].*$/, "", actual_part)
                    sub(/[^0-9].*$/, "", target_part)
                    actual_number = actual_part == "" ? 0 : actual_part + 0
                    target_number = target_part == "" ? 0 : target_part + 0
                    if (actual_number > target_number) { exit 0 }
                    if (actual_number < target_number) { exit 1 }
                }
                exit 0
            }'
    }

    run_brew() {
        log "Running: $BREW $*"
        "$BREW" "$@"
    }

    wait_for_parakey_exit() {
        for _ in {1..60}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        log "Parakey was still running after 30s; sending TERM before updating."
        kill -TERM "$PARAKEY_PID" 2>/dev/null || true
        for _ in {1..20}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        fail "Parakey did not quit, so the app bundle was not touched."
    }

    installed_target_version() {
        local installed
        installed="$(app_version)"
        log "Installed app version: ${installed:-unknown}"
        [ -n "$installed" ] && version_at_least "$installed" "$TARGET_VERSION"
    }

    {
        echo "[$(timestamp)] Parakey update starting"
        echo "Target version: $TARGET_VERSION"
        echo "Current installed version: $(app_version)"
        echo "Brew: $BREW"
        echo "Cask tap: $CASK_TAP"
        echo "Cask: $CASK_TOKEN"
        echo "Installed cask name: $CASK_INSTALLED_TOKEN"
        echo "App: $APP_PATH"
    }

    state "preparing" "Preparing Homebrew for Parakey v$TARGET_VERSION..."

    if ! run_brew tap "$CASK_TAP"; then
        fail "brew tap failed; leaving the existing app in place."
    fi

    state "checking" "Checking Homebrew metadata..."
    if ! run_brew update --force; then
        fail "brew update failed; leaving the existing app in place."
    fi

    state "downloading" "Downloading Parakey v$TARGET_VERSION..."
    if ! run_brew fetch --cask --force "$CASK_TOKEN"; then
        fail "brew cask fetch failed; leaving the existing app in place."
    fi

    state "installing" "Installing Parakey v$TARGET_VERSION..."
    wait_for_parakey_exit

    if ! run_brew upgrade --cask --force --appdir="$APP_DIR" "$CASK_TOKEN"; then
        fail "brew cask upgrade failed; leaving the existing app in place."
    fi

    state "verifying" "Verifying the installed app..."
    if ! installed_target_version; then
        log "brew upgrade completed without installing v$TARGET_VERSION; forcing qualified cask reinstall."
        state "installing" "Reinstalling Parakey v$TARGET_VERSION..."
        if ! run_brew update --force; then
            fail "brew update failed before reinstall; leaving the existing app in place."
        fi
        if ! run_brew reinstall --cask --force --appdir="$APP_DIR" "$CASK_TOKEN"; then
            fail "brew cask reinstall failed; leaving the existing app in place."
        fi
    fi

    if ! installed_target_version; then
        fail "Expected Parakey v$TARGET_VERSION or newer after update, but the installed app is still $(app_version)."
    fi

    state "relaunching" "Update complete. Reopening Parakey..."
    sleep 2
    /usr/bin/open "$APP_PATH"
    state "complete" "Parakey v$TARGET_VERSION is installed."
    """#
}

func superDictateDirectUpdateHelperScript(pid: pid_t,
                                           targetVersion: String,
                                           statePath: String,
                                           stagedAppPath: String,
                                           workDirectory: String,
                                           backupAppPath: String,
                                           appPath: String,
                                           language: InterfaceLanguage,
                                           relaunch: Bool = true) -> String {
    let preparing = localizedText("Подготавливаю замену приложения…",
                                  "Preparing to replace the application…",
                                  language: language)
    let installing = localizedText("Устанавливаю SuperDictate Next v\(targetVersion)…",
                                    "Installing SuperDictate Next v\(targetVersion)…",
                                    language: language)
    let verifying = localizedText("Проверяю установленную версию…",
                                   "Verifying the installed version…",
                                   language: language)
    let relaunching = localizedText("Обновление готово. Запускаю SuperDictate Next…",
                                    "Update complete. Reopening SuperDictate Next…",
                                    language: language)
    let complete = localizedText("SuperDictate Next v\(targetVersion) установлена.",
                                  "SuperDictate Next v\(targetVersion) is installed.",
                                  language: language)
    let failed = localizedText("Обновление не установлено. Предыдущая версия восстановлена.",
                                "The update was not installed. The previous version was restored.",
                                language: language)

    return #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    PANEL_PID=\#(pid)
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    STAGED_APP=\#(shellSingleQuoted(stagedAppPath))
    WORK_DIR=\#(shellSingleQuoted(workDirectory))
    BACKUP_APP=\#(shellSingleQuoted(backupAppPath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    SHOULD_RELAUNCH=\#(relaunch ? "1" : "0")
    APP_PARENT="$(/usr/bin/dirname "$APP_PATH")"
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    SERVICE="gui/$(/usr/bin/id -u)/\#(AGENT_LABEL)"

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp="${STATE_PATH}.$$"
        log "$message"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    cleanup() {
        /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
        /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
    }
    trap cleanup EXIT

    wait_for_panel_exit() {
        for _ in {1..40}; do
            if ! /bin/kill -0 "$PANEL_PID" 2>/dev/null; then
                return 0
            fi
            /bin/sleep 0.25
        done
        /bin/kill -TERM "$PANEL_PID" 2>/dev/null || true
        /bin/sleep 1
        ! /bin/kill -0 "$PANEL_PID" 2>/dev/null
    }

    verify_app() {
        [ -x "$APP_PATH/Contents/MacOS/SuperDictate" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" = "com.local.superdictate" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" = "$TARGET_VERSION" ] || return 1
        /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    }

    rollback() {
        log "Rolling back the application bundle."
        if [ -d "$BACKUP_APP" ]; then
            /bin/rm -rf "$APP_PATH" 2>/dev/null || true
            /bin/mv "$BACKUP_APP" "$APP_PATH" 2>/dev/null || true
        fi
        state "failed" \#(shellSingleQuoted(failed))
        if [ "$SHOULD_RELAUNCH" = "1" ] && [ -d "$APP_PATH" ]; then
            /usr/bin/open "$APP_PATH" 2>/dev/null || true
        fi
        exit 1
    }

    state "preparing" \#(shellSingleQuoted(preparing))
    [ -d "$STAGED_APP" ] || rollback
    [ -d "$APP_PATH" ] || rollback
    [ ! -e "$BACKUP_APP" ] || rollback
    [ -w "$APP_PATH" ] && [ -w "$APP_PARENT" ] || rollback
    wait_for_panel_exit || rollback

    /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    /usr/bin/pkill -f "$APP_PATH/Contents/MacOS/SuperDictate --agent" >/dev/null 2>&1 || true

    state "installing" \#(shellSingleQuoted(installing))
    /bin/mv "$APP_PATH" "$BACKUP_APP" || rollback
    /usr/bin/ditto "$STAGED_APP" "$APP_PATH" || rollback

    state "verifying" \#(shellSingleQuoted(verifying))
    verify_app || rollback

    /bin/rm -rf "$BACKUP_APP" || true
    state "relaunching" \#(shellSingleQuoted(relaunching))
    if [ "$SHOULD_RELAUNCH" = "1" ]; then
        /usr/bin/open "$APP_PATH" || rollback
    fi
    /bin/sleep 2
    state "complete" \#(shellSingleQuoted(complete))
    """#
}

func writePrivateUpdateHelperScript(_ script: String,
                                            directory: String = NSTemporaryDirectory(),
                                            fileName: String? = nil) throws -> String {
    guard !directory.isEmpty else { throw posixError(EINVAL) }
    let leafName = fileName ?? "parakey-update-\(UUID().uuidString).sh"
    guard !leafName.isEmpty,
          (leafName as NSString).lastPathComponent == leafName else {
        throw posixError(EINVAL)
    }

    let path = (directory as NSString).appendingPathComponent(leafName)
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(path, flags, PRIVATE_HELPER_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    var closed = false
    var removeOnFailure = true
    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_HELPER_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        try writeAllData(Data(script.utf8), to: fd)
        try validateSingleLinkRegularFileDescriptor(fd)

        let closeStatus = Darwin.close(fd)
        closed = true
        guard closeStatus == 0 else { throw currentPOSIXError() }

        removeOnFailure = false
        return path
    } catch {
        if !closed { _ = Darwin.close(fd) }
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

struct PrivateOutputFile {
    let path: String
    let handle: FileHandle
}

func openPrivateUpdateHelperLog(preferredPath: String = UPDATE_HELPER_LOG_PATH,
                                        fallbackDirectory: String = NSTemporaryDirectory()) throws -> PrivateOutputFile {
    do {
        let fd = try openPrivateOutputFileDescriptor(atPath: preferredPath,
                                                     exclusive: false,
                                                     removeOnFailure: false)
        return PrivateOutputFile(path: preferredPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    } catch {
        let fallbackPath = (fallbackDirectory as NSString)
            .appendingPathComponent("parakey-update-\(UUID().uuidString).log")
        let fd = try openPrivateOutputFileDescriptor(atPath: fallbackPath,
                                                     exclusive: true,
                                                     removeOnFailure: true)
        return PrivateOutputFile(path: fallbackPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}

func createPrivateUpdateProgressStateFile(directory: String = NSTemporaryDirectory()) throws -> String {
    let path = (directory as NSString)
        .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).state")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: true,
                                                 removeOnFailure: true)
    do {
        try writeAllData(Data("starting\tStarting update...\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
        return path
    } catch {
        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
        throw error
    }
}

func writePrivateUpdateProgressState(phase: String,
                                             message: String,
                                             to path: String) throws {
    let safePhase = phase.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let safeMessage = message.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: false,
                                                 removeOnFailure: false)
    do {
        try writeAllData(Data("\(safePhase)\t\(safeMessage)\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
    } catch {
        _ = Darwin.close(fd)
        throw error
    }
}

private func openPrivateOutputFileDescriptor(atPath path: String,
                                             exclusive: Bool,
                                             removeOnFailure: Bool) throws -> Int32 {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

    var flags = O_WRONLY | O_CREAT | O_NOFOLLOW
    if exclusive { flags |= O_EXCL }

    let fd = Darwin.open(path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        guard Darwin.ftruncate(fd, 0) == 0 else {
            throw currentPOSIXError()
        }
        return fd
    } catch {
        _ = Darwin.close(fd)
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

