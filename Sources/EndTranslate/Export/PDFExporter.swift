import PDFKit
import CoreGraphics

enum PDFExportError: LocalizedError {
    case cannotCreateContext(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext(let reason): return "无法创建导出文件：\(reason)"
        }
    }
}

/// Flattens the annotated view into a new PDF by drawing each original page and
/// then each translation block into a fresh CGPDFContext.
///
/// Deliberately avoids `PDFDocument.write(to:)`: the appearance streams PDFKit
/// generates for annotations containing nested PDF pages come back with
/// corrupted glyph encodings, while drawing into our own context is exact.
enum PDFExporter {
    static func export(document: PDFDocument, overlays: [TranslationAnnotation], to url: URL) throws {
        var byPage: [Int: [TranslationAnnotation]] = [:]
        for overlay in overlays where overlay.status == .done && !overlay.showsOriginal {
            byPage[overlay.model.page, default: []].append(overlay)
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: &mediaBox,
                  [kCGPDFContextCreator: "EndTranslate"] as CFDictionary
              ) else {
            throw PDFExportError.cannotCreateContext(url.path)
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            let ours = byPage[index] ?? []

            // kCGPDFContextMediaBox only honors a CFData of raw CGRect bytes; a bare
            // CGRect (or its dictionary representation) is silently ignored and the
            // page falls back to the context default size.
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            // draw(with:to:) puts the box origin at (0,0); shift back so page coordinates
            // (and the translation rects) line up when the media box doesn't start at 0.
            context.saveGState()
            context.translateBy(x: pageBox.minX, y: pageBox.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            for overlay in ours { draw(overlay, in: context) }
            context.endPDFPage()
        }
        context.closePDF()
        Log.write("exported \(document.pageCount) page(s) to \(url.lastPathComponent)")
    }

    /// Same look as on screen: faint tint, translation, and a left accent rule.
    private static func draw(_ overlay: TranslationAnnotation, in context: CGContext) {
        let rect = overlay.bounds
        context.saveGState()
        context.setFillColor(CGColor(red: 0.955, green: 0.965, blue: 1, alpha: 1))
        context.fill(rect)
        if let rendered = overlay.rendered {
            rendered.draw(in: rect, context: context)
        } else {
            let text = overlay.fallbackText ?? MarkdownText.plainText(overlay.model.translationMd)
            TranslationAnnotation.drawText(text, color: .black, in: rect.insetBy(dx: 3, dy: 3), context: context)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 0.55))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height))
        context.restoreGState()
    }
}
