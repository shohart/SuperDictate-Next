// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

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

/// True for 127.0.0.1/::1/localhost — see the `connectionProxyDictionary`
/// override at the call site for why this matters.
func isLoopbackHost(_ host: String?) -> Bool {
    guard let host else { return false }
    return host == "127.0.0.1" || host == "::1" || host == "localhost"
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
        if isLoopbackHost(url.host) {
            // A system-wide HTTP/HTTPS/SOCKS proxy (common on managed
            // Macs, VPN clients, and -- verified empirically during
            // development -- this project's own dev machine) has no route
            // back into this same machine's loopback interface. Without
            // this override, URLSession still honors that proxy for a
            // 127.0.0.1 target (macOS's proxy exceptions list defaults to
            // *.local/link-local/specific LAN hosts, never loopback), so
            // every request to the bundled SuperDictateLLMHost silently
            // hangs until `timeoutInterval` and falls back to raw text --
            // observed directly as the `llm-gec` self-test's request
            // taking exactly ~30s (the default timeout) before failing.
            // An empty dictionary (not nil) is CFNetwork's documented way
            // to say "no proxy," overriding the system configuration for
            // this session only. Applies equally to a user-supplied custom
            // baseURL that happens to also be loopback (e.g. their own
            // local llama-server) -- same reasoning, same fix.
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
