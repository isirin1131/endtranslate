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

    private func export(_ notes: [TranslationAnnotation], source: PDFDocument? = nil) async throws -> PDFDocument {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        let source = source ?? PDFDocument(data: pdf(["ORIGINAL_CONTENT"]))!
        try await PDFExporter.export(document: source, overlays: notes, to: url)
        return try #require(PDFDocument(url: url))
    }

    // PDFKit may extract underscores as separate runs; use whole words as text sentinels.
    @Test func plainTextFallbackIsIncludedInExport() async throws {
        let note = annotation("中文译文 FALLBACKTRANSLATION")
        note.fallbackText = note.model.translationMd
        let output = try await export([note])
        let text = try #require(output.string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        #expect(text.contains("FALLBACKTRANSLATION"))
        #expect(text.contains("中文译文"))
    }

    @Test func translationWaitingForRenderingCanExportAsPlainText() async throws {
        let note = annotation("**RENDERNOTREADY**")
        #expect(note.rendered == nil)
        #expect(note.fallbackText == nil)
        let output = try await export([note])
        let text = try #require(output.string)
        #expect(text.contains("RENDERNOTREADY"))
        #expect(!text.contains("**"))
    }

    @Test func vectorTranslationAndOriginalContentArePreserved() async throws {
        let note = annotation("VECTOR_TRANSLATION")
        note.rendered = RenderedTranslation(
            pdfData: pdf(["VECTOR_TRANSLATION"], box: CGRect(x: 0, y: 0, width: 300, height: 75))
        )
        let output = try await export([note])
        let text = try #require(output.string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        #expect(text.contains("VECTOR_TRANSLATION"))
        #expect(output.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 400 + PDFExporter.sidebarWidth, height: 500))
    }

    @Test func unfinishedAnnotationsAreNotExported() async throws {
        let loading = annotation("LOADINGTRANSLATION")
        loading.status = .loading
        // A retry can still have a previous rendered result attached.
        loading.rendered = RenderedTranslation(
            pdfData: pdf(["STALE_RESULT"], box: CGRect(x: 0, y: 0, width: 300, height: 75))
        )
        let failed = annotation("FAILEDTRANSLATION")
        failed.status = .failed("请求超时")
        let output = try await export([loading, failed])
        let text = try #require(output.string)
        #expect(text.contains("ORIGINAL_CONTENT"))
        // Pages without completed annotations keep their original mediaBox width.
        #expect(output.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 400, height: 500))
        for excluded in ["LOADINGTRANSLATION", "STALE_RESULT", "FAILEDTRANSLATION"] {
            #expect(!text.contains(excluded))
        }
    }

    @Test func annotationsStayOnTheirAssignedPages() async throws {
        let source = PDFDocument(data: pdf(["PAGE_ONE", "PAGE_TWO"]))!
        let output = try await export([annotation("SECONDPAGETRANSLATION", page: 1)], source: source)
        #expect(output.pageCount == 2)
        #expect(output.page(at: 0)?.bounds(for: .mediaBox).width == 400)
        #expect(output.page(at: 1)?.bounds(for: .mediaBox).width == 400 + PDFExporter.sidebarWidth)
        #expect(!output.page(at: 0)!.string!.contains("SECONDPAGETRANSLATION"))
        #expect(output.page(at: 1)!.string!.contains("SECONDPAGETRANSLATION"))
    }

    @Test func sideBySideCardsExportIntoRightSidebarWithoutSlicingOriginalPage() async throws {
        let source = PDFDocument(data: pdf(["ORIGINAL_CONTENT"]))!
        let left = annotation("LEFTCARDTRANSLATION")
        left.model.rect = CGRect(x: 20, y: 300, width: 160, height: 50)
        let right = annotation("RIGHTCARDTRANSLATION")
        right.model.rect = CGRect(x: 210, y: 300, width: 160, height: 50)
        let output = try await export([right, left], source: source)
        let pageBox = try #require(output.page(at: 0)?.bounds(for: .mediaBox))
        #expect(pageBox.width == 400 + PDFExporter.sidebarWidth)
        #expect(pageBox.height == 500)
        #expect(left.bounds.minX > 400)
        #expect(right.bounds.minX > 400)
        #expect(!left.bounds.intersects(right.bounds))
        // The fallback renderer may wrap long Latin words once it grows the font toward the
        // comfort size, so compare without extracted line breaks.
        let text = try #require(output.string).replacingOccurrences(of: "\n", with: "")
        #expect(text.contains("ORIGINAL_CONTENT"))
        #expect(text.contains("LEFTCARDTRANSLATION"))
        #expect(text.contains("RIGHTCARDTRANSLATION"))
    }

    @Test func denseCardsExportInsideTheOriginalPageHeight() async throws {
        let notes = (0..<16).map { index -> TranslationAnnotation in
            let note = annotation("DENSECARD\(index)")
            note.model.rect = CGRect(
                x: CGFloat(20 + (index * 37) % 300),
                y: CGFloat(40 + (index * 53) % 380),
                width: 160,
                height: 24
            )
            return note
        }
        let output = try await export(notes)
        let pageBox = try #require(output.page(at: 0)?.bounds(for: .mediaBox))
        #expect(pageBox == CGRect(x: 0, y: 0, width: 400 + PDFExporter.sidebarWidth, height: 500))
        let top = 500 - CardSidebarLayout.pageVerticalInset
        let bottom = CardSidebarLayout.pageVerticalInset
        for note in notes {
            #expect(note.bounds.minX >= 400)
            #expect(note.bounds.maxX <= 400 + PDFExporter.sidebarWidth)
            #expect(note.bounds.minY >= bottom - 0.001)
            #expect(note.bounds.maxY <= top + 0.001)
        }
        for i in 0..<notes.count {
            for j in (i + 1)..<notes.count {
                #expect(!notes[i].bounds.intersects(notes[j].bounds))
            }
        }
    }

    @Test @MainActor func exportReportsPageProgress() async throws {
        let source = PDFDocument(data: pdf(["PAGE_ONE", "PAGE_TWO", "PAGE_THREE"]))!
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        var completed: [Int] = []
        var totals: [Int] = []
        try await PDFExporter.export(
            document: source,
            overlays: [],
            to: url,
            progress: { done, total in
                completed.append(done)
                totals.append(total)
            }
        )
        #expect(completed == [1, 2, 3])
        #expect(totals == [3, 3, 3])
        #expect(PDFDocument(url: url)?.pageCount == 3)
    }

    @Test @MainActor func exportCanBeCancelledBetweenPages() async throws {
        let source = PDFDocument(data: pdf(["PAGE_ONE", "PAGE_TWO"]))!
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        var exportedPages = 0
        var cancel = false
        do {
            try await PDFExporter.export(
                document: source,
                overlays: [],
                to: url,
                progress: { _, _ in
                    exportedPages += 1
                    cancel = true
                },
                isCancelled: { cancel }
            )
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            #expect(exportedPages == 1)
        }
    }
}
