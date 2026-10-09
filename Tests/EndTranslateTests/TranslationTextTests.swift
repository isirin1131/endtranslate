import Testing
import PDFKit
@testable import EndTranslate

@Suite(.serialized)
final class TranslationTextTests {
    private let pageSize = CGSize(width: 320, height: 180)
    private let textRect = CGRect(x: 19, y: 31, width: 270, height: 116)

    /// Rasterize the same PDF-point layout through the export and flipped-view paths.
    /// Matching at different zoom levels catches both mirrored glyphs and fixed-size text.
    private func raster(_ text: String, color: NSColor, zoom: CGFloat, screen: Bool) throws -> Data {
        let width = Int(pageSize.width * zoom)
        let height = Int(pageSize.height * zoom)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if screen {
            // NSView.isFlipped makes its origin the top left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: textRect.minX * zoom, y: (pageSize.height - textRect.maxY) * zoom,
                              width: textRect.width * zoom, height: textRect.height * zoom)
            TranslationAnnotation.drawText(text, color: color, in: rect, context: context,
                                           yDown: true, scale: zoom)
        } else {
            // A PDF page keeps a bottom-left origin; raster scale belongs to the context.
            context.scaleBy(x: zoom, y: zoom)
            TranslationAnnotation.drawText(text, color: color, in: textRect, context: context)
        }
        return Data(bytes: try #require(context.data), count: width * height * 4)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func errorTextHasTheSameOrientationAndSizeAsPDF(zoom: Double) throws {
        let error = LLMClient.LLMError.http(401, "")
        let text = "翻译失败：\(LLMClient.describe(error))\n点击重试"
        let reference = try raster(text, color: .systemRed, zoom: zoom, screen: false)
        let screen = try raster(text, color: .systemRed, zoom: zoom, screen: true)
        #expect(reference.contains { $0 < 200 })
        #expect(screen.elementsEqual(reference))
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func fallbackTextHasTheSameOrientationAndSizeAsPDF(zoom: Double) throws {
        let text = "第一行：中文译文 First line\n第二行：保留公式 E = mc²\nThird line: readable at every zoom."
        let reference = try raster(text, color: .black, zoom: zoom, screen: false)
        let screen = try raster(text, color: .black, zoom: zoom, screen: true)
        #expect(reference.contains { $0 < 200 })
        #expect(screen.elementsEqual(reference))
    }
}
