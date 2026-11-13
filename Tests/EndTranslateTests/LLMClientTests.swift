import Foundation
import Testing
@testable import EndTranslate

@Suite(.serialized)
final class LLMClientTests {
    /// Mutable state captured by the injected sleeper; tests run serially.
    private final class Recorder: @unchecked Sendable {
        var delays: [TimeInterval] = []
    }

    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient(
        baseURL: String = "https://unit.test/v1",
        model: String = "test-model",
        thinking: Bool = false,
        policy: LLMClient.RetryPolicy = LLMClient.RetryPolicy(
            maxAttempts: 3,
            baseDelay: 0.001,
            maxDelay: 0.002,
            maxRetryAfter: 0.002,
            totalBudget: 5
        ),
        sleeper: @escaping LLMClient.Sleeper = { _ in }
    ) -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let settings = LLMClient.Configuration(
            baseURL: baseURL,
            model: model,
            apiKey: "test-key",
            thinking: thinking
        )
        return LLMClient(
            configuration: settings,
            session: session,
            retryPolicy: policy,
            sleeper: sleeper
        )
    }

    /// URLProtocol hands the body over as a stream, so `httpBody` alone isn't enough.
    private func requestBody(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func response(_ status: Int, headers: [String: String] = [:],
                          for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func json(content: String?, finishReason: String? = "stop",
                      refusal: String? = nil,
                      completionTokens: Int? = nil,
                      reasoningTokens: Int? = nil) -> Data {
        var message: [String: Any] = ["content": content ?? NSNull()]
        if let refusal { message["refusal"] = refusal }
        var choice: [String: Any] = ["message": message]
        if let finishReason { choice["finish_reason"] = finishReason }
        var payload: [String: Any] = ["choices": [choice]]
        if completionTokens != nil || reasoningTokens != nil {
            var usage: [String: Any] = [:]
            if let completionTokens { usage["completion_tokens"] = completionTokens }
            if let reasoningTokens {
                usage["completion_tokens_details"] = ["reasoning_tokens": reasoningTokens]
            }
            payload["usage"] = usage
        }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func errorBody(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
    }

    private func capture(_ operation: () async throws -> Void) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    @Test func successfulResponseIsReturnedAndFenceIsStripped() async throws {
        StubURLProtocol.handler = { [self] request in
            (response(200, for: request), json(content: "```markdown\n译文\n```"))
        }
        let text = try await makeClient().translate(imagePNG: Data([0x89, 0x50]))
        #expect(text == "译文")
    }

    @Test func truncatedResponseIsReportedWithoutRetrying() async {
        var attempts = 0
        StubURLProtocol.handler = { [self] request in
            attempts += 1
            return (response(200, for: request), json(content: "半截译文", finishReason: "length"))
        }
        let recorder = Recorder()
        let client = makeClient(sleeper: { recorder.delays.append($0) })
        let error = await capture { _ = try await client.translate(imagePNG: Data()) }
        #expect(attempts == 1)
        guard let llmError = error as? LLMClient.LLMError,
              case .truncated(let reasoningTokens) = llmError else {
            Issue.record("expected truncated error, got \(String(describing: error))")
            return
        }
        #expect(reasoningTokens == 0)
        #expect(recorder.delays.isEmpty)
    }

    @Test func maxTokensFinishReasonIsTreatedAsTruncated() async {
        StubURLProtocol.handler = { [self] request in
            (response(200, for: request), json(content: "半截", finishReason: "max_tokens"))
        }
        let error = await capture { _ = try await makeClient().translate(imagePNG: Data()) }
        guard let llmError = error as? LLMClient.LLMError, case .truncated = llmError else {
            Issue.record("expected truncated error, got \(String(describing: error))")
            return
        }
    }

    @Test func deepSeekRequestsDisableThinkingAndUseAWiderBudget() async throws {
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { [self] request in
            bodies.append(requestBody(request) ?? [:])
            return (response(200, for: request), json(content: "译文"))
        }
        _ = try await makeClient(baseURL: "https://api.deepseek.com", model: "deepseek-flash")
            .translate(imagePNG: Data())
        #expect(bodies.count == 1)
        #expect(bodies[0]["max_tokens"] as? Int == 8192)
        #expect((bodies[0]["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test func deepSeekCanOptIntoThinkingWithMoreHeadroom() async throws {
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { [self] request in
            bodies.append(requestBody(request) ?? [:])
            return (response(200, for: request), json(content: "译文"))
        }
        _ = try await makeClient(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-flash",
            thinking: true
        ).translate(imagePNG: Data())
        #expect(bodies[0]["max_tokens"] as? Int == 16384)
        #expect((bodies[0]["thinking"] as? [String: Any])?["type"] as? String == "enabled")
    }

    @Test func otherServicesDoNotReceiveTheThinkingSwitch() async throws {
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { [self] request in
            bodies.append(requestBody(request) ?? [:])
            return (response(200, for: request), json(content: "译文"))
        }
        _ = try await makeClient().translate(imagePNG: Data())
        #expect(bodies[0]["max_tokens"] as? Int == 4096)
        #expect(bodies[0]["thinking"] == nil)
    }

    @Test func truncatedReasoningIsRetriedWithThinkingOff() async throws {
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { [self] request in
            bodies.append(requestBody(request) ?? [:])
            if bodies.count == 1 {
                return (response(200, for: request),
                        json(content: "半截", finishReason: "length",
                             completionTokens: 4096, reasoningTokens: 3979))
            }
            return (response(200, for: request), json(content: "完整译文"))
        }
        let text = try await makeClient(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-flash",
            thinking: true
        ).translate(imagePNG: Data())
        #expect(text == "完整译文")
        #expect(bodies.count == 2)
        #expect((bodies[1]["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test func contentFilterAndRefusalAreReported() async {
        StubURLProtocol.handler = { [self] request in
            (response(200, for: request), json(content: nil, finishReason: "content_filter"))
        }
        let error = await capture { _ = try await makeClient().translate(imagePNG: Data()) }
        guard let llmError = error as? LLMClient.LLMError, case .refused = llmError else {
            Issue.record("expected refused error, got \(String(describing: error))")
            return
        }
    }

    @Test func retriesRateLimitAndUsesRetryAfter() async throws {
        var attempts = 0
        StubURLProtocol.handler = { [self] request in
            attempts += 1
            if attempts == 1 {
                return (response(429, headers: ["Retry-After": "0"], for: request),
                        errorBody("rate limited"))
            }
            return (response(200, for: request), json(content: "重试成功"))
        }
        let recorder = Recorder()
        let client = makeClient(sleeper: { recorder.delays.append($0) })
        let text = try await client.translate(imagePNG: Data())
        #expect(text == "重试成功")
        #expect(attempts == 2)
        #expect(recorder.delays.count == 1)
    }

    @Test func retriesServerErrorsUntilAttemptsAreExhausted() async {
        var attempts = 0
        StubURLProtocol.handler = { [self] request in
            attempts += 1
            return (response(503, for: request), errorBody("unavailable"))
        }
        let recorder = Recorder()
        let client = makeClient(sleeper: { recorder.delays.append($0) })
        let error = await capture { _ = try await client.translate(imagePNG: Data()) }
        #expect(attempts == 3)
        #expect(recorder.delays.count == 2)
        guard let llmError = error as? LLMClient.LLMError,
              case .http(503, _) = llmError else {
            Issue.record("expected HTTP 503, got \(String(describing: error))")
            return
        }
    }

    @Test func retriesTransientNetworkFailures() async {
        var attempts = 0
        StubURLProtocol.handler = { _ in
            attempts += 1
            throw URLError(.timedOut)
        }
        let recorder = Recorder()
        let client = makeClient(sleeper: { recorder.delays.append($0) })
        let error = await capture { _ = try await client.translate(imagePNG: Data()) }
        #expect(attempts == 3)
        #expect(recorder.delays.count == 2)
        guard let urlError = error as? URLError else {
            Issue.record("expected URLError, got \(String(describing: error))")
            return
        }
        #expect(urlError.code == .timedOut)
    }

    @Test func doesNotRetryClientErrors() async {
        var attempts = 0
        StubURLProtocol.handler = { [self] request in
            attempts += 1
            return (response(401, for: request), errorBody("bad key"))
        }
        let recorder = Recorder()
        let client = makeClient(sleeper: { recorder.delays.append($0) })
        let error = await capture { _ = try await client.translate(imagePNG: Data()) }
        #expect(attempts == 1)
        #expect(recorder.delays.isEmpty)
        guard let llmError = error as? LLMClient.LLMError,
              case .http(401, _) = llmError else {
            Issue.record("expected HTTP 401, got \(String(describing: error))")
            return
        }
        #expect(llmError.needsSettingsReview)
    }

    @Test func cancellationStopsRetrying() async {
        var attempts = 0
        StubURLProtocol.handler = { [self] request in
            attempts += 1
            return (response(429, headers: ["Retry-After": "1"], for: request), errorBody("slow down"))
        }
        let client = makeClient(sleeper: { _ in throw CancellationError() })
        let error = await capture { _ = try await client.translate(imagePNG: Data()) }
        #expect(attempts == 1)
        #expect(error is CancellationError)
    }

    @Test func emptyChoicesAreReported() async {
        StubURLProtocol.handler = { [self] request in
            (response(200, for: request), Data(#"{"choices":[]}"#.utf8))
        }
        let error = await capture { _ = try await makeClient().translate(imagePNG: Data()) }
        guard let llmError = error as? LLMClient.LLMError, case .emptyResponse = llmError else {
            Issue.record("expected empty response, got \(String(describing: error))")
            return
        }
    }

    @Test func localEndpointNeedsNoKey() {
        let configuration = LLMClient.Configuration(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "llava",
            apiKey: ""
        )
        #expect(configuration.isConfigured)
        #expect(LLMClient.Configuration.isLocalEndpoint("http://localhost:1234/v1"))
        #expect(!LLMClient.Configuration.isLocalEndpoint("https://api.openai.com/v1"))
    }

    @Test func thinkingControlIsLimitedToDeepSeek() {
        let deepSeek = LLMClient.Configuration(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-flash",
            apiKey: "key"
        )
        let proxy = LLMClient.Configuration(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-flash",
            apiKey: "key"
        )
        let other = LLMClient.Configuration(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o",
            apiKey: "key"
        )
        #expect(deepSeek.supportsThinkingControl)
        #expect(proxy.supportsThinkingControl)
        #expect(!other.supportsThinkingControl)
    }
}
