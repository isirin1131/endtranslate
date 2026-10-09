import Testing
import PDFKit
import CoreText
@testable import EndTranslate

@Suite(.serialized)
final class PDFExporterTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EndTranslateExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pdf(_ pages: [String], box: CGRect = CGRect(x: 0, y: 0, width: 400, height: 500)) -> Data {
        let data = NSMutableData()
        var box = box
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: box.minX + 12, y: box.maxY - 25)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func annotation(_ text: String, page: Int = 0) -> TranslationAnnotation {
        let model = Annotation(id: UUID(), page: page, rect: CGRect(x: 30, y: 280, width: 300, height: 50),
                               translationMd: text, createdAt: Date())
        let note = TranslationAnnotation(model: model)
        note.status = .done
        note.bounds = CGRect(x: 30, y: 345, width: 300, height: 75)
        return note
    }

    private func export(_ notes: [TranslationAnnotation], source: PDFDocument? = nil) throws -> PDFDocument {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        let source = source ?? PDFDocument(data: pdf(["ORIGINAL_CONTENT"]))!
        try PDFExporter.export(document: source, overlays: notes, to: url)
        return try #require(PDFDocument(url: url))
    }

    // PDFKit may extract underscores as separate runs; use whole words as text sentinels.
    @Test func plainTextFallbackIsIncludedInExport() throws {
        let note = annotation("中文译文 FALLBACKTRANSLATION")
        note.fallbackText = note.model.translationMd
        let output = try export([note])
        let text = try #require(output.string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        #expect(text.contains("FALLBACKTRANSLATION"))
        #expect(text.contains("中文译文"))
    }

    @Test func translationWaitingForRenderingCanExportAsPlainText() throws {
        let note = annotation("**RENDERNOTREADY**")
        #expect(note.rendered == nil)
        #expect(note.fallbackText == nil)
        let text = try #require(export([note]).string)
        #expect(text.contains("RENDERNOTREADY"))
        #expect(!text.contains("**"))
    }

    @Test func vectorTranslationAndOriginalContentArePreserved() throws {
        let note = annotation("VECTOR_TRANSLATION")
        note.rendered = RenderedDoc(
            pdfData: pdf(["VECTOR_TRANSLATION"], box: CGRect(x: 0, y: 0, width: 300, height: 75)),
            key: "test", typstSource: ""
        )
        let output = try export([note])
        let text = try #require(output.string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        #expect(text.contains("VECTOR_TRANSLATION"))
        #expect(output.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 400, height: 500))
    }

    @Test func hiddenAndUnfinishedAnnotationsAreNotExported() throws {
        let hidden = annotation("HIDDENTRANSLATION")
        hidden.showsOriginal = true
        let loading = annotation("LOADINGTRANSLATION")
        loading.status = .loading
        // A retry can still have a previous rendered result attached.
        loading.rendered = RenderedDoc(
            pdfData: pdf(["STALE_RESULT"], box: CGRect(x: 0, y: 0, width: 300, height: 75)),
            key: "stale", typstSource: ""
        )
        let failed = annotation("FAILEDTRANSLATION")
        failed.status = .failed("请求超时")
        let text = try #require(export([hidden, loading, failed]).string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        for excluded in ["HIDDENTRANSLATION", "LOADINGTRANSLATION", "STALE_RESULT", "FAILEDTRANSLATION"] {
            #expect(!text.contains(excluded))
        }
    }

    @Test func annotationsStayOnTheirAssignedPages() throws {
        let source = PDFDocument(data: pdf(["PAGE_ONE", "PAGE_TWO"]))!
        let output = try export([annotation("SECONDPAGETRANSLATION", page: 1)], source: source)
        #expect(output.pageCount == 2)
        #expect(!output.page(at: 0)!.string!.contains("SECONDPAGETRANSLATION"))
        #expect(output.page(at: 1)!.string!.contains("SECONDPAGETRANSLATION"))
    }

    @Test func expandedPageAndFallbackExportTogether() throws {
        let source = PDFDocument(data: pdf(["ORIGINAL_CONTENT"]))!
        let note = annotation("GAPTRANSLATION")
        let layout = GapLayout([PageGap(id: note.model.id, y: 330, height: 81)])
        let expanded = try #require(PageGapper.build(from: source.page(at: 0)!, layout: layout, box: .mediaBox))
        note.place(slotMinY: 330, slotHeight: 81, pageBounds: expanded.page.bounds(for: .mediaBox))
        let output = try export([note], source: expanded.document)
        #expect(output.page(at: 0)?.bounds(for: .mediaBox).height == 581)
        #expect(output.string!.contains("ORIGINAL_CONTENT"))
        #expect(output.string!.contains("GAPTRANSLATION"))
    }
}
