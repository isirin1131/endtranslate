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
            baseURL: "https://unit.test/v1",
            model: "test-model",
            apiKey: "test-key"
        )
        return LLMClient(
            configuration: settings,
            session: session,
            retryPolicy: policy,
            sleeper: sleeper
        )
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
                      refusal: String? = nil) -> Data {
        var message: [String: Any] = ["content": content ?? NSNull()]
        if let refusal { message["refusal"] = refusal }
        var choice: [String: Any] = ["message": message]
        if let finishReason { choice["finish_reason"] = finishReason }
        return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
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
        guard let llmError = error as? LLMClient.LLMError, case .truncated = llmError else {
            Issue.record("expected truncated error, got \(String(describing: error))")
            return
        }
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
}
