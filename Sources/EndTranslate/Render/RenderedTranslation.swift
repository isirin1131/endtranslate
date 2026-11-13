import AppKit
import CoreGraphics

/// A single vector PDF, shared by the reader, editor preview, and PDF export.
final class RenderedTranslation: @unchecked Sendable {
    /// Largest uniform scale used when fitting the vector into a card. Capped at 1.0
    /// so short chips stay crisp at the native 13pt base font rather than blowing up.
    static let maxContentScale: CGFloat = 1.0

    let pdfData: Data
    let size: CGSize
    private let document: CGPDFDocument

    init?(pdfData: Data) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1,
              let page = document.page(at: 1) else { return nil }
        self.pdfData = pdfData
        self.document = document
        self.size = page.getBoxRect(.mediaBox).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
    }

    /// The maximum uniform scale that fits this vector inside the target rect, capped at `maxScale`.
    func fitScale(in rect: CGRect, maxScale: CGFloat = RenderedTranslation.maxContentScale) -> CGFloat {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return 1.0 }
        let scale = min(rect.width / size.width, rect.height / size.height, maxScale)
        return (scale.isFinite && scale > 0) ? scale : 1.0
    }

    /// PDF and export contexts are y-up; the screen overlay is y-down.
    ///
    /// Preserves aspect ratio, vertically centers within the card, and aligns to the left
    /// edge so the reading start point is consistent across single-line chips and paragraphs.
    func draw(
        in rect: CGRect,
        context: CGContext,
        yDown: Bool = false,
        scale preferred: CGFloat? = nil,
        maxScale: CGFloat = RenderedTranslation.maxContentScale
    ) {
        guard let page = document.page(at: 1) else { return }
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        let naturalScale = fitScale(in: rect, maxScale: maxScale)
        let scale = min(preferred ?? naturalScale, naturalScale)
        guard scale.isFinite, scale > 0 else { return }
        let drawHeight = box.height * scale
        let yOffset = (rect.height - drawHeight) * 0.5
        let xOffset: CGFloat = 0

        context.saveGState()
        context.clip(to: rect)
        if yDown {
            context.translateBy(x: rect.minX + xOffset, y: rect.minY + yOffset)
            context.scaleBy(x: 1, y: -1)
        } else {
            context.translateBy(x: rect.minX + xOffset, y: rect.maxY - yOffset)
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.maxY)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    func nsImage(scale: CGFloat = 2) -> NSImage? {
        let w = max(Int((size.width * scale).rounded()), 1)
        let h = max(Int((size.height * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = gc.cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale)
        draw(in: CGRect(origin: .zero, size: size), context: context)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
