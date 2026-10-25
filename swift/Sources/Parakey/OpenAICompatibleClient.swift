// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import Darwin
import Foundation

// MARK: - OpenAI-compatible chat completions client
//
// One client, two callers: the bundled SuperDictateLLMHost helper
// (LLMHostProcess.swift, baseURL = http://127.0.0.1:<port>) and a
// user-supplied custom OpenAI-compatible baseURL (Settings). Both speak the
// exact same POST /v1/chat/completions JSON shape, so there is no
// bundled-vs-custom branch anywhere in this file — see the atom-derived
// architecture note in LLMHostProcess.swift for why that unification is the
// point of building the bundled helper as a real chat-completions server
// instead of a bespoke IPC protocol.

/// Why a chat-completion request failed. Carried as a value, mirroring
/// UpdateCheckFailure (UpdateCheck.swift) — the caller decides how loud to
/// be (LLM postprocessing failure must never block or corrupt the user's
/// dictated text; see RecordingLifecycle.swift's fallback policy).
enum LLMPostprocessError: Error, Equatable, Sendable {
    /// The HTTP request itself failed (offline, DNS, timeout, connection
    /// refused — the common case right after spawning the bundled helper
    /// before it has finished loading the model).
    case network
    /// The server answered with a non-2xx status.
    case httpStatus(Int)
    /// A response arrived but wasn't a well-formed chat-completion payload.
    case unexpectedResponse
    /// The response parsed but the assistant message content was empty.
    case emptyCompletion
    /// The request URL itself was malformed (bad custom baseURL).
    case invalidBaseURL
}

/// Whether `host` lives on this machine or its own LAN: loopback, the IPv4
/// private ranges (10/8, 172.16/12, 192.168/16), link-local and CGNAT
/// addresses, IPv6 loopback/ULA/link-local, and mDNS `.local` names.
/// Public names are deliberately not resolved: DNS may itself be reachable
/// only through the proxy, and a lookup per request would slow the
/// dictation path. A local LLM server is configured with a literal LAN
/// address or a `.local` name in practice.
///
/// Used by the `connectionProxyDictionary` override at the call site:
/// loopback and LAN endpoints must never go through the system proxy.
func isLocalNetworkHost(_ host: String?) -> Bool {
    guard let rawHost = host else { return false }
    var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !host.isEmpty else { return false }
    if host.hasPrefix("[") && host.hasSuffix("]") {
        host = String(host.dropFirst().dropLast())
    }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if host == "localhost" || host == "0.0.0.0"
        || host == "::1" || host == "::" { return true }
    if host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }

    if host.contains(":") {
        // An IPv4-mapped literal (::ffff:192.168.1.5) is a LAN endpoint.
        if host.hasPrefix("::ffff:") {
            return isLocalNetworkHost(String(host.dropFirst(7)))
        }
        // IPv6: unique-local fc00::/7 and link-local fe80::/10.
        return host.hasPrefix("fc") || host.hasPrefix("fd")
            || host.hasPrefix("fe80:")
    }

    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    switch bytes[0] {
    case 10, 127:
        return true
    case 169:
        return bytes[1] == 254
    case 172:
        return (16...31).contains(Int(bytes[1]))
    case 192:
        return bytes[1] == 168
    case 100:
        return (64...127).contains(Int(bytes[1]))
    default:
        return false
    }
}

enum OpenAICompatibleRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct OpenAICompatibleMessage: Codable, Sendable {
    let role: OpenAICompatibleRole
    let content: String
}

enum OpenAICompatibleClient {
    private struct ChatTemplateKwargs: Codable {
        let enableThinking: Bool

        enum CodingKeys: String, CodingKey {
            case enableThinking = "enable_thinking"
        }
    }

    private struct ChatCompletionRequest: Codable {
        let model: String
        let messages: [OpenAICompatibleMessage]
        let temperature: Double
        let maxTokens: Int
        let chatTemplateKwargs: ChatTemplateKwargs

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct ChatCompletionResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    /// Sends a chat completion request: system prompt, optional few-shot
    /// example turns, then the real user text. `exampleTurns` exists
    /// because in-context examples given as actual user/assistant message
    /// pairs proved far more reliable at pinning down this model's
    /// behavior (no rephrasing, no refusing text that merely resembles a
    /// request/command) than describing the same rules as prose in the
    /// system prompt alone — see LLMPostprocessingPrompts.swift's own doc
    /// comment for the empirical comparison. Defaults to none so this stays
    /// a plain single-turn client for any other caller (e.g. a future
    /// rewrite mode, or a user's custom endpoint that has its own prompt
    /// conventions).
    /// `enableThinking` should be `false` for GEC correction (see the
    /// atom's §9 requirement — thinking must be disabled for the small
    /// correction model); the parameter exists here, not hardcoded, so a
    /// future rewrite mode can decide independently.
    static func chatCompletion(baseURL: URL,
                                apiKey: String?,
                                model: String,
                                systemPrompt: String,
                                exampleTurns: [OpenAICompatibleMessage] = [],
                                userText: String,
                                enableThinking: Bool = false,
                                temperature: Double = 0,
                                maxTokens: Int = 512,
                                useSystemProxy: Bool = true,
                                // 60s comfortably covers a release-build
                                // correction request (measured ~30 tok/s on
                                // the pinned model) even for a long
                                // dictation, and also happens to cover a
                                // -c debug self-test run (self-test only
                                // exists in debug builds -- `#if DEBUG` in
                                // main.swift -- where the SAME request
                                // measured ~35s due to -Onone; see
                                // scripts/build-test-app.sh's own comment
                                // on debug vs release inference speed).
                                timeoutInterval: TimeInterval = 60) async -> Result<String, LLMPostprocessError> {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidBaseURL)
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + "v1/chat/completions"
            : components.path + "/v1/chat/completions"
        guard let url = components.url else {
            return .failure(.invalidBaseURL)
        }

        let payload = ChatCompletionRequest(
            model: model,
            messages: [OpenAICompatibleMessage(role: .system, content: systemPrompt)]
                + exampleTurns
                + [OpenAICompatibleMessage(role: .user, content: userText)],
            temperature: temperature,
            maxTokens: maxTokens,
            chatTemplateKwargs: ChatTemplateKwargs(enableThinking: enableThinking)
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = timeoutInterval
        do {
            req.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .failure(.unexpectedResponse)
        }

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        if !useSystemProxy || isLocalNetworkHost(url.host) {
            // A system-wide HTTP/HTTPS/SOCKS proxy (common on managed
            // Macs, VPN clients, and -- verified empirically during
            // development -- this project's own dev machine) has no route
            // back to loopback or the user's own LAN. Without this
            // override, URLSession still honors that proxy for a
            // 127.0.0.1 target (macOS's proxy exceptions list defaults to
            // *.local/link-local/specific LAN hosts, never loopback), so
            // every request to the bundled SuperDictateLLMHost silently
            // hangs until `timeoutInterval` and falls back to raw text --
            // observed directly as the `llm-gec` self-test's request
            // taking exactly ~30s (the default timeout) before failing.
            // An empty dictionary (not nil) is CFNetwork's documented way
            // to say "no proxy," overriding the system configuration for
            // this session only.
            //
            // The same override covers a user's own llama-server on the
            // LAN, and the Settings checkbox that turns the system proxy
            // off for internet endpoints (a provider behind a local XRay
            // client needs the proxy; a machine behind a broken proxy
            // needs to bypass it).
            config.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return .failure(.network)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.unexpectedResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            return .failure(.unexpectedResponse)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyCompletion)
        }
        return .success(trimmed)
    }
}
