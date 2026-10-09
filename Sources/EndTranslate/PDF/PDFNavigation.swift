import PDFKit

/// A destination stays in original page coordinates, independent of the PDFPage
/// instances that get replaced whenever translation slots are laid out.
struct PDFNavigationTarget: Equatable {
    let pageIndex: Int
    let point: CGPoint?

    init(pageIndex: Int, point: CGPoint? = nil) {
        self.pageIndex = pageIndex
        self.point = point
    }

    static func pageIndex(from text: String, pageCount: Int) -> Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              number >= 1, number <= pageCount else { return nil }
        return number - 1
    }

    func destination(in document: PDFDocument, layout: GapLayout, box: PDFDisplayBox = .cropBox) -> PDFDestination? {
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return nil }
        var originalBounds = page.bounds(for: box)
        originalBounds.size.height -= layout.totalHeight
        guard originalBounds.width > 0, originalBounds.height > 0 else { return nil }
        func coordinate(_ value: CGFloat?, fallback: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
            guard let value, value.isFinite, value != kPDFDestinationUnspecifiedValue else { return fallback }
            return min(max(value, lower), upper)
        }
        let x = coordinate(point?.x, fallback: originalBounds.minX, min: originalBounds.minX, max: originalBounds.maxX)
        let y = coordinate(point?.y, fallback: originalBounds.maxY, min: originalBounds.minY, max: originalBounds.maxY)
        let destination = PDFDestination(page: page, at: CGPoint(x: x, y: layout.expand(y)))
        destination.zoom = kPDFDestinationUnspecifiedValue
        return destination
    }
}

struct PDFOutlineEntry: Identifiable {
    let id: String
    let title: String
    let target: PDFNavigationTarget?
    let children: [PDFOutlineEntry]?

    static func read(from document: PDFDocument) -> [PDFOutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        func entries(in parent: PDFOutline, path: String) -> [PDFOutlineEntry] {
            (0..<parent.numberOfChildren).compactMap { index in
                guard let node = parent.child(at: index) else { return nil }
                let id = path + String(index)
                let title = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let destination = (node.action as? PDFActionGoTo)?.destination ?? node.destination
                var target: PDFNavigationTarget?
                if let destination, let page = destination.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound {
                        target = PDFNavigationTarget(pageIndex: pageIndex, point: destination.point)
                    }
                }
                let children = entries(in: node, path: id + ".")
                return PDFOutlineEntry(id: id, title: title.isEmpty ? "未命名章节" : title, target: target,
                                       children: children.isEmpty ? nil : children)
            }
        }
        return entries(in: root, path: "")
    }
}
