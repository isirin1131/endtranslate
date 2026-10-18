import AppKit
import CoreText

/// Shared visual constants for floating sidebar cards, so screen and PDF export stay
/// identical while the chrome can be tuned in one place.
enum SidebarCardStyle {
    static let cornerRadius: CGFloat = 10
    static let accentBarWidth: CGFloat = 3
    static let accentBarInset: CGFloat = 9

    /// Rounded accent capsule inset from the card's top and bottom edges.
    static func accentBar(in cardRect: CGRect) -> CGRect {
        let inset = min(accentBarInset, cardRect.height * 0.28)
        return CGRect(
            x: cardRect.minX + 1.5,
            y: cardRect.minY + inset,
            width: accentBarWidth,
            height: max(cardRect.height - inset * 2, 0)
        )
    }
}

final class TranslationAnnotation {
    enum Status: Equatable {
        case loading
        case done
        case failed(String)
    }

    var model: Annotation { didSet { bumpLayoutRevision() } }
    /// Most recently placed card frame in overlay/export coordinates.
    var bounds: CGRect = .zero
    var status: Status = .loading { didSet { bumpLayoutRevision() } }
    var rendered: RenderedTranslation? { didSet { bumpLayoutRevision() } }
    /// Plain-text fallback while vector typesetting is unavailable.
    var fallbackText: String? { didSet { bumpLayoutRevision() } }

    /// Layout metrics are recomputed on every overlay pass (scroll, resize, hover). The
    /// viewport layout asks for them once per annotation per frame, and measuring fallback
    /// text with CoreText is expensive, so cache the result until the content changes.
    private var layoutRevision: UInt64 = 0
    private var cachedMetrics: (revision: UInt64, maxCardWidth: CGFloat, metrics: LayoutMetrics)?

    private func bumpLayoutRevision() {
        layoutRevision &+= 1
    }

    static let cardInsetX: CGFloat = 9
    static let cardInsetY: CGFloat = 7
    static let minInnerWidth: CGFloat = 26
    static let minCardWidth: CGFloat = minInnerWidth + 2 * cardInsetX
    static let defaultRenderWidth: CGFloat = 290
    /// Base font used when typesetting Markdown/LaTeX into the card's vector PDF.
    /// Rendering at 13pt (instead of 10pt) keeps text readable once the vector is
    /// width-limited inside a narrow or multi-column card.
    static let renderFontSize: CGFloat = 13

    init(model: Annotation) {
        self.model = model
    }

    /// Text shown when there is no rendered translation to draw.
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

    /// Skeleton height while waiting: a guess at the translation's height.
    static func loadingHeight(for rect: CGRect) -> CGFloat {
        min(max(rect.height * 0.6, 20), 96)
    }

    /// Content rectangle inside a floating card frame.
    static func contentRect(for cardRect: CGRect) -> CGRect {
        cardRect.insetBy(
            dx: min(cardInsetX, max(cardRect.width * 0.25, 0)),
            dy: min(cardInsetY, max(cardRect.height * 0.25, 0))
        )
    }

