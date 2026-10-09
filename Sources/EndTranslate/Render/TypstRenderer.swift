import Foundation
import AppKit
import CoreGraphics
import CryptoKit

final class RenderedDoc: @unchecked Sendable {
    let pdfData: Data
    let size: CGSize
    let key: String
    let typstSource: String

    private let lock = NSLock()
    private var page: CGPDFPage?

    init?(pdfData: Data, key: String, typstSource: String) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let pdf = CGPDFDocument(provider),
              let first = pdf.page(at: 1) else { return nil }
        self.pdfData = pdfData
        self.page = first
        self.size = first.getBoxRect(.mediaBox).size
        self.key = key
        self.typstSource = typstSource
    }

    func pdfPage() -> CGPDFPage? {
        lock.lock()
        defer { lock.unlock() }
        return page
    }

    /// Draws top-left aligned at uniform scale, so a clamped box clips rather than squashes.
    /// `yDown` matches the caller's context orientation: PDF pages are y-up, so drawing into a
    /// flipped context (NSView.isFlipped) without unflipping mirrors the page vertically.
    func draw(in rect: CGRect, context: CGContext, yDown: Bool = false) {
        guard let page = pdfPage() else { return }
        let box = page.getBoxRect(.mediaBox)
        let scale = rect.width / max(box.width, 1)
        context.saveGState()
        context.clip(to: rect)
        if yDown {
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: 1, y: -1)
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.maxY)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    func nsImage(scale: CGFloat = 2) -> NSImage? {
        guard let page = pdfPage() else { return nil }
        let w = max(Int((size.width * scale).rounded()), 1)
        let h = max(Int((size.height * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

enum TypstError: LocalizedError {
    case binaryMissing(String)
    case compileFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let path): return "找不到 typst：\(path)"
        case .compileFailed(let message): return "typst 编译失败：\(message)"
        }
    }
}

final class TypstRenderer: @unchecked Sendable {
    static let shared = TypstRenderer()

    static let bundledPaths = [
        "/opt/homebrew/bin/typst",
        "/usr/local/bin/typst",
        NSHomeDirectory() + "/.cargo/bin/typst"
    ]

    let executablePath: String?
    private let cacheDir: URL
    private let lock = NSLock()
    private var memory: [String: RenderedDoc] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<RenderedDoc, Error>] = [:]

    private init() {
        executablePath = Self.bundledPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("EndTranslate/typst", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        purgeOldEntries()
    }

    private func purgeOldEntries() {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }

    static func key(markdown: String, width: CGFloat, fontSize: CGFloat) -> String {
        let payload = "v\(MarkdownToTypst.templateVersion)|\(MarkdownToTypst.mitexVersion)|\(width)|\(fontSize)|\(markdown)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    func cached(key: String) -> RenderedDoc? {
        lock.lock()
        defer { lock.unlock() }
        return memory[key]
    }

    private enum RenderSlot {
        case ready(RenderedDoc)
        case pending(Task<RenderedDoc, Error>)
        case owner(Task<RenderedDoc, Error>)
    }

    private func slot(
        key: String,
        markdown: String,
        width: CGFloat,
        fontSize: CGFloat,
        allowDegrade: Bool
    ) -> RenderSlot {
        lock.lock()
        defer { lock.unlock() }
        if let hit = memory[key] { return .ready(hit) }
        if let existing = inFlight[key] { return .pending(existing) }
        let task = Task<RenderedDoc, Error>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw TypstError.compileFailed("renderer released") }
            defer { self.finish(key: key) }
            if let onDisk = self.loadFromDisk(key: key) { return onDisk }
            do {
                return try self.compile(markdown: markdown, width: width, fontSize: fontSize, key: key, degradedMath: [])
            } catch {
                guard allowDegrade else { throw error }
                let bad = await self.invalidMath(in: markdown)
                guard !bad.isEmpty else { throw error }
                Log.write("typst degrading \(bad.count) unrenderable formula(s) in \(key)")
                return try self.compile(markdown: markdown, width: width, fontSize: fontSize, key: key, degradedMath: bad)
            }
        }
        inFlight[key] = task
        return .owner(task)
    }

    func render(
        markdown: String,
        width: CGFloat,
        fontSize: CGFloat,
        allowDegrade: Bool = true
    ) async throws -> RenderedDoc {
        let key = Self.key(markdown: markdown, width: width, fontSize: fontSize)
        switch slot(key: key, markdown: markdown, width: width, fontSize: fontSize, allowDegrade: allowDegrade) {
        case .ready(let doc):
            return doc
        case .pending(let task), .owner(let task):
            let doc = try await task.value
            store(doc, key: key)
            return doc
        }
    }

    /// Compiles each formula on its own to find the ones mitex rejects, so only those fall back to raw text.
    private func invalidMath(in markdown: String) async -> Set<String> {
        let unique = Set(MarkdownToTypst.mathSnippets(markdown).map(MarkdownToTypst.normalizeMath))
        var bad: Set<String> = []
        for snippet in unique.sorted().prefix(24) where !snippet.isEmpty {
            let probe = "$$\n\(snippet)\n$$"
            if (try? await render(markdown: probe, width: 480, fontSize: 10, allowDegrade: false)) == nil {
                bad.insert(snippet)
            }
        }
        return bad
    }

    private func finish(key: String) {
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
    }

    private func store(_ doc: RenderedDoc, key: String) {
        lock.lock()
        memory[key] = doc
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 200, let oldest = order.first {
            memory[oldest] = nil
            order.removeFirst()
        }
        lock.unlock()
    }

    private func loadFromDisk(key: String) -> RenderedDoc? {
        let url = cacheDir.appendingPathComponent("\(key).pdf")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let source = (try? String(contentsOf: cacheDir.appendingPathComponent("\(key).typ"), encoding: .utf8)) ?? ""
        return RenderedDoc(pdfData: data, key: key, typstSource: source)
    }

    private func compile(
        markdown: String,
        width: CGFloat,
        fontSize: CGFloat,
        key: String,
        degradedMath: Set<String>
    ) throws -> RenderedDoc {
        guard let executablePath else { throw TypstError.binaryMissing(Self.bundledPaths[0]) }
        let source = MarkdownToTypst.document(
            markdown: markdown,
            width: width,
            fontSize: fontSize,
            degradedMath: degradedMath
        )
        let sourceURL = cacheDir.appendingPathComponent("\(key).typ")
        let outputURL = cacheDir.appendingPathComponent("\(key).pdf")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["compile", "--format", "pdf", sourceURL.path, outputURL.path]
        process.currentDirectoryURL = cacheDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let started = Date()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .split(separator: "\n").prefix(4).joined(separator: " ") ?? "exit \(process.terminationStatus)"
            Log.write("typst FAILED \(elapsed)ms key=\(key) \(message)")
            throw TypstError.compileFailed(message)
        }
        guard let data = try? Data(contentsOf: outputURL),
              let doc = RenderedDoc(pdfData: data, key: key, typstSource: source) else {
            throw TypstError.compileFailed("no output")
        }
        Log.write("typst ok \(elapsed)ms size=\(Int(doc.size.width))x\(Int(doc.size.height))pt key=\(key)")
        return doc
    }

    func renderFitting(
        markdown: String,
        idealWidth: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        fontSize: CGFloat
    ) async -> RenderedDoc? {
        var width = min(max(idealWidth, minWidth), maxWidth)
        var last: RenderedDoc?
        for _ in 0..<4 {
            guard let doc = try? await render(markdown: markdown, width: width, fontSize: fontSize) else {
                return last
            }
            last = doc
            if doc.size.height <= maxHeight || width >= maxWidth - 0.5 { return doc }
            let ratio = (doc.size.height / max(maxHeight, 1)).squareRoot()
            let next = min(maxWidth, max(minWidth, width * max(1.12, ratio)))
            if next <= width + 0.5 { return doc }
            width = next
        }
        return last
    }
}
