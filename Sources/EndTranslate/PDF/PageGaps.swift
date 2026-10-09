import PDFKit

/// A translation slot cut into a page right above a selection, in ORIGINAL page coordinates.
struct PageGap {
    let id: UUID
    let y: CGFloat
    let height: CGFloat
}

/// Maps between original page coordinates and the expanded page that has gaps inserted.
/// Content at or above a cut moves up by that gap's height; everything below stays put,
/// so the page origin (and all y below the lowest cut) is unchanged.
struct GapLayout {
    let gaps: [PageGap]

    static let empty = GapLayout([])

    init(_ gaps: [PageGap]) {
        self.gaps = gaps.filter { $0.height > 0 }.sorted {
            $0.y != $1.y ? $0.y < $1.y : $0.id.uuidString < $1.id.uuidString
        }
    }

    var totalHeight: CGFloat { gaps.reduce(0) { $0 + $1.height } }

    func expand(_ y: CGFloat) -> CGFloat {
        y + gaps.filter { $0.y <= y }.reduce(0) { $0 + $1.height }
    }

    /// Points inside a gap collapse onto that gap's cut line.
    func collapse(_ y: CGFloat) -> CGFloat {
        var acc: CGFloat = 0
        for gap in gaps {
            let bottom = gap.y + acc
            if y < bottom { break }
            if y < bottom + gap.height { return gap.y }
            acc += gap.height
        }
        return y - acc
    }

    /// The gap's vertical extent in expanded coordinates.
    func slot(for id: UUID) -> (minY: CGFloat, height: CGFloat)? {
        var acc: CGFloat = 0
        for gap in gaps {
            if gap.id == id { return (gap.y + acc, gap.height) }
            acc += gap.height
        }
        return nil
    }
}

enum PageGapper {
    /// Builds a replacement page: the original page is drawn as vector bands cut at each gap,
    /// bands above a cut shifted up, leaving blank slots for the translations.
    ///
    /// A PDFPage subclass overriding `draw(with:to:)` does not work here: PDFView's tiled
    /// display path honors the enlarged `bounds` but ignores the overridden drawing.
    static func build(from original: PDFPage, layout: GapLayout, box: PDFDisplayBox) -> (page: PDFPage, document: PDFDocument)? {
        let orig = original.bounds(for: box)
        var mediaBox = CGRect(x: orig.minX, y: orig.minY, width: orig.width, height: orig.height + layout.totalHeight)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        // Same quirk as the exporter: the media box must be raw CGRect bytes in a CFData.
        let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        let cuts = [orig.minY] + layout.gaps.map { min(max($0.y, orig.minY), orig.maxY) } + [orig.maxY]
        for i in 0..<cuts.count - 1 {
            let a = cuts[i], b = cuts[i + 1]
            guard b > a else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: layout.expand(a) - a)
            context.clip(to: CGRect(x: orig.minX, y: a, width: orig.width, height: b - a))
            // draw(with:to:) maps the box origin to (0,0); shift back so the new page
            // keeps the original coordinate space (annotation rects stay valid).
            context.translateBy(x: orig.minX, y: orig.minY)
            original.draw(with: box, to: context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else { return nil }
        return (page, doc)
    }
}
