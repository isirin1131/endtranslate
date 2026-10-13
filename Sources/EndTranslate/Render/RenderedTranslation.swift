import AppKit
import CoreGraphics

/// A single vector PDF, shared by the reader, editor preview, and PDF export.
final class RenderedTranslation: @unchecked Sendable {
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
    func draw(in rect: CGRect, context: CGContext, yDown: Bool = false) {
        guard let page = document.page(at: 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        let scale = rect.width / box.width
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
