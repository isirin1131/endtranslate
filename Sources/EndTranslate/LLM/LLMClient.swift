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

    /// One-line, human wording for anything the translation path can throw.
    static func describe(_ error: Error) -> String {
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

    private struct Request: Encodable {
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
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    let settings: AppSettings

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
        guard settings.isConfigured else { throw LLMError.notConfigured }
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), url.host != nil else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body = Request(
            model: settings.model.trimmingCharacters(in: .whitespaces),
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
            max_tokens: 4096
        )
        request.httpBody = try JSONEncoder().encode(body)
        Log.write("LLM request: image=\(imagePNG.count / 1024)KB")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? ""
            Log.write("LLM HTTP \(http.statusCode)")
            throw LLMError.http(http.statusCode, snippet)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            Log.write("LLM empty/unexpected response")
            throw LLMError.emptyResponse
        }
        Log.write("LLM OK, \(text.count) chars")
        return text
    }
}
