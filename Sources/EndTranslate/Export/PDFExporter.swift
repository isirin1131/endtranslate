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

/// Flattens the annotated view into a new PDF by keeping each original page intact on the left
/// and placing its floating translation cards in a right-hand sidebar column connected by leader lines.
///
/// Deliberately avoids `PDFDocument.write(to:)`: the appearance streams PDFKit
/// generates for annotations containing nested PDF pages come back with
/// corrupted glyph encodings, while drawing into our own context is exact.
enum PDFExporter {
    static let sidebarWidth: CGFloat = CardSidebarLayout.defaultSidebarWidth

    /// Exports one page at a time and yields between pages so the reader can show progress and
    /// cancel. PDFKit is kept on the main actor; jumping to a background executor would race
    /// the live PDFView and its document. Callers that need to abandon a partial file should
    /// write to a temporary URL and remove it after `CancellationError`.
    @MainActor
    static func export(
        document: PDFDocument,
        overlays: [TranslationAnnotation],
        to url: URL,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) async throws {
        let pageCount = document.pageCount
        var byPage: [Int: [TranslationAnnotation]] = [:]
        for overlay in overlays where overlay.status == .done {
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

        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }
            guard let page = document.page(at: index) else { continue }
            let pageBox = page.bounds(for: .mediaBox)
            let ours = byPage[index] ?? []

            let cardX = pageBox.maxX + CardSidebarLayout.cardHorizontalInset
            let cardWidth = sidebarWidth - CardSidebarLayout.cardHorizontalInset * 2
            let specs = ours.map { overlay in
                let metrics = overlay.layoutMetrics(maxCardWidth: cardWidth)
                return SidebarCardSpec(
                    id: overlay.model.id,
                    page: index,
                    sourceRect: overlay.model.rect,
                    desiredY: overlay.model.rect.maxY,
                    preferredWidth: metrics.naturalWidth,
                    height: metrics.naturalHeight,
                    pageMinY: pageBox.minY,
                    pageMaxY: pageBox.maxY,
                    isFullWidth: metrics.isFullWidth,
                    contentUnits: metrics.contentUnits
                )
            }
            let layout = CardSidebarLayout.placeExportCards(
                specs,
                cardX: cardX,
                cardWidth: cardWidth,
                pageBounds: pageBox
            )
            let byID = Dictionary(uniqueKeysWithValues: ours.map { ($0.model.id, $0) })

            // The solver guarantees that every card fits inside the page viewport, so the
            // exported page height never grows (SPEC §5). Only the sidebar widens the box.
            var exportBox = ours.isEmpty
                ? pageBox
                : CGRect(
                    x: pageBox.minX,
                    y: pageBox.minY,
                    width: pageBox.width + sidebarWidth,
                    height: pageBox.height
                )

            // kCGPDFContextMediaBox only honors a CFData of raw CGRect bytes; a bare
            // CGRect (or its dictionary representation) is silently ignored and the
            // page falls back to the context default size.
            let boxData = Data(bytes: &exportBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            // draw(with:to:) puts the box origin at (0,0); shift back so page coordinates
            // (and the source highlight rects) line up when the media box doesn't start at 0.
            context.saveGState()
            context.translateBy(x: pageBox.minX, y: pageBox.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            if !ours.isEmpty {
                drawSidebarBackdrop(pageBox: pageBox, exportBox: exportBox, in: context)
                for placed in layout.cards {
                    guard let overlay = byID[placed.id] else { continue }
                    overlay.bounds = placed.frame
                    drawSourceHighlight(overlay.model.rect, in: context)
                    drawConnector(sourceRect: overlay.model.rect, cardRect: placed.frame, pageBox: pageBox, in: context)
                }
                for placed in layout.cards {
                    guard let overlay = byID[placed.id] else { continue }
                    drawCard(overlay, in: placed.frame, context: context)
                }
                for placed in layout.cards {
                    guard let overlay = byID[placed.id] else { continue }
                    drawConnectorEndpoints(sourceRect: overlay.model.rect, cardRect: placed.frame,
                                           pageBox: pageBox, in: context)
                }
            }
            context.endPDFPage()
            progress?(index + 1, pageCount)
            await Task.yield()
        }
        try Task.checkCancellation()
        guard !isCancelled() else { throw CancellationError() }
        context.closePDF()
        Log.write("exported \(pageCount) page(s) to \(url.lastPathComponent)")
    }

    private static func drawSidebarBackdrop(pageBox: CGRect, exportBox: CGRect, in context: CGContext) {
        let sidebarRect = CGRect(
            x: pageBox.maxX,
            y: exportBox.minY,
            width: exportBox.maxX - pageBox.maxX,
            height: exportBox.height
        )
        context.saveGState()
        context.setFillColor(ReaderTheme.printSidebar.cgColor)
        context.fill(sidebarRect)
        context.setFillColor(ReaderTheme.printDivider.cgColor)
        context.fill(CGRect(x: pageBox.maxX, y: exportBox.minY, width: 0.75, height: exportBox.height))
        context.restoreGState()
    }

    private static func drawSourceHighlight(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(3, rect.width * 0.25),
            cornerHeight: min(3, rect.height * 0.25),
            transform: nil
        )
        context.setFillColor(ReaderTheme.sourceFill.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(ReaderTheme.sourceStroke.cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawConnector(sourceRect: CGRect, cardRect: CGRect, pageBox: CGRect, in context: CGContext) {
        let connector = CardConnector(
            sourceRect: sourceRect,
            cardRect: cardRect,
            minSourceX: pageBox.minX + 4,
            maxSourceX: pageBox.maxX - 4
        )
        context.saveGState()
        context.setStrokeColor(ReaderTheme.printConnector.cgColor)
        context.setLineWidth(1.0)
        context.setLineCap(.round)
        connector.addPath(to: context)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawConnectorEndpoints(sourceRect: CGRect, cardRect: CGRect,
                                               pageBox: CGRect, in context: CGContext) {
        let connector = CardConnector(
            sourceRect: sourceRect,
            cardRect: cardRect,
            minSourceX: pageBox.minX + 4,
            maxSourceX: pageBox.maxX - 4
        )
        let radius: CGFloat = 1.8
        context.saveGState()
        context.setFillColor(ReaderTheme.inkAccent.withAlphaComponent(0.62).cgColor)
        for point in [connector.start, connector.end] {
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                           width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    private static func drawCard(_ overlay: TranslationAnnotation, in cardRect: CGRect, context: CGContext) {
        context.saveGState()
        let radius = min(SidebarCardStyle.cornerRadius,
                         min(cardRect.width, cardRect.height) * 0.35)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setFillColor(ReaderTheme.cardPaper.cgColor)
        context.addPath(cardPath)
        context.fillPath()

        context.saveGState()
        ctxClipAndDrawContent(overlay, cardRect: cardRect, cardPath: cardPath, context: context)
        context.restoreGState()

        context.setStrokeColor(ReaderTheme.printCardBorder.cgColor)
        context.setLineWidth(0.8)
        context.addPath(cardPath)
        context.strokePath()
        context.restoreGState()
    }

    private static func ctxClipAndDrawContent(
        _ overlay: TranslationAnnotation,
        cardRect: CGRect,
        cardPath: CGPath,
        context: CGContext
    ) {
        context.addPath(cardPath)
        context.clip()

        let contentRect = TranslationAnnotation.contentRect(for: cardRect)
        let maxInnerWidth = max(
            sidebarWidth - 2 * CardSidebarLayout.cardHorizontalInset - 2 * TranslationAnnotation.cardInsetX,
            TranslationAnnotation.minInnerWidth
        )
        let textScale = min(max(maxInnerWidth / TranslationAnnotation.defaultRenderWidth, 0.5), 1.0)
        if let rendered = overlay.rendered {
            rendered.draw(in: contentRect, context: context)
        } else {
            let text = overlay.fallbackText ?? MarkdownText.plainText(overlay.model.translationMd)
            TranslationAnnotation.drawText(text, color: .black, in: contentRect, context: context, scale: textScale)
        }
        let accentBar = SidebarCardStyle.accentBar(in: cardRect)
        let accentRadius = accentBar.width * 0.5
        context.setFillColor(ReaderTheme.inkAccent.withAlphaComponent(0.65).cgColor)
        context.addPath(CGPath(roundedRect: accentBar, cornerWidth: accentRadius,
                               cornerHeight: accentRadius, transform: nil))
        context.fillPath()
    }
}
