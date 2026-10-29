// SuperDictate — account sync of the vocabulary with the SuperDictate sync
// server (docs/specs/vocabulary-hygiene-and-sync-spec.md §4; server in
// server/vocab-sync). Layers:
//   - VocabularySyncTokenStore: where the bearer token lives (Keychain in
//     the app, in memory in self-tests);
//   - VocabularySyncClient: the HTTP API (URLSession, system proxy for
//     internet hosts, direct for loopback/LAN — same policy as
//     OpenAICompatibleClient);
//   - VocabularySyncEngine: one serial push/pull pass over a store;
//   - VocabularySyncCoordinator: triggers (launch, 5 s after a local edit,
//     every 15 min, the manual button), backoff and notifications. Both
//     the agent and the Control Panel run one; a file lock keeps their
//     passes from overlapping.

import Foundation
import Security

// MARK: - Failures

enum VocabularySyncFailure: String, Error, Equatable, Sendable {
    case wrongPassword = "wrong-password"
    case tooManyAttempts = "too-many-attempts"
    case invalidCredentials = "invalid-credentials"
    /// A 401 on an authenticated request: the token is gone.
    case unauthorized
    case network
    case server
    case notSignedIn = "not-signed-in"
    case busy
    case keychain

    /// Failures worth backing off on (the next automatic trigger retries).
    var isTransient: Bool {
        switch self {
        case .network, .server, .busy: return true
        default: return false
        }
    }
}

// MARK: - Token storage

protocol VocabularySyncTokenStore: Sendable {
    func token(for account: String) -> String?
    func setToken(_ token: String, for account: String) throws
    func removeToken(for account: String)
}

/// Generic password, service `com.local.superdictate.vocab-sync`, account =
/// the e-mail (spec §4.1). The password itself is never stored.
struct KeychainVocabularySyncTokenStore: VocabularySyncTokenStore {
    let service: String

    init(service: String = VOCABULARY_SYNC_KEYCHAIN_SERVICE) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String, for account: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VocabularySyncFailure.keychain }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "SuperDictate vocabulary sync"
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VocabularySyncFailure.keychain }
    }

    func removeToken(for account: String) {
        guard !account.isEmpty else { return }
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Self-tests only: never touches the real Keychain entry.
final class InMemoryVocabularySyncTokenStore: VocabularySyncTokenStore, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    func token(for account: String) -> String? { lock.withLock { tokens[account] } }
    func setToken(_ token: String, for account: String) throws { lock.withLock { tokens[account] = token } }
    func removeToken(for account: String) { _ = lock.withLock { tokens.removeValue(forKey: account) } }
}

// MARK: - HTTP client

struct VocabularySyncWireEntry: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
    let origin: String
    let asrHint: Bool?
    let deleted: Bool
    let updatedAt: String
    var revision: Int? = nil

    enum CodingKeys: String, CodingKey {
        case source, replacement, origin, deleted, revision
        case asrHint = "asr_hint"
        case updatedAt = "updated_at"
    }
}

struct VocabularySyncResponse: Codable, Sendable {
    let revision: Int
    let entries: [VocabularySyncWireEntry]
}

struct VocabularySyncAuthResult: Codable, Sendable {
    let token: String
    let created: Bool
    let email: String
}

struct VocabularySyncClient: Sendable {
    let baseURL: URL
    var timeout: TimeInterval = 30

    private struct ClientInfo: Codable { let platform: String; let version: String }
    private struct AuthRequest: Codable { let email: String; let password: String; let client: ClientInfo }
    private struct PushRequest: Codable { let since: Int; let changes: [VocabularySyncWireEntry]; let client: ClientInfo }