    private static func textMetrics(for markdown: String) -> (totalUnits: CGFloat, maxLineUnits: CGFloat, lineCount: Int, hasBlockStructure: Bool) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, 0, 0, false) }
        let hasBlock = trimmed.contains("$$")
            || trimmed.contains("\\[")
            || trimmed.contains("\\begin{")
            || trimmed.contains("\n|")
            || trimmed.hasPrefix("|")
        let plain = MarkdownText.plainText(trimmed)
        let rawLines = plain.components(separatedBy: .newlines)
        var totalUnits: CGFloat = 0
        var maxLineUnits: CGFloat = 0
        var nonEmptyLines = 0
        for line in rawLines {
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            nonEmptyLines += 1
            var lineUnits: CGFloat = 0
            for scalar in clean.unicodeScalars {
                if scalar.properties.isWhitespace {
                    lineUnits += 0.3
                } else if scalar.value >= 0x2E80 {
                    lineUnits += 1.0
                } else {
                    lineUnits += 0.52
                }
            }
            totalUnits += lineUnits
            maxLineUnits = max(maxLineUnits, lineUnits)
        }
        return (totalUnits, maxLineUnits, nonEmptyLines, hasBlock)
    }

    /// Estimated content volume in character units (CJK glyph = 1, ASCII glyph = 0.52).
    static func contentUnits(for markdown: String) -> CGFloat {
        textMetrics(for: markdown).totalUnits
    }

    /// Whether the translation is a full-width paragraph, table, or display equation that should span the sidebar.
    static func isFullWidthContent(_ markdown: String) -> Bool {
        let m = textMetrics(for: markdown)
        return m.hasBlockStructure || m.totalUnits > 42 || m.maxLineUnits > 22
    }

    /// Natural (base font size) card metrics plus the content classification used by the
    /// viewport layout solver.
    struct LayoutMetrics: Equatable {
        let naturalWidth: CGFloat
        let naturalHeight: CGFloat
        let contentUnits: CGFloat
        let isFullWidth: Bool
        let isCompactLabel: Bool
    }

    func layoutMetrics(maxCardWidth: CGFloat) -> LayoutMetrics {
        if let cached = cachedMetrics,
           cached.revision == layoutRevision,
           cached.maxCardWidth == maxCardWidth {
            return cached.metrics
        }
        let size = cardSize(maxCardWidth: maxCardWidth)
        let m = Self.textMetrics(for: displayText)
        let fullWidth = m.hasBlockStructure || m.totalUnits > 42
        let compact = size.height <= 28 || (m.totalUnits > 0 && m.totalUnits <= 18)
        let metrics = LayoutMetrics(
            naturalWidth: size.width,
            naturalHeight: size.height,
            contentUnits: m.totalUnits,
            isFullWidth: fullWidth,
            isCompactLabel: compact
        )
        cachedMetrics = (layoutRevision, maxCardWidth, metrics)
        return metrics
    }

    /// Chooses an adaptive maximum content width based on the translation's length and structure,
    /// so short labels and medium phrases stay compact and can arrange in 2D columns while long
    /// paragraphs, tables, and display equations use the full available sidebar width.
    static func preferredRenderWidth(for markdown: String, maxInnerWidth: CGFloat = defaultRenderWidth) -> CGFloat {
        let effectiveMax = max(maxInnerWidth, minInnerWidth)
        let m = textMetrics(for: markdown)
        guard m.totalUnits > 0 || m.hasBlockStructure else { return minInnerWidth }
        if m.hasBlockStructure || m.totalUnits > 38 || m.maxLineUnits > 22 {
            return effectiveMax
        }
        if m.totalUnits <= 18 {
            return min(effectiveMax, 195)
        }
        if m.lineCount >= 2 && m.maxLineUnits <= 18 {
            return min(effectiveMax, 210)
        }
        return min(effectiveMax, max(168, round(effectiveMax * 0.58)))
    }

    /// Adaptive outer card size (width and height) for the floating card within `maxCardWidth`.
    func cardSize(maxCardWidth: CGFloat) -> CGSize {
        let maxInnerWidth = max(maxCardWidth - 2 * Self.cardInsetX, Self.minInnerWidth)
        if status == .loading {
            let innerW = min(max(ceil(model.rect.width * 1.05), Self.minInnerWidth), maxInnerWidth)
            let innerH = Self.loadingHeight(for: model.rect)
            return CGSize(width: innerW + 2 * Self.cardInsetX, height: innerH + 2 * Self.cardInsetY)
        }
        if status == .done, let rendered {
            let innerW = min(max(ceil(rendered.size.width), Self.minInnerWidth), maxInnerWidth)
            let scale = innerW / max(rendered.size.width, 1)
            let innerH = max(ceil(rendered.size.height * scale), 14)
            return CGSize(width: innerW + 2 * Self.cardInsetX, height: innerH + 2 * Self.cardInsetY)
        }
        let targetMaxInner = Self.preferredRenderWidth(for: displayText, maxInnerWidth: maxInnerWidth)
        let measured = Self.measuredSize(text: displayText, maxWidth: targetMaxInner, fontSize: Self.renderFontSize)
        let innerW = min(max(measured.width + 6, Self.minInnerWidth), maxInnerWidth)
        let innerH = max(measured.height + 3, 16)
        return CGSize(width: innerW + 2 * Self.cardInsetX, height: innerH + 2 * Self.cardInsetY)
    }

    /// Required total height for the floating card in the sidebar at a given card width.
    func cardHeight(cardWidth: CGFloat) -> CGFloat {
        let innerWidth = max(cardWidth - 2 * Self.cardInsetX, Self.minInnerWidth)
        if status == .loading { return Self.loadingHeight(for: model.rect) + 2 * Self.cardInsetY }
        if status == .done, let rendered {
            let scaledHeight = ceil(rendered.size.height * (innerWidth / max(rendered.size.width, 1)))
            return max(scaledHeight, 14) + 2 * Self.cardInsetY
        }
        return max(Self.measuredHeight(text: displayText, width: innerWidth, fontSize: Self.renderFontSize) + 3, 16) + 2 * Self.cardInsetY
    }

    /// Tight bounding size with the fallback text renderer; used before vector typesetting is ready.
    static func measuredSize(text: String, maxWidth: CGFloat, fontSize: CGFloat) -> CGSize {
        let attrString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude), nil
        )
        return CGSize(width: ceil(fit.width), height: ceil(fit.height))
    }

    /// Height with the fallback text renderer; used before vector typesetting is ready.
    static func measuredHeight(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        measuredSize(text: text, maxWidth: width, fontSize: fontSize).height
    }

    /// CoreText draws in y-up coordinates. Screen overlays are y-down, whereas PDF
    /// exports are y-up. Layout stays in PDF points so the font tracks the page zoom.
    ///
    /// The fallback renderer searches `[5.5, 15.5]` for the largest font that fits both the
    /// available width and height (SPEC §4.2), then centers the block vertically so cards that
    /// grew or shrank in the sidebar still look balanced instead of top-clipped.
    static func drawText(_ text: String, color: NSColor, in rect: CGRect, context: CGContext,
                         yDown: Bool = false, scale: CGFloat = 1) {
        guard scale.isFinite, scale > 0,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }
        let logicalRect = CGRect(x: 0, y: 0, width: rect.width / scale, height: rect.height / scale)
        let minimumFont: CGFloat = 5.5
        let maximumFont: CGFloat = 15.5

        func measuredSize(at fontSize: CGFloat) -> CGSize {
            let attrString = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attrString)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil,
                CGSize(width: logicalRect.width, height: .greatestFiniteMagnitude), nil
            )
            guard fit.width <= logicalRect.width + 0.5 else {
                return CGSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
            }
            return fit
        }

        // Binary search the largest fitting size. When even 5.5pt overflows, keep 5.5pt and
        // let the card's clip path bound the overflow (identical to the previous behavior).
        var fontSize = minimumFont
        var fitSize = measuredSize(at: minimumFont)
        var low = minimumFont
        var high = maximumFont
        for _ in 0..<7 {
            let mid = (low + high) * 0.5
            let size = measuredSize(at: mid)
            if size.height <= logicalRect.height + 0.5 {
                fontSize = mid
                fitSize = size
                low = mid
            } else {
                high = mid
            }
        }

        let attrString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let fitHeight = fitSize.height.isFinite ? fitSize.height : 0
        let fitWidth = fitSize.width.isFinite ? fitSize.width : logicalRect.width
        let verticalOffset = max(0, (logicalRect.height - fitHeight) * 0.5)
        // A short single-line label centered in a stretched full-width row reads as an
        // intentional pill instead of a lonely word hugging the left accent bar.
        let horizontalOffset: CGFloat
        if fitWidth <= logicalRect.width * 0.75, fitHeight <= 28 {
            horizontalOffset = max(0, (logicalRect.width - fitWidth) * 0.5)
        } else {
            horizontalOffset = 0
        }

        context.saveGState()
        context.translateBy(x: rect.minX, y: yDown ? rect.maxY : rect.minY)
        context.scaleBy(x: scale, y: yDown ? -scale : scale)
        // Both coordinate systems draw the first line at the logical top; shifting the
        // logical origin down centers the laid-out block inside the expanded card.
        context.translateBy(x: horizontalOffset, y: -verticalOffset)
        context.textMatrix = .identity
        let path = CGPath(rect: logicalRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
