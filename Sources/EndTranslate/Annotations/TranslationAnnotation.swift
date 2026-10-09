import PDFKit
import CoreText

final class TranslationAnnotation: PDFAnnotation {
    enum Status: Equatable {
        case loading
        case done
        case failed(String)
    }

    var model: Annotation
    var status: Status = .loading
    /// Collapses the gap to a thin handle so the page reads like the original.
    var showsOriginal = false
    var rendered: RenderedDoc?
    /// Plain-text fallback when typst fails.
    var fallbackText: String?

    static let margin: CGFloat = 3
    static let collapsedHeight: CGFloat = 6

    init(model: Annotation) {
        self.model = model
        super.init(bounds: .zero, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func refresh() {
        SelectionOverlay.requestInvalidate()
    }

    /// Text shown when there is no typst page to draw.
    var displayText: String {
        switch status {
        case .loading: return "翻译中…"
        case .failed(let message): return "翻译失败：\(message)\n点击重试"
        case .done: return fallbackText ?? model.translationMd
        }
    }

    var isLoading: Bool { status == .loading }
    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    func boxWidth(pageWidth: CGFloat) -> CGFloat {
        let width = rendered.map { $0.size.width } ?? max(model.rect.width, 140)
        return min(width, pageWidth - 4)
    }

    /// Skeleton height while waiting: a guess at the translation's height so the page
    /// moves as little as possible when the real result replaces it.
    static func loadingHeight(for rect: CGRect) -> CGFloat {
        min(max(rect.height * 0.6, 22), 120)
    }

    /// Height of the slot this annotation needs cut into the page.
    func gapHeight(pageWidth: CGFloat) -> CGFloat {
        if showsOriginal { return Self.collapsedHeight }
        if status == .loading { return Self.loadingHeight(for: model.rect) + 2 * Self.margin }
        if status == .done, let rendered { return rendered.size.height + 2 * Self.margin }
        let width = boxWidth(pageWidth: pageWidth) - 6
        return max(Self.measuredHeight(text: displayText, width: width, fontSize: 10) + 6, 16) + 2 * Self.margin
    }

    /// Positions the box inside its slot (expanded page coordinates).
    func place(slotMinY: CGFloat, slotHeight: CGFloat, pageBounds: CGRect) {
        let width = boxWidth(pageWidth: pageBounds.width)
        var x = model.rect.minX
        if x + width > pageBounds.maxX - 2 { x = pageBounds.maxX - 2 - width }
        x = max(x, pageBounds.minX + 2)
        if showsOriginal {
            bounds = CGRect(x: x, y: slotMinY, width: width, height: slotHeight)
        } else {
            bounds = CGRect(x: x, y: slotMinY + Self.margin, width: width,
                            height: max(slotHeight - 2 * Self.margin, 1))
        }
    }

    /// Height with the fallback text renderer; used before the typst page is ready.
    static func measuredHeight(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let attrString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return ceil(fit.height)
    }

    static func drawText(_ text: String, color: NSColor, in rect: CGRect, context: CGContext) {
        var fontSize: CGFloat = 10
        var framesetter: CTFramesetter
        var fitHeight: CGFloat = 0
        while true {
            let attrString = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color
            ])
            framesetter = CTFramesetterCreateWithAttributedString(attrString)
            fitHeight = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil
            ).height
            if fitHeight <= rect.height || fontSize <= 5 { break }
            fontSize -= 0.5
        }
        context.saveGState()
        context.textMatrix = .identity
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
