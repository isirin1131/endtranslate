import AppKit
import PDFKit
import Testing
@testable import EndTranslate

@Suite(.serialized)
@MainActor
final class MarkdownRendererTests {
    private let directory: URL
    private let renderer: MarkdownRenderer

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EndTranslateRenderTests-\(UUID().uuidString)")
        renderer = MarkdownRenderer(cacheDirectory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func pdf(_ markdown: String, width: CGFloat = 300) async throws -> PDFDocument {
        let rendered = try await renderer.render(markdown: markdown, width: width, fontSize: 10)
        #expect(abs(rendered.size.width - width) < 1)
        #expect(rendered.size.height > 10)
        return try #require(PDFDocument(data: rendered.pdfData))
    }

    @Test func rendersChineseMarkdownAndLatexInOneVectorPage() async throws {
        let output = try await pdf(#"""
        # 中文译文
        **正文 SENTINEL** 与行内公式 $x_1^2 + \frac{1}{2}$。

        \[
        \int_0^1 x^2\,dx = \frac{1}{3}
        \]

        $$\begin{pmatrix}a & b \\ c & d\end{pmatrix}$$

        | 项目 | 值 |
        | --- | --- |
        | 均值 | $\mu$ |
        """#)
        // PDFKit can return compatibility radicals for CJK glyphs in an embedded font.
        let text = try #require(output.string).precomposedStringWithCompatibilityMapping
        #expect(output.pageCount == 1)
        #expect(text.contains("中文译文"))
        #expect(text.contains("SENTINEL"))
        #expect(text.contains("均值"))
        #expect(!text.contains(#"\frac"#))
        #expect(!text.contains(#"\begin"#))
        #expect(!text.contains(#"\mu"#))
        #expect(!text.contains("$$"))
        let page = try #require(output.page(at: 0)?.pageRef)
        let dictionary = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        if let resources {
            var images: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(resources, "XObject", &images)
            // Text and inline SVG paths must not be flattened into a page-sized image.
            if let images { #expect(CGPDFDictionaryGetCount(images) == 0) }
        }
    }

    @Test func unsupportedFormulaKeepsSourceAndOtherFormulasRender() async throws {
        let output = try await pdf(#"Before $\frac{1}{2}$ middle $\notAnActualCommand{x}$ AFTER $\require{html}$"#)
        let text = try #require(output.string)
        #expect(text.contains("Before"))
        #expect(text.contains("AFTER"))
        #expect(text.contains(#"\notAnActualCommand"#))
        #expect(text.contains(#"\require"#))
        #expect(!text.contains(#"\frac"#))
    }

    @Test func concurrentRequestsKeepTheirOwnContentAndSize() async throws {
        async let first = renderer.render(markdown: "FIRSTTOKEN $a^2$", width: 180, fontSize: 10)
        async let second = renderer.render(markdown: "SECONDTOKEN $b^2$", width: 320, fontSize: 10)
        async let duplicate = renderer.render(markdown: "FIRSTTOKEN $a^2$", width: 180, fontSize: 10)
        let (a, b, c) = try await (first, second, duplicate)
        #expect(a === c)
        #expect(abs(a.size.width - 180) < 1)
        #expect(abs(b.size.width - 320) < 1)
        #expect(PDFDocument(data: a.pdfData)?.string?.contains("FIRSTTOKEN") == true)
        #expect(PDFDocument(data: a.pdfData)?.string?.contains("SECONDTOKEN") == false)
        #expect(PDFDocument(data: b.pdfData)?.string?.contains("SECONDTOKEN") == true)
    }

    @Test func cacheCanRenderWithoutStartingWebKitAndMacrosDoNotLeak() async throws {
        _ = try await pdf(#"$\gdef\MyPrivateMacro{z}\MyPrivateMacro$"#)
        let after = try await pdf(#"$\MyPrivateMacro$"#)
        #expect(after.string?.contains(#"\MyPrivateMacro"#) == true)
        let cached = MarkdownRenderer(resources: directory.appendingPathComponent("missing-resources"), cacheDirectory: directory)
        let hit = try await cached.render(markdown: #"$\MyPrivateMacro$"#, width: 300, fontSize: 10)
        #expect(PDFDocument(data: hit.pdfData)?.string?.contains(#"\MyPrivateMacro"#) == true)
    }

    @Test func invalidSizeAndMissingResourcesFailWithoutHanging() async throws {
        await #expect(throws: MarkdownRenderError.self) {
            try await renderer.render(markdown: "text", width: .nan, fontSize: 10)
        }
        let missing = MarkdownRenderer(resources: directory.appendingPathComponent("missing"), cacheDirectory: directory)
        await #expect(throws: MarkdownRenderError.self) {
            try await missing.render(markdown: "text", width: 300, fontSize: 10)
        }
    }

    @Test func legacyTypstCacheIsPurgedOnStartup() throws {
        let parentDir = FileManager.default.temporaryDirectory.appendingPathComponent("EndTranslateLegacyTest-\(UUID().uuidString)")
        let legacyTypstDir = parentDir.appendingPathComponent("typst")
        let dummyCacheDir = parentDir.appendingPathComponent("translations-v1")
        try FileManager.default.createDirectory(at: legacyTypstDir, withIntermediateDirectories: true)
        let sampleFile = legacyTypstDir.appendingPathComponent("sample.pdf")
        try "dummy".write(to: sampleFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: sampleFile.path))

        _ = MarkdownRenderer(cacheDirectory: dummyCacheDir)
        #expect(!FileManager.default.fileExists(atPath: legacyTypstDir.path))
        try? FileManager.default.removeItem(at: parentDir)
    }

    @Test func tamperedResourceFailsVerificationAndThrows() async throws {
        let realResources = Bundle.main.url(forResource: "Renderer", withExtension: nil)
            ?? Bundle.module.url(forResource: "Renderer", withExtension: nil)
        let resourcesURL = try #require(realResources)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EndTranslateTamperTest-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: resourcesURL, to: tempDir)

        let targetFile = tempDir.appendingPathComponent("style.css")
        var content = try String(contentsOf: targetFile, encoding: .utf8)
        content.append("\n/* tampered */\n")
        try content.write(to: targetFile, atomically: true, encoding: .utf8)

        let tamperedRenderer = MarkdownRenderer(resources: tempDir, cacheDirectory: directory)
        await #expect(throws: MarkdownRenderError.self) {
            try await tamperedRenderer.render(markdown: "test", width: 300, fontSize: 10)
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func fitToContentShrinksShortLabelsAndExpandsLongParagraphs() async throws {
        let short = try await renderer.render(markdown: "范数", width: 195, fontSize: 10, fitToContent: true)
        let medium = try await renderer.render(markdown: "Transformer 编码器", width: 195, fontSize: 10, fitToContent: true)
        let long = try await renderer.render(
            markdown: "图1：模型概览。我们将图像分割为固定大小的图像块，对每个图像块进行线性嵌入，添加位置嵌入，并将得到的向量序列输入标准 Transformer 编码器。",
            width: 290,
            fontSize: 10,
            fitToContent: true
        )
        #expect(short.size.width >= 24)
        #expect(short.size.width < 50)
        #expect(medium.size.width > short.size.width)
        #expect(medium.size.width < 130)
        #expect(long.size.width > 240)
    }

    @Test func viewModelTypesetsRestoredCardOnlyWhenRequested() async throws {
        let model = PDFViewModel()
        let note = TranslationAnnotation(model: Annotation(
            id: UUID(), page: 0,
            rect: CGRect(x: 40, y: 80, width: 220, height: 50),
            translationMd: "LAZYTOKEN $x^2$", createdAt: Date()
        ))
        note.status = .done
        note.fallbackText = "LAZYTOKEN x^2"
        model.store.add(note.model, view: note)
        #expect(note.rendered == nil)

        model.ensureRendered(note)
        let deadline = Date().addingTimeInterval(10)
        while note.rendered == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(note.rendered != nil)
        #expect(note.fallbackText == nil)
    }
}
