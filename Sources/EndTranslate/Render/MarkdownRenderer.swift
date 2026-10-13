import AppKit
import CryptoKit
import WebKit

enum MarkdownRenderError: LocalizedError {
    case resourcesMissing, invalidSize, invalidPDF, processTerminated
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "应用内的排版资源不完整"
        case .invalidSize: return "译文尺寸超出排版范围"
        case .invalidPDF: return "无法生成译文预览"
        case .timedOut(let stage): return "\(stage)超时"
        case .processTerminated: return "排版进程已退出，请重试"
        }
    }
}

/// Uses one on-demand WebKit view for local Markdown/LaTeX typesetting. Jobs are
/// serialized so simultaneous translations cannot overwrite one another's page.
@MainActor
final class MarkdownRenderer: NSObject, WKNavigationDelegate {
    static let shared = MarkdownRenderer()
    // Bump after changing the renderer, CSS, or bundled libraries.
    private static let cacheVersion = 1
    private static let memoryLimit = 32 * 1024 * 1024

    private struct Job {
        let key: String
        let markdown: String
        let width: CGFloat
        let fontSize: CGFloat
    }

    private let resources: URL?
    private let cacheDirectory: URL
    private var memory: [String: RenderedTranslation] = [:]
    private var order: [String] = []
    private var memoryBytes = 0
    private var jobs: [Job] = []
    private var waiters: [String: [CheckedContinuation<RenderedTranslation, Error>]] = [:]
    private var worker: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var webView: WKWebView?
    private var navigationCompletion: (@Sendable (Result<Void, Error>) -> Void)?

    init(resources: URL? = nil, cacheDirectory: URL? = nil) {
        self.resources = resources
            ?? Bundle.main.url(forResource: "Renderer", withExtension: nil)
            ?? Bundle.module.url(forResource: "Renderer", withExtension: nil)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let application = Bundle.main.bundleIdentifier ?? "app.endtranslate"
        self.cacheDirectory = cacheDirectory ?? base.appendingPathComponent("\(application)/translations-v\(Self.cacheVersion)")
        super.init()
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        purgeOldEntries()
    }

    func render(markdown: String, width: CGFloat, fontSize: CGFloat) async throws -> RenderedTranslation {
        try Task.checkCancellation()
        guard width.isFinite, fontSize.isFinite, width >= 40, width <= 4_000,
              fontSize >= 4, fontSize <= 100 else { throw MarkdownRenderError.invalidSize }
        let payload = "\(Self.cacheVersion)|\(width)|\(fontSize)|\(markdown)"
        let key = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        if let data = try? Data(contentsOf: cacheURL(key)), let hit = RenderedTranslation(pdfData: data) {
            store(hit, key: key)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL(key).path)
            return hit
        }
        idleTask?.cancel()
        let result: RenderedTranslation = try await withCheckedThrowingContinuation { continuation in
            if waiters[key] != nil {
                waiters[key]?.append(continuation)
            } else {
                waiters[key] = [continuation]
                jobs.append(Job(key: key, markdown: markdown, width: width, fontSize: fontSize))
            }
            if worker == nil { worker = Task { await drain() } }
        }
        try Task.checkCancellation()
        return result
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            let result: Result<RenderedTranslation, Error>
            do {
                let rendered = try await typeset(job)
                store(rendered, key: job.key)
                try? rendered.pdfData.write(to: cacheURL(job.key), options: .atomic)
                result = .success(rendered)
            } catch {
                resetWebView()
                result = .failure(error)
            }
            for continuation in waiters.removeValue(forKey: job.key) ?? [] {
                continuation.resume(with: result)
            }
        }
        worker = nil
        // Release the rendering view after a quiet minute; cached PDFs need no web view.
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            self?.resetWebView()
        }
    }

    private func typeset(_ job: Job) async throws -> RenderedTranslation {
        let view = try await engine()
        view.setFrameSize(NSSize(width: job.width, height: 100))
        let metrics: Any = try await perform("排版译文") { completion in
            view.callAsyncJavaScript(
                "return await EndTranslate.render(markdown, width, fontSize);",
                arguments: ["markdown": job.markdown, "width": job.width, "fontSize": job.fontSize],
                in: nil, in: .page, completionHandler: completion
            )
        }
        guard let metrics = metrics as? [String: Any], let height = metrics["height"] as? Double,
              height.isFinite, height > 0, height <= 100_000 else { throw MarkdownRenderError.invalidSize }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: job.width, height: ceil(height))
        let data: Data = try await perform("生成译文预览") { completion in
            view.createPDF(configuration: configuration, completionHandler: completion)
        }
        guard let rendered = RenderedTranslation(pdfData: data) else { throw MarkdownRenderError.invalidPDF }
        return rendered
    }

    private func engine() async throws -> WKWebView {
        if let webView { return webView }
        guard let resources else { throw MarkdownRenderError.resourcesMissing }
        let index = resources.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { throw MarkdownRenderError.resourcesMissing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), configuration: configuration)
        view.appearance = NSAppearance(named: .aqua)
        view.navigationDelegate = self
        webView = view
        try await perform("载入排版资源") { completion in
            navigationCompletion = completion
            view.loadFileURL(index, allowingReadAccessTo: resources)
        }
        return view
    }

    /// A stalled script or web process must not block every subsequent translation.
    private func perform<Value>(_ stage: String, _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let pending = RenderCompletion(continuation)
            pending.timeout = Task {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                pending.finish(.failure(MarkdownRenderError.timedOut(stage)))
            }
            start { result in MainActor.assumeIsolated { pending.finish(result) } }
        }
    }

    private func resetWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationCompletion?(.failure(MarkdownRenderError.processTerminated))
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        navigationCompletion?(.success(()))
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        navigationCompletion?(.failure(error))
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { resetWebView() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url == resources?.appendingPathComponent("index.html")
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func cacheURL(_ key: String) -> URL { cacheDirectory.appendingPathComponent(key + ".pdf") }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func store(_ rendered: RenderedTranslation, key: String) {
        memoryBytes -= memory[key]?.pdfData.count ?? 0
        memory[key] = rendered
        memoryBytes += rendered.pdfData.count
        touch(key)
        while order.count > 64 || memoryBytes > Self.memoryLimit {
            let oldest = order.removeFirst()
            memoryBytes -= memory.removeValue(forKey: oldest)?.pdfData.count ?? 0
        }
    }

    private func purgeOldEntries() {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "pdf" {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

@MainActor
private final class RenderCompletion<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
