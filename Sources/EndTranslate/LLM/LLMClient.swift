import Foundation

struct LLMClient {
    enum Prompts {
        static let system = """
        你是学术论文翻译助手。图片是英文 PDF 的一个选区。请：
        1. 将其中英文内容忠实翻译为中文，输出 GitHub Flavored Markdown；
        2. 数学公式一律用 LaTeX 表示，行内 $...$，独立公式 $$...$$，不要翻译公式内的符号；
        3. 保留段落结构，不要输出原文，不要加解释或前后缀。
        """
        static let user = "请翻译这张图片中的选区内容。"
    }

    enum LLMError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case emptyResponse
        /// The service hit its output limit; the returned Markdown is incomplete.
        /// `reasoningTokens` separates "the model thought until the budget ran out"
        /// from "the translation itself is too long" — different remedies.
        case truncated(reasoningTokens: Int)
        /// The service refused to translate the selected content.
        case refused

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "翻译服务尚未配置完整"
            case .badURL: return "Base URL 无效"
            case .http(let code, let body):
                let detail = Self.serverMessage(body).map { "：\($0)" } ?? ""
                switch code {
                case 401: return "API Key 认证失败（HTTP 401），请在设置中核对服务地址和对应的 Key"
                case 403: return "服务拒绝访问（HTTP 403），请检查模型权限或账户限制"
                case 404: return "接口地址或模型不存在（HTTP 404）\(detail)"
                case 413: return "选区图片过大（HTTP 413）"
                case 429: return "请求过于频繁或额度不足（HTTP 429）"
                case 500...599: return "服务暂时不可用（HTTP \(code)）"
                default: return "HTTP \(code)\(detail)"
                }
            case .emptyResponse: return "响应为空或格式不符"
            case .truncated(let reasoningTokens):
                // Thinking and the visible answer share one budget, so a short
                // translation can still be truncated by a long reasoning pass.
                return reasoningTokens > 0
                    ? "模型在思考上耗尽了输出额度，译文未完成，请重试"
                    : "译文超出模型输出上限，可能不完整，请缩短选区后重试"
            case .refused: return "服务拒绝了本次翻译内容"
            }
        }

        var needsSettingsReview: Bool {
            switch self {
            case .notConfigured, .badURL, .http(401, _), .http(403, _), .http(404, _): return true
            default: return false
            }
        }

        /// `{"error": {"message": …}}` is what OpenAI-compatible servers send back.
        private static func serverMessage(_ body: String) -> String? {
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
            }
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["error"] as? String
                ?? json["message"] as? String
            return message.map { String($0.prefix(120)) }
        }
    }

    /// Snapshot of the user's service settings, so one translation attempt cannot observe
    /// half-edited fields while it is running.
    struct Configuration: Equatable {
        var baseURL: String
        var model: String
        var apiKey: String
        /// DeepSeek-only: let the model reason before writing. Off by default because
        /// reasoning shares `max_tokens` with the answer and adds seconds per selection.
        var thinking: Bool

        init(baseURL: String, model: String, apiKey: String, thinking: Bool = false) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.thinking = thinking
        }

        init(settings: AppSettings) {
            self.init(
                baseURL: settings.baseURL,
                model: settings.model,
                apiKey: settings.apiKey,
                thinking: settings.thinkingEnabled
            )
        }

        var isConfigured: Bool {
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !base.isEmpty && hasModel && (hasKey || Self.isLocalEndpoint(base))
        }

        /// Local servers (Ollama, LM Studio…) usually run without a key.
        static func isLocalEndpoint(_ baseURL: String) -> Bool {
            guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host else {
                return false
            }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        /// DeepSeek defaults to thinking mode and exposes a `thinking` switch; other
        /// OpenAI-compatible endpoints reject unknown fields, so the switch is opt-in
        /// per host rather than sent blindly.
        var supportsThinkingControl: Bool {
            guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
                .host?.lowercased() else { return false }
            return host == "deepseek.com" || host.hasSuffix(".deepseek.com")
        }
    }

    /// Retry only transient failures. `finish_reason == "length"` (or `"max_tokens"`) is
    /// not retried as-is: the same request with the same output limit would truncate again.
    /// It gets one *changed* attempt (thinking off / larger budget) instead.
    struct RetryPolicy: Equatable, Sendable {
        var maxAttempts: Int = 3
        var baseDelay: TimeInterval = 1
        var maxDelay: TimeInterval = 8
        var maxRetryAfter: TimeInterval = 20
        /// Stop retrying once the whole translation has spent this long.
        var totalBudget: TimeInterval = 180
    }

    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    typealias Clock = @Sendable () -> Date

    private struct Request: Encodable {
        struct Thinking: Encodable { let type: String }
        struct Message: Encodable {
            struct Part: Encodable {
                struct ImageURL: Encodable { let url: String }
                let type: String
                let text: String?
                let image_url: ImageURL?
            }
            let role: String
            let content: [Part]
        }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        /// Omitted for services that don't understand it (see `supportsThinkingControl`).
        let thinking: Thinking?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable {
            struct CompletionDetails: Decodable {
                let reasoning_tokens: Int?
            }
            let completion_tokens: Int?
            let completion_tokens_details: CompletionDetails?
        }
        let choices: [Choice]
        let usage: Usage?
    }

    let configuration: Configuration
    let session: URLSession
    let retryPolicy: RetryPolicy
    private let sleeper: Sleeper
    private let now: Clock

    init(
        settings: AppSettings,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleeper: @escaping Sleeper = LLMClient.defaultSleeper,
        now: @escaping Clock = { Date() }
    ) {
        self.init(
            configuration: Configuration(settings: settings),
            session: session,
            retryPolicy: retryPolicy,
            sleeper: sleeper,
            now: now
        )
    }

    init(
        configuration: Configuration,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleeper: @escaping Sleeper = LLMClient.defaultSleeper,
        now: @escaping Clock = { Date() }
    ) {
        self.configuration = configuration
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.now = now
    }

    private static let defaultSleeper: Sleeper = { seconds in
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 300) * 1_000_000_000))
    }

    /// One-line, human wording for anything the translation path can throw.
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "已取消" }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "请求超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost: return "网络未连接"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址，请检查 Base URL"
            case .cannotConnectToHost: return "无法连接服务器，请检查 Base URL"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "安全连接失败"
            case .cancelled: return "已取消"
            default: return error.localizedDescription
            }
        }
        if error is DecodingError { return "响应格式不符（接口是否为 OpenAI 兼容？）" }
        return error.localizedDescription
    }

    func translate(imagePNG: Data) async throws -> String {
        let text = try await chat(system: Prompts.system, user: Prompts.user, imagePNG: imagePNG)
        return Self.stripFence(text)
    }

    /// Models sometimes wrap the whole answer in ```markdown … ``` despite the prompt.
    static func stripFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return trimmed }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return trimmed }
        let lang = lines[0].dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        // A real code block (```python) is content; only unwrap markdown/plain wrappers.
        guard ["", "markdown", "md", "gfm", "text"].contains(lang) else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chat(system: String, user: String, imagePNG: Data) async throws -> String {
        guard configuration.isConfigured else { throw LLMError.notConfigured }
        var maxTokens = outputBudget
        var thinking = configuration.supportsThinkingControl && configuration.thinking
        var request = try makeRequest(
            system: system, user: user, imagePNG: imagePNG,
            maxTokens: maxTokens, thinking: thinking
        )
        let started = now()
        let maxAttempts = min(max(retryPolicy.maxAttempts, 1), 5)
        var lastError: Error = LLMError.emptyResponse
        /// At most one escalation: re-ask with thinking off / a larger output budget.
        var escalated = false

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            let remainingBudget = retryPolicy.totalBudget - now().timeIntervalSince(started)
            guard remainingBudget > 1 else { throw lastError }
            var attemptRequest = request
            attemptRequest.timeoutInterval = min(120, max(1, remainingBudget))
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.emptyResponse
                }
                if (200..<300).contains(http.statusCode) {
                    do {
                        return try decode(data)
                    } catch LLMError.truncated(let reasoningTokens) where !escalated {
                        let error = LLMError.truncated(reasoningTokens: reasoningTokens)
                        lastError = error
                        // Only a reasoning pass can be crowded out of the budget; a
                        // genuinely long answer would just be truncated again.
                        guard reasoningTokens > 0 else { throw error }
                        let nextBudget = escalatedBudget(from: maxTokens)
                        guard nextBudget > maxTokens || thinking else { throw error }
                        escalated = true
                        maxTokens = max(maxTokens, nextBudget)
                        thinking = false
                        request = try makeRequest(
                            system: system, user: user, imagePNG: imagePNG,
                            maxTokens: maxTokens, thinking: thinking
                        )
                        Log.write("LLM truncated after \(reasoningTokens) reasoning tokens; retrying with max_tokens=\(maxTokens), thinking=\(thinking)")
                        continue
                    }
                }

                let error = LLMError.http(
                    http.statusCode,
                    String(data: data.prefix(500), encoding: .utf8) ?? ""
                )
                lastError = error
                guard attempt < maxAttempts, Self.isRetryable(statusCode: http.statusCode) else {
                    throw error
                }
                guard let delay = retryDelay(
                    attempt: attempt,
                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                    started: started
                ) else {
                    throw error
                }
                Log.write("LLM retry \(attempt + 1)/\(maxAttempts) after HTTP \(http.statusCode) in \(String(format: "%.1f", delay))s")
                try await sleeper(delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                lastError = error
                guard attempt < maxAttempts, Self.isRetryable(urlError: error) else {
                    throw error
                }
                guard let delay = retryDelay(
                    attempt: attempt,
                    retryAfterHeader: nil,
                    started: started
                ) else {
                    throw error
                }
                Log.write("LLM retry \(attempt + 1)/\(maxAttempts) after \(error.code.rawValue) in \(String(format: "%.1f", delay))s")
                try await sleeper(delay)
            } catch let error as LLMError {
                throw error
            } catch {
                throw error
            }
        }
        throw lastError
    }

    /// Room for the visible answer, not a target: models stop at `stop` long before.
    /// DeepSeek shares this budget with its thinking pass, and its non-thinking default
    /// is 8K, so 4K was leaving no room for formula-heavy pages.
    private var outputBudget: Int {
        guard configuration.supportsThinkingControl else { return 4096 }
        return configuration.thinking ? 16384 : 8192
    }

    /// Turning thinking off frees the budget the reasoning pass consumed. Other services
    /// get a modestly larger cap instead, since the switch isn't theirs to honour.
    private func escalatedBudget(from current: Int) -> Int {
        if configuration.supportsThinkingControl { return max(current, 8192) }
        return min(max(current * 2, 8192), 16384)
    }

    private func makeRequest(
        system: String,
        user: String,
        imagePNG: Data,
        maxTokens: Int,
        thinking: Bool
    ) throws -> URLRequest {
        let base = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), url.host != nil else {
            throw LLMError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body = Request(
            model: configuration.model.trimmingCharacters(in: .whitespaces),
            messages: [
                .init(role: "system", content: [
                    .init(type: "text", text: system, image_url: nil)
                ]),
                .init(role: "user", content: [
                    .init(type: "text", text: user, image_url: nil),
                    .init(type: "image_url", text: nil,
                          image_url: .init(url: "data:image/png;base64,\(imagePNG.base64EncodedString())"))
                ])
            ],
            max_tokens: maxTokens,
            thinking: configuration.supportsThinkingControl
                ? .init(type: thinking ? "enabled" : "disabled")
                : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        Log.write("LLM request: image=\(imagePNG.count / 1024)KB max_tokens=\(maxTokens) thinking=\(configuration.supportsThinkingControl ? String(thinking) : "n/a")")
        return request
    }

    private func decode(_ data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = decoded.choices.first else { throw LLMError.emptyResponse }
        let reasoningTokens = decoded.usage?.completion_tokens_details?.reasoning_tokens ?? 0
        if choice.finish_reason == "length" || choice.finish_reason == "max_tokens" {
            Log.write("LLM truncated: completion=\(decoded.usage?.completion_tokens ?? -1) reasoning=\(reasoningTokens)")
            throw LLMError.truncated(reasoningTokens: reasoningTokens)
        }
        if choice.finish_reason == "content_filter" || choice.message.refusal != nil {
            throw LLMError.refused
        }
        guard let text = choice.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        Log.write("LLM OK, \(text.count) chars (reasoning=\(reasoningTokens))")
        return text
    }

    /// Sleep before the next attempt, or return nil when the retry budget is exhausted.
    private func retryDelay(attempt: Int, retryAfterHeader: String?, started: Date) -> TimeInterval? {
        let exponent = pow(2, Double(max(attempt - 1, 0)))
        let base = min(max(retryPolicy.maxDelay, 0), max(retryPolicy.baseDelay, 0) * exponent)
        let jitter = Double.random(in: 0...0.25) * base
        var delay = base + jitter
        if let retryAfter = Self.retryAfterInterval(retryAfterHeader, now: now()) {
            delay = max(delay, min(retryAfter, max(retryPolicy.maxRetryAfter, 0)))
        }
        let remaining = retryPolicy.totalBudget - now().timeIntervalSince(started)
        guard remaining > 0.5 else { return nil }
        return min(delay, remaining)
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(statusCode)
    }

    private static func isRetryable(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    private static func retryAfterInterval(_ header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