    private static var clientInfo: ClientInfo { ClientInfo(platform: "macos", version: currentBundleVersion()) }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        if isLocalNetworkHost(baseURL.host) {
            // Same rule as OpenAICompatibleClient: a system proxy has no
            // route to loopback/LAN. The public sync server keeps the
            // system proxy policy (nil = honor the system configuration).
            config.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: config)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw VocabularySyncFailure.server }
            return (data, http.statusCode)
        } catch let failure as VocabularySyncFailure {
            throw failure
        } catch {
            throw VocabularySyncFailure.network
        }
    }

    private func jsonRequest(_ path: String, method: String, token: String?, body: Data?) -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func signIn(email: String, password: String) async throws -> VocabularySyncAuthResult {
        let body = try JSONEncoder().encode(AuthRequest(email: email, password: password, client: Self.clientInfo))
        let (data, status) = try await send(jsonRequest("v1/auth", method: "POST", token: nil, body: body))
        switch status {
        case 200..<300:
            guard let result = try? JSONDecoder().decode(VocabularySyncAuthResult.self, from: data) else {
                throw VocabularySyncFailure.server
            }
            return result
        case 401: throw VocabularySyncFailure.wrongPassword
        case 422: throw VocabularySyncFailure.invalidCredentials
        case 429: throw VocabularySyncFailure.tooManyAttempts
        default: throw VocabularySyncFailure.server
        }
    }

    func signOut(token: String) async {
        _ = try? await send(jsonRequest("v1/auth", method: "DELETE", token: token, body: nil))
    }

    func pull(token: String, since: Int) async throws -> VocabularySyncResponse {
        var components = URLComponents(url: endpoint("v1/vocabulary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "since", value: String(since))]
        guard let url = components?.url else { throw VocabularySyncFailure.server }
        var request = jsonRequest("v1/vocabulary", method: "GET", token: token, body: nil)
        request.url = url
        return try decodeSync(try await send(request))
    }

    func push(token: String, since: Int, changes: [VocabularySyncWireEntry]) async throws -> VocabularySyncResponse {
        let body = try JSONEncoder().encode(PushRequest(since: since, changes: changes, client: Self.clientInfo))
        return try decodeSync(try await send(jsonRequest("v1/vocabulary", method: "POST", token: token, body: body)))
    }

    private func decodeSync(_ result: (Data, Int)) throws -> VocabularySyncResponse {
        let (data, status) = result
        switch status {
        case 200..<300:
            guard let response = try? JSONDecoder().decode(VocabularySyncResponse.self, from: data) else {
                throw VocabularySyncFailure.server
            }
            return response
        case 401: throw VocabularySyncFailure.unauthorized
        default: throw VocabularySyncFailure.server
        }
    }
}

// MARK: - Engine

struct VocabularySyncPassSummary: Equatable, Sendable {
    var pushed = 0
    var applied = 0
}

/// One serial push/pull pass at a time (spec §4.2). Within a process the
/// actor queues callers; across the agent and the Control Panel an
/// optional lock file does.
actor VocabularySyncEngine {
    static let maxChangesPerPush = 1000
    /// The server's per-field limit (MAX_FIELD in server/vocab-sync/app.py).
    static let maxFieldLength = 200

    let settings: Settings
    let tokenStore: any VocabularySyncTokenStore
    private let lockFileURL: URL?
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(settings: Settings, tokenStore: any VocabularySyncTokenStore, lockFileURL: URL?) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.lockFileURL = lockFileURL
    }

    private var store: VocabularyStore { settings.vocabularyStore }
    private var client: VocabularySyncClient { VocabularySyncClient(baseURL: settings.vocabularySyncServerURL) }

    nonisolated var isSignedIn: Bool {
        settings.vocabularySyncEnabled && tokenStore.token(for: settings.vocabularySyncEmail) != nil
    }

    // MARK: Serialization

    private func acquire() async {
        if running {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            running = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Cross-process lock: the agent and the Control Panel may both run a
    /// pass; the cursors in UserDefaults must not interleave.
    private func acquireFileLock() async throws -> Int32? {
        guard let lockFileURL else { return nil }
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        for _ in 0..<150 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        close(fd)
        throw VocabularySyncFailure.busy
    }

    private func releaseFileLock(_ fd: Int32?) {
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: Account

    /// Signs in (the first sign-in with a new e-mail creates the account),
    /// stores the token and resets the cursors so the next pass is a full
    /// merge. Returns whether the account was created.
    func signIn(email: String, password: String) async throws -> Bool {
        await acquire()
        defer { release() }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = try await client.signIn(email: trimmed, password: password)
        let previous = settings.vocabularySyncEmail
        if !previous.isEmpty, previous != auth.email {
            tokenStore.removeToken(for: previous)
        }
        try tokenStore.setToken(auth.token, for: auth.email)
        settings.vocabularySyncEmail = auth.email
        settings.vocabularySyncEnabled = true
        settings.vocabularySyncLastServerRevision = 0
        settings.vocabularySyncLastPushedLocalStamp = ""
        settings.vocabularySyncLastSyncAt = nil
        settings.vocabularySyncLastError = nil
        log("vocabulary sync: signed in as \(auth.email)\(auth.created ? " (new account)" : "")")
        return auth.created
    }

    func signOut() async {
        await acquire()
        defer { release() }
        let email = settings.vocabularySyncEmail
        if let token = tokenStore.token(for: email) {
            await client.signOut(token: token)
        }
        tokenStore.removeToken(for: email)
        settings.vocabularySyncEnabled = false
        settings.vocabularySyncLastServerRevision = 0
        settings.vocabularySyncLastPushedLocalStamp = ""
        settings.vocabularySyncLastSyncAt = nil
        settings.vocabularySyncLastError = nil
        log("vocabulary sync: signed out")
    }

    // MARK: Pass

    func runPass() async throws -> VocabularySyncPassSummary {
        await acquire()
        defer { release() }
        let lock = try await acquireFileLock()
        defer { releaseFileLock(lock) }
        settings.refreshFromDisk()

        let email = settings.vocabularySyncEmail
        guard settings.vocabularySyncEnabled, !email.isEmpty,
              let token = tokenStore.token(for: email) else {
            throw VocabularySyncFailure.notSignedIn
        }
        do {
            let summary = try await pass(token: token)
            settings.vocabularySyncLastSyncAt = Date()
            settings.vocabularySyncLastError = nil
            return summary
        } catch let failure as VocabularySyncFailure {
            if failure == .unauthorized {
                // Spec §4.2: a 401 drops the token; the UI asks to sign in again.
                tokenStore.removeToken(for: email)
                log("vocabulary sync: the server rejected the token (401); signed out locally")
            } else {
                log("vocabulary sync: pass failed (\(failure.rawValue))")
            }
            settings.vocabularySyncLastError = failure.rawValue
            throw failure
        } catch {
            log("vocabulary sync: pass failed (\(error))")
            settings.vocabularySyncLastError = VocabularySyncFailure.server.rawValue
            throw VocabularySyncFailure.server
        }
    }

    private func pass(token: String) async throws -> VocabularySyncPassSummary {
        let passStart = VocabularyStore.timestamp()
        let cursorStamp = settings.vocabularySyncLastPushedLocalStamp
        let local = store.syncChanges(since: cursorStamp)

        var changes: [VocabularySyncWireEntry] = []
        var newestPushed = ""
        for record in local.entries {
            guard let source = Self.wireField(record.source),
                  let replacement = Self.wireField(record.replacement), !record.updatedAt.isEmpty else {
                log("vocabulary sync: entry id=\(record.id) not pushed (empty, too long or control characters)")
                continue
            }
            changes.append(VocabularySyncWireEntry(source: source, replacement: replacement,
                                                   origin: record.origin.rawValue, asrHint: record.asrHint,
                                                   deleted: false, updatedAt: record.updatedAt))
            newestPushed = max(newestPushed, record.updatedAt)
        }
        for tombstone in local.tombstones {
            guard let source = Self.wireField(tombstone.source), !tombstone.deletedAt.isEmpty else { continue }
            changes.append(VocabularySyncWireEntry(source: source, replacement: "", origin: VocabularyOrigin.manual.rawValue,
                                                   asrHint: nil, deleted: true, updatedAt: tombstone.deletedAt))
            newestPushed = max(newestPushed, tombstone.deletedAt)
        }

        var summary = VocabularySyncPassSummary()
        var since = settings.vocabularySyncLastServerRevision
        if changes.isEmpty {
            let response = try await client.pull(token: token, since: since)
            summary.applied += try apply(response)
            since = response.revision
            settings.vocabularySyncLastServerRevision = since
        } else {
            var start = 0
            while start < changes.count {
                let batch = Array(changes[start..<min(start + Self.maxChangesPerPush, changes.count)])
                let response = try await client.push(token: token, since: since, changes: batch)
                summary.applied += try apply(response)
                summary.pushed += batch.count
                since = response.revision
                settings.vocabularySyncLastServerRevision = since
                start += batch.count
            }
            // Never ahead of this device's own clock: a remote stamp from a
            // device whose clock runs fast must not hide later local edits.
            settings.vocabularySyncLastPushedLocalStamp = min(newestPushed, passStart)
        }
        log("vocabulary sync: pass done — pushed \(summary.pushed), applied \(summary.applied), revision \(since)")
        return summary
    }

    private func apply(_ response: VocabularySyncResponse) throws -> Int {
        let entries = response.entries.map { entry in
            VocabularyStore.RemoteEntry(source: entry.source, replacement: entry.replacement,
                                        origin: VocabularyOrigin(rawValue: entry.origin) ?? .manual,
                                        asrHint: entry.asrHint, deleted: entry.deleted, updatedAt: entry.updatedAt)
        }
        do {
            return try store.applyRemote(entries)
        } catch {
            log("vocabulary sync: applying server entries failed: \(error)")
            throw VocabularySyncFailure.busy
        }
    }

    /// What the server accepts (its `_clean`): NFC, trimmed, non-empty, at
    /// most 200 characters, no control characters.
    static func wireField(_ text: String) -> String? {
        let cleaned = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.unicodeScalars.count <= maxFieldLength,
              !cleaned.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return cleaned
    }
}

// MARK: - Coordinator

/// App-side triggers and status around one engine. The agent runs the
/// automatic triggers; the Control Panel uses it for sign-in, sign-out and
/// the manual button.
@MainActor
final class VocabularySyncCoordinator {
    enum Role { case agent, controlPanel }

    static let debounceSeconds: TimeInterval = 5
    static let periodicSeconds: TimeInterval = 15 * 60
    static let maxBackoffSeconds: TimeInterval = 15 * 60

    let engine: VocabularySyncEngine
    private let settings: Settings
    private let role: Role
    private var debounceTask: Task<Void, Never>?
    private var notifyTask: Task<Void, Never>?
    private var periodicTimer: Timer?
    private var consecutiveFailures = 0
    private var nextAutomaticAttempt = Date.distantPast
    private(set) var isSyncing = false
    private var started = false

    init(settings: Settings, role: Role) {
        self.settings = settings
        self.role = role
        let lockURL = (try? superDictateApplicationSupportDirectory())?
            .appendingPathComponent("vocab-sync.lock", isDirectory: false)
        self.engine = VocabularySyncEngine(settings: settings, tokenStore: KeychainVocabularySyncTokenStore(),
                                           lockFileURL: lockURL)
    }

    var isSignedIn: Bool { engine.isSignedIn }

    func start() {
        guard !started else { return }
        started = true
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        settings.vocabularyStore.onLocalChange = { [weak self] in
            Task { @MainActor in self?.localChangeHappened() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: VOCABULARY_CHANGED_NOTIFICATION, object: nil, queue: .main
        ) { [weak self] notification in
            let sender = notification.userInfo?["pid"] as? Int
            let reason = notification.userInfo?["reason"] as? String
            guard sender != pid, reason == "local" else { return }
            MainActor.assumeIsolated { self?.scheduleDebouncedSync() }
        }
        guard role == .agent else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.periodicSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in _ = await self?.sync(trigger: "periodic", manual: false) }
        }
        Task { _ = await sync(trigger: "launch", manual: false) }
    }

    /// Coalesced: an import upserts row by row, and each write calls back.
    private func localChangeHappened() {
        guard notifyTask == nil else { return }
        notifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.notifyTask = nil
            DistributedNotificationCenter.default().postNotificationName(
                VOCABULARY_CHANGED_NOTIFICATION, object: nil,
                userInfo: ["pid": Int(ProcessInfo.processInfo.processIdentifier), "reason": "local"],
                deliverImmediately: true)
            self.scheduleDebouncedSync()
        }
    }

    /// Spec §4.2 trigger: 5 s after any local vocabulary change. Only the
    /// agent pushes automatically; a Control Panel edit reaches the agent
    /// through the distributed notification posted above.
    private func scheduleDebouncedSync() {
        guard role == .agent else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await self?.sync(trigger: "local change", manual: false)
        }
    }

    /// One pass. Automatic triggers are skipped while signed out or inside
    /// the backoff window after a transient failure; the manual button
    /// always tries. Returns the failure, nil on success.
    @discardableResult
    func sync(trigger: String, manual: Bool) async -> VocabularySyncFailure? {
        guard engine.isSignedIn else { return manual ? .notSignedIn : nil }
        if !manual, Date() < nextAutomaticAttempt { return nil }
        isSyncing = true
        postStatusChanged()
        defer {
            isSyncing = false
            postStatusChanged()
        }
        do {
            let summary = try await engine.runPass()
            consecutiveFailures = 0
            nextAutomaticAttempt = .distantPast
            if summary.applied > 0 {
                DistributedNotificationCenter.default().postNotificationName(
                    VOCABULARY_CHANGED_NOTIFICATION, object: nil,
                    userInfo: ["pid": Int(ProcessInfo.processInfo.processIdentifier), "reason": "sync"],
                    deliverImmediately: true)
            }
            log("vocabulary sync: \(trigger) pass ok")
            return nil
        } catch let failure as VocabularySyncFailure {
            if failure.isTransient {
                consecutiveFailures += 1
                let delay = min(30 * pow(2, Double(consecutiveFailures - 1)), Self.maxBackoffSeconds)
                nextAutomaticAttempt = Date().addingTimeInterval(delay)
            }
            return failure
        } catch {
            return .server
        }
    }

    func signIn(email: String, password: String) async -> Result<Bool, VocabularySyncFailure> {
        do {
            let created = try await engine.signIn(email: email, password: password)
            postStatusChanged()
            consecutiveFailures = 0
            nextAutomaticAttempt = .distantPast
            _ = await sync(trigger: "sign-in", manual: true)
            return .success(created)
        } catch let failure as VocabularySyncFailure {
            return .failure(failure)
        } catch {
            return .failure(.server)
        }
    }

    func signOut() async {
        await engine.signOut()
        postStatusChanged()
    }

    private func postStatusChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            VOCABULARY_SYNC_STATUS_NOTIFICATION, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
