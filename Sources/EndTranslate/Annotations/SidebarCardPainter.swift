import AppKit
import CoreGraphics

/// Shared painter for floating sidebar cards across screen overlay, PDF export,
/// and snapshot tests.
enum SidebarCardPainter {
    struct State {
        var isHovered: Bool = false
        var isDimmed: Bool = false
        var isFailed: Bool = false
        var isPrint: Bool = false
    }

    /// Computes a harmonious shared font scale across a group of visible cards.
    ///
    /// By picking a quantized shared scale (down to 0.05), chips and paragraphs in the same
    /// viewport share the same typography instead of jumping between 5 different font sizes.
    static func sharedScale(for cards: [(RenderedTranslation, CGRect)]) -> CGFloat {
        guard !cards.isEmpty else { return 1.0 }
        let scales = cards.map { rendered, rect in
            rendered.fitScale(in: TranslationAnnotation.contentRect(for: rect))
        }.sorted()
        guard !scales.isEmpty else { return 1.0 }
        let median = scales[scales.count / 2]
        let floor = scales.first { $0 >= 0.8 } ?? median
        return max(min((floor * 20).rounded(.down) / 20, 1.0), 0.5)
    }

    /// Draws a complete translation card into `cardRect`.
    static func draw(
        _ note: TranslationAnnotation,
        in cardRect: CGRect,
        scale: CGFloat = 1.0,
        state: State,
        phase: TimeInterval = 0,
        context ctx: CGContext,
        yDown: Bool = false
    ) {
        ctx.saveGState()
        let cornerRadius = min(
            SidebarCardStyle.cornerRadius,
            min(cardRect.width, cardRect.height) * 0.35
        )
        let cardPath = CGPath(
            roundedRect: cardRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        if state.isDimmed {
            ctx.setAlpha(0.55)
        }

        // Floating card shadow (omitted in print/export).
        if !state.isPrint {
            ctx.saveGState()
            let shadowY = yDown ? (state.isHovered ? 4.0 : 1.5) : (state.isHovered ? -4.0 : -1.5)
            let shadowBlur: CGFloat = state.isHovered ? 16 : 6
            ctx.setShadow(
                offset: CGSize(width: 0, height: shadowY),
                blur: shadowBlur,
                color: ReaderTheme.cardShadow.cgColor
            )
            ctx.setFillColor(ReaderTheme.cardPaper.cgColor)
            ctx.addPath(cardPath)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(ReaderTheme.cardPaper.cgColor)
            ctx.addPath(cardPath)
            ctx.fillPath()
        }

        // Inner content
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        let contentRect = TranslationAnnotation.contentRect(for: cardRect)
        switch note.status {
        case .loading:
            drawSkeleton(in: contentRect, phase: phase, context: ctx, yDown: yDown)
        case .done:
            if let rendered = note.rendered {
                let maxScale = state.isPrint
                    ? RenderedTranslation.maxContentScale
                    : max(RenderedTranslation.maxContentScale, scale)
                rendered.draw(
                    in: contentRect,
                    context: ctx,
                    yDown: yDown,
                    scale: scale,
                    maxScale: maxScale
                )
            } else {
                TranslationAnnotation.drawText(
                    note.displayText,
                    color: .black,
                    in: contentRect,
                    context: ctx,
                    yDown: yDown,
                    scale: scale
                )
            }
        case .failed:
            TranslationAnnotation.drawText(
                note.displayText,
                color: ReaderTheme.inkError,
                in: contentRect,
                context: ctx,
                yDown: yDown,
                scale: scale
            )
        }

        // Accent capsule: shown only on hover for taller cards (height >= 44).
        // Quiet cards stay minimal and free of heavy left stripes.
        if state.isHovered && cardRect.height >= SidebarCardStyle.accentBarMinHeight {
            let accentBar = SidebarCardStyle.accentBar(in: cardRect)
            let accentRadius = accentBar.width * 0.5
            let ruleColor = state.isFailed ? ReaderTheme.inkError : ReaderTheme.inkAccent
            ctx.setFillColor(ruleColor.withAlphaComponent(0.95).cgColor)
            ctx.addPath(CGPath(
                roundedRect: accentBar,
                cornerWidth: accentRadius,
                cornerHeight: accentRadius,
                transform: nil
            ))
            ctx.fillPath()
        }
        ctx.restoreGState()

        // Card border
        if state.isPrint {
            ctx.setStrokeColor(ReaderTheme.printCardBorder.cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(cardPath)
            ctx.strokePath()
        } else if state.isHovered {
            let strokeColor = state.isFailed ? ReaderTheme.chromeError : ReaderTheme.chromeAccent
            ctx.setStrokeColor(strokeColor.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(cardPath)
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(ReaderTheme.cardStroke.cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(cardPath)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    struct HoverLayout: Equatable {
        let frame: CGRect
        let scale: CGFloat
    }

    /// Computes the magnified frame and typography scale for a hovered sidebar card.
    ///
    /// Handles dense-viewport compressed cards, narrow sidebars (floating gently across
    /// the divider when needed), `.failed`/fallback plain text, and viewport edge clamping.
    static func hoverLayout(
        for note: TranslationAnnotation,
        baseRect: CGRect,
        baseScale: CGFloat,
        sidebarRect: CGRect,
        viewportBounds: CGRect,
        progress: CGFloat = 1.0,
        zoomFactor: CGFloat = 1.22
    ) -> HoverLayout {
        hoverLayout(
            contentSize: note.rendered?.size,
            fallbackText: note.rendered == nil ? note.displayText : nil,
            isLoading: note.isLoading,
            baseRect: baseRect,
            baseScale: baseScale,
            sidebarRect: sidebarRect,
            viewportBounds: viewportBounds,
            progress: progress,
            zoomFactor: zoomFactor
        )
    }

    /// Pure geometry solver for hover magnification, directly testable without a `PDFView`.
    static func hoverLayout(
        contentSize: CGSize?,
        fallbackText: String?,
        isLoading: Bool,
        baseRect: CGRect,
        baseScale: CGFloat,
        sidebarRect: CGRect,
        viewportBounds: CGRect,
        progress: CGFloat = 1.0,
        zoomFactor: CGFloat = 1.22
    ) -> HoverLayout {
        let safeBaseScale = (baseScale.isFinite && baseScale > 0) ? baseScale : 1.0
        guard !isLoading,
              !baseRect.isEmpty,
              !viewportBounds.isEmpty,
              baseRect.minX.isFinite, baseRect.minY.isFinite,
              baseRect.width.isFinite, baseRect.height.isFinite else {
            return HoverLayout(frame: baseRect, scale: safeBaseScale)
        }
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else {
            return HoverLayout(frame: baseRect, scale: safeBaseScale)
        }

        let padding: CGFloat = 12
        let safeViewport = viewportBounds.insetBy(
            dx: min(padding, viewportBounds.width * 0.1),
            dy: min(padding, viewportBounds.height * 0.1)
        )
        guard safeViewport.width > 0, safeViewport.height > 0 else {
            return HoverLayout(frame: baseRect, scale: safeBaseScale)
        }

        let insetX = TranslationAnnotation.cardInsetX * 2
        let insetY = TranslationAnnotation.cardInsetY * 2
        let maxTargetWidth = min(
            safeViewport.width,
            max(baseRect.width, max(sidebarRect.width + 120, 420))
        )
        let maxTargetHeight = safeViewport.height

        let targetScale: CGFloat
        let targetW: CGFloat
        let targetH: CGFloat

        if let contentSize, contentSize.width > 0, contentSize.height > 0 {
            let desiredScale = min(max(safeBaseScale * zoomFactor, 1.18), 1.28)
            let availContentW = max(maxTargetWidth - insetX, 1)
            let availContentH = max(maxTargetHeight - insetY, 1)
            let maxFitScale = min(availContentW / contentSize.width, availContentH / contentSize.height)
            targetScale = min(desiredScale, max(maxFitScale, min(safeBaseScale, maxFitScale)))
            let idealW = ceil(contentSize.width * targetScale + insetX)
            let idealH = ceil(contentSize.height * targetScale + insetY)
            targetW = min(max(baseRect.width, idealW), maxTargetWidth)
            targetH = min(max(baseRect.height, idealH), maxTargetHeight)
        } else {
            let desiredScale = min(max(safeBaseScale * 1.15, 1.15), 1.24)
            let maxLogicalW = max(120, min(maxTargetWidth - insetX, max(baseRect.width - insetX, 300)))
            let textSize = fallbackText.map {
                TranslationAnnotation.measuredSize(text: $0, maxWidth: maxLogicalW, fontSize: 13.5)
            } ?? .zero
            let rawW = max(baseRect.width, ceil(textSize.width * desiredScale + insetX))
            let rawH = max(baseRect.height, ceil(textSize.height * desiredScale + insetY))
            targetW = min(rawW, maxTargetWidth)
            targetH = min(rawH, maxTargetHeight)
            targetScale = desiredScale
        }

        // Keep narrow chips anchored on their left edge near the connector; push leftward across
        // the divider only when expanding past the right sidebar margin.
        let rightMargin = max(0, CardSidebarLayout.cardHorizontalInset - 4)
        let sidebarRightLimit = min(
            safeViewport.maxX,
            max(baseRect.maxX, sidebarRect.maxX - rightMargin)
        )
        var targetX = baseRect.minX
        if targetX + targetW > sidebarRightLimit {
            targetX = sidebarRightLimit - targetW
        }
        targetX = max(safeViewport.minX, min(targetX, safeViewport.maxX - targetW))

        var targetY = (baseRect.midY - targetH * 0.5).rounded()
        targetY = min(max(targetY, safeViewport.minY), safeViewport.maxY - targetH)

        let targetFrame = CGRect(x: targetX, y: targetY, width: targetW, height: targetH)
        let t = 1 - pow(1 - clampedProgress, 3)
        let frame = CGRect(
            x: baseRect.minX + (targetFrame.minX - baseRect.minX) * t,
            y: baseRect.minY + (targetFrame.minY - baseRect.minY) * t,
            width: baseRect.width + (targetFrame.width - baseRect.width) * t,
            height: baseRect.height + (targetFrame.height - baseRect.height) * t
        )
        let scale = safeBaseScale + (targetScale - safeBaseScale) * t
        return HoverLayout(frame: frame, scale: scale)
    }

    /// Placeholder skeleton lines with a soft sweep.
    static func drawSkeleton(
        in rect: CGRect,
        phase: TimeInterval,
        context ctx: CGContext,
        yDown: Bool = true
    ) {
        let lineHeight: CGFloat = 5
        let spacing: CGFloat = 7
        let inset = CGPoint(x: 4, y: 4)
        let widths: [CGFloat] = [0.92, 0.84, 0.88, 0.58]
        var y = yDown ? (rect.minY + inset.y) : (rect.maxY - inset.y - lineHeight)
        var i = 0
        let available = rect.width - inset.x * 2
        guard available > 4 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let endCondition: () -> Bool = {
            yDown
                ? (y + lineHeight <= rect.maxY - inset.y + 0.5)
                : (y >= rect.minY + inset.y - 0.5)
        }
        while endCondition() {
            let fraction = widths[i % widths.count]
            let bar = CGRect(x: rect.minX + inset.x, y: y, width: available * fraction, height: lineHeight)
            let wave = 0.5 + 0.5 * sin(phase * 3.2 - Double(i) * 0.6)
            ctx.setFillColor(ReaderTheme.skeleton.withAlphaComponent(0.08 + 0.08 * wave).cgColor)
            let radius = lineHeight / 2
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            y += yDown ? (lineHeight + spacing) : -(lineHeight + spacing)
            i += 1
        }
        ctx.restoreGState()
    }
}

/// Shared painter for source paragraph highlights on the PDF page.
enum SourceHighlightPainter {
    struct State {
        var isHovered: Bool = false
        var anyHovered: Bool = false
        var isFailed: Bool = false
        var isPrint: Bool = false
    }

    static func draw(_ sourceRect: CGRect, state: State, in ctx: CGContext) {
        ctx.saveGState()
        let rounded = CGPath(
            roundedRect: sourceRect,
            cornerWidth: min(3, sourceRect.width * 0.25),
            cornerHeight: min(3, sourceRect.height * 0.25),
            transform: nil
        )
        let color: NSColor = state.isFailed ? ReaderTheme.inkError : ReaderTheme.inkAccent

        let fill: NSColor
        if state.isFailed {
            fill = state.isHovered ? color.withAlphaComponent(0.10) : color.withAlphaComponent(0.05)
        } else if state.isHovered {
            fill = color.withAlphaComponent(0.08)
        } else if state.anyHovered {
            fill = color.withAlphaComponent(0.02)
        } else {
            fill = color.withAlphaComponent(0.04)
        }

        ctx.setFillColor(fill.cgColor)
        ctx.addPath(rounded)
        ctx.fillPath()

        // Crisp border only when hovered. Quiet state has NO border, eliminating double-line clutter.
        if state.isHovered {
            ctx.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(rounded)
            ctx.strokePath()
        }

        // Anchor dot on the right edge (screen overlay only)
        if !state.isPrint {
            let dotRadius = state.isHovered
                ? ConnectorStyle.sourceAnchorHoverRadius
                : ConnectorStyle.sourceAnchorRadius
            let dot = CGPoint(x: sourceRect.maxX, y: sourceRect.midY)
            let alpha: CGFloat = state.isHovered ? 0.95 : (state.anyHovered ? 0.25 : 0.55)
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: dot.x - dotRadius,
                y: dot.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }

        ctx.restoreGState()
    }
}
