import AppKit
import CoreGraphics

/// A single vector PDF, shared by the reader, editor preview, and PDF export.
final class RenderedTranslation: @unchecked Sendable {
    /// Largest uniform scale used when fitting the vector into a card. With the 13pt
    /// base render font this caps the displayed text at roughly 16pt.
    static let maxContentScale: CGFloat = 1.25

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

    /// PDF and export contexts are y-up; the screen overlay is y-down.
    ///
    /// The card frame is resized by the viewport layout solver, so drawing must preserve the
    /// rendered page's aspect ratio: use the tighter of the width/height ratios, cap comfort
    /// enlargement at 1.45x, center vertically, and only center short labels horizontally.
    func draw(in rect: CGRect, context: CGContext, yDown: Bool = false) {
        guard let page = document.page(at: 1) else { return }
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        let scale = min(rect.width / box.width, rect.height / box.height, Self.maxContentScale)
        guard scale.isFinite, scale > 0 else { return }
        let drawWidth = box.width * scale
        let drawHeight = box.height * scale
        let yOffset = (rect.height - drawHeight) * 0.5
        let xOffset: CGFloat
        if box.width < rect.width * 0.75 && box.height < 28 {
            xOffset = (rect.width - drawWidth) * 0.5
        } else {
            xOffset = 0
        }

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
