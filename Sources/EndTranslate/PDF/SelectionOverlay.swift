import AppKit
import PDFKit

/// Viewport-fixed layer above the PDFView. It paints the translation boxes itself
/// (vector, at device resolution) instead of relying on PDFAnnotation drawing, and
/// owns box-selection with a page-space anchor plus edge auto-scroll.
final class SelectionOverlay: NSView {
    /// Page index + selection rect in ORIGINAL page coordinates (gaps removed).
    /// Returns false to keep the selection pending (e.g. translation not configured yet).
    var onSelection: ((Int, CGRect) -> Bool)?
    var onClickAnnotation: ((TranslationAnnotation) -> Void)?
    var onEditAnnotation: ((TranslationAnnotation) -> Void)?
    var onDeleteAnnotation: ((TranslationAnnotation) -> Void)?
    var onRetranslateAnnotation: ((TranslationAnnotation) -> Void)?
    var onCopyAnnotation: ((TranslationAnnotation) -> Void)?
    var onToggleOriginal: ((TranslationAnnotation) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    /// Scroll / zoom / resize: lets the model remember the reading position.
    var onViewportChange: (() -> Void)?
    weak var store: AnnotationStore?

    private weak var pdfView: PDFView?
    /// Runs only while something moves on its own: a drag (edge auto-scroll), a loading
    /// skeleton, or briefly after a viewport change. Idle reading costs no wakeups.
    private var animationTimer: Timer?
    private var settleUntil: Date = .distantPast
    private var lastToken = ""
    private var observers: [NSObjectProtocol] = []

    // A finished selection waits here until the user confirms it on the chip,
    // so a stray trackpad drag never fires a translation by itself.
    private var pendingPage: Int?
    private var pendingRect: CGRect = .null
    private weak var menuAnnotation: TranslationAnnotation?
    private weak var hovered: TranslationAnnotation?
    private var hoveredChipButton: Int?
    private var dropHighlight = false
    /// Last single-click toggle, so the second click of a double-click can undo it.
    private var lastToggle: (annotation: TranslationAnnotation?, time: TimeInterval)?

    private static var invalidateHandler: (() -> Void)?
    static func requestInvalidate() { invalidateHandler?() }

    // Selection state (page-space anchor so momentum scroll can't desync it). Pages are tracked
    // by index and points in original coordinates: gapped pages get replaced mid-drag.
    private var anchorPage: Int?
    private var anchorPagePoint: NSPoint = .zero
    private var currentOverlayPoint: NSPoint?
    private var selectionPageRect: CGRect = .null

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
        SelectionOverlay.invalidateHandler = { [weak self] in
            self?.needsDisplay = true
            self?.updateAnimationTimer()
        }
        // Scrolling and zooming move the page under us; redraw on those instead of polling.
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let pdfView = self.pdfView, let view = note.object as? NSView,
                          view !== self, view.isDescendant(of: pdfView) else { return }
                    self.viewportChanged()
                }
            })
        }
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportChanged() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        animationTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Lets clicks on the scroll bars through to the scroll view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let scrollView = pdfView?.documentView?.enclosingScrollView {
            for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 })
            where !scroller.isHidden {
                let local = scroller.convert(point, from: superview)
                if scroller.bounds.contains(local) { return nil }
            }
        }
        return super.hitTest(point)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func viewportChanged() {
        needsDisplay = true
        onViewportChange?()
        // Keep ticking a little so gesture-driven changes that post no notification still land.
        settleUntil = Date().addingTimeInterval(0.25)
        updateAnimationTimer()
    }

    private var loadingAnnotations: [TranslationAnnotation] {
        store?.allViews.filter { $0.isLoading && !$0.showsOriginal } ?? []
    }

    private var hasLoadingAnnotation: Bool { !loadingAnnotations.isEmpty }

    private func updateAnimationTimer() {
        let needed = anchorPage != nil || hasLoadingAnnotation || Date() < settleUntil
        if needed, animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !needed, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
        }
    }

    private func tick() {
        var changed = false
        if anchorPage != nil {
            maybeAutoScroll()
            recomputeSelection()
            changed = true
        }
        let token = transformToken()
        if token != lastToken { lastToken = token; changed = true }
        if changed {
            needsDisplay = true
        } else {
            // Only the skeletons animate: repaint just their boxes, not every rendered page.
            for annotation in loadingAnnotations {
                if let rect = overlayRect(of: annotation) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
            }
        }
        updateAnimationTimer()
    }

    private func transformToken() -> String {
        let clip = pdfView?.documentView?.enclosingScrollView?.contentView
        let o = clip?.bounds.origin ?? .zero
        let s = pdfView?.scaleFactor ?? 1
        return "\(o.x)|\(o.y)|\(s)|\(bounds.width)|\(bounds.height)"
    }

    // MARK: cursor & hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil, chipButton: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
    }

    private func updateHover(at p: NSPoint, modifiers: NSEvent.ModifierFlags) {
        if let chip = chipRects(), chip.frame.contains(p) {
            let button = chip.confirm.contains(p) ? 0 : (chip.cancel.contains(p) ? 1 : nil)
            setHovered(nil, chipButton: button)
            NSCursor.pointingHand.set()
            return
        }
        // Option forces a new selection even on top of an existing box.
        let hit = modifiers.contains(.option) ? nil : annotation(at: p)
        setHovered(hit, chipButton: nil)
        if hit != nil {
            NSCursor.pointingHand.set()
        } else if isOverPage(p) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func setHovered(_ annotation: TranslationAnnotation?, chipButton: Int?) {
        guard annotation !== hovered || chipButton != hoveredChipButton else { return }
        hovered = annotation
        hoveredChipButton = chipButton
        needsDisplay = true
    }

    private func isOverPage(_ p: NSPoint) -> Bool {
        guard let pdfView else { return false }
        return pdfView.page(for: convert(p, to: pdfView), nearest: false) != nil
    }

    // MARK: coordinates

    private func displayedPage(_ index: Int) -> PDFPage? {
        pdfView?.document?.page(at: index)
    }

    private func layout(_ index: Int) -> GapLayout {
        store?.layout(for: index) ?? .empty
    }

    /// Overlay point → original page coordinates of the given page.
    private func originalPoint(_ overlayPoint: NSPoint, page index: Int) -> NSPoint? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        var p = pdfView.convert(convert(overlayPoint, to: pdfView), to: page)
        p.y = layout(index).collapse(p.y)
        return p
    }

    /// Original-coordinate rect → overlay rect (a rect spanning a gap stretches over it).
    private func overlayRect(original rect: CGRect, page index: Int) -> CGRect? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        let l = layout(index)
        let minY = l.expand(rect.minY)
        let maxY = rect.height > 0 ? l.expand(rect.maxY) : minY
        let expanded = CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY)
        return convert(pdfView.convert(expanded, from: page), from: pdfView)
    }

    private func originalBounds(page index: Int) -> CGRect? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        var b = page.bounds(for: pdfView.displayBox)
        b.size.height -= layout(index).totalHeight
        return b
    }

    /// A translation box (expanded page coordinates) → overlay rect.
    private func overlayRect(of annotation: TranslationAnnotation) -> CGRect? {
        guard let pdfView, let page = displayedPage(annotation.model.page) else { return nil }
        return convert(pdfView.convert(annotation.bounds, from: page), from: pdfView)
    }

    // MARK: hit testing

    private func annotation(at overlayPoint: NSPoint) -> TranslationAnnotation? {
        guard let pdfView, let doc = pdfView.document, let store else { return nil }
        let viewPoint = convert(overlayPoint, to: pdfView)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        let index = doc.index(for: page)
        for model in store.annotations.reversed() where model.page == index {
            guard let v = store.view(for: model.id) else { continue }
            // Collapsed handles are thin; give them a comfortable hit target.
            let target = v.showsOriginal ? v.bounds.insetBy(dx: 0, dy: -4) : v.bounds
            if target.contains(pagePoint) { return v }
        }
        return nil
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let chip = chipRects() {
            if chip.confirm.contains(p) {
                confirmPending()
                return
            }
            if chip.cancel.contains(p) {
                cancelPending()
                return
            }
            if chip.frame.contains(p) { return }
            cancelPending()
        }
        if event.clickCount >= 2, !event.modifierFlags.contains(.option), let last = lastToggle,
           event.timestamp - last.time <= NSEvent.doubleClickInterval, let annotation = last.annotation {
            // The first click of this double-click already toggled the box (possibly out from
            // under the cursor). Put it back and treat the pair as "edit".
            lastToggle = nil
            onToggleOriginal?(annotation)
            onEditAnnotation?(annotation)
            return
        }
        if !event.modifierFlags.contains(.option), let hit = annotation(at: p) {
            // Clicks land on us, not the PDFView; hand it the keyboard so arrows/space scroll.
            if let pdfView { window?.makeFirstResponder(pdfView) }
            if event.clickCount >= 2 {
                lastToggle = nil
                onEditAnnotation?(hit)
            } else {
                if hit.status == .done {
                    lastToggle = (annotation: hit, time: event.timestamp)
                } else {
                    lastToggle = nil
                }
                onClickAnnotation?(hit)
            }
            return
        }
        lastToggle = nil
        guard let pdfView, let doc = pdfView.document else { return }
        guard let page = pdfView.page(for: convert(p, to: pdfView), nearest: false) else {
            window?.makeFirstResponder(pdfView)
            return
        }
        let index = doc.index(for: page)
        guard let origin = originalPoint(p, page: index) else { return }
        window?.makeFirstResponder(self)
        anchorPage = index
        anchorPagePoint = origin
        currentOverlayPoint = p
        selectionPageRect = .null
        needsDisplay = true
        updateAnimationTimer()
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchorPage != nil else { return }
        currentOverlayPoint = convert(event.locationInWindow, from: nil)
        recomputeSelection()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { endDrag() }
        guard let page = anchorPage else { return }
        let rect = selectionPageRect
        guard !rect.isNull, rect.width >= 3, rect.height >= 3 else {
            if let pdfView { window?.makeFirstResponder(pdfView) }
            return
        }
        pendingPage = page
        pendingRect = rect
    }

    private func endDrag() {
        anchorPage = nil
        currentOverlayPoint = nil
        selectionPageRect = .null
        needsDisplay = true
        updateAnimationTimer()
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = annotation(at: p) else {
            super.rightMouseDown(with: event)
            return
        }
        menuAnnotation = hit
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let hasText = !hit.model.translationMd.isEmpty
        add("编辑译文…", #selector(menuEdit(_:)), enabled: !hit.isLoading)
        add("拷贝译文", #selector(menuCopy(_:)), enabled: hasText)
        add("重新翻译", #selector(menuRetranslate(_:)), enabled: !hit.isLoading)
        menu.addItem(.separator())
        add(hit.showsOriginal ? "展开译文" : "收起译文", #selector(menuToggleOriginal(_:)), enabled: !hit.isLoading)
        menu.addItem(.separator())
        add("删除译文框", #selector(menuDelete(_:)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuEdit(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onEditAnnotation?(annotation)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onCopyAnnotation?(annotation)
    }

    @objc private func menuRetranslate(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onRetranslateAnnotation?(annotation)
    }

    @objc private func menuToggleOriginal(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onToggleOriginal?(annotation)
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onDeleteAnnotation?(annotation)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36 where pendingPage != nil, 76 where pendingPage != nil: // return, keypad enter
            confirmPending()
        case 53 where anchorPage != nil: // esc mid-drag
            endDrag()
            restoreFirstResponder()
        case 53 where pendingPage != nil:
            cancelPending()
        default:
            // Everything else (arrows, space, page up/down) keeps scrolling the document.
            if let pdfView { pdfView.keyDown(with: event) } else { super.keyDown(with: event) }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if pendingPage != nil { cancelPending() }
    }

    private func confirmPending() {
        guard let page = pendingPage else { return }
        let rect = pendingRect
        let accepted = onSelection?(page, rect) ?? true
        guard accepted else { return }
        clearPending()
        restoreFirstResponder()
        needsDisplay = true
    }

    private func cancelPending() {
        clearPending()
        restoreFirstResponder()
        needsDisplay = true
    }

    private func restoreFirstResponder() {
        guard let window, window.firstResponder === self, let pdfView else { return }
        window.makeFirstResponder(pdfView)
    }

    func clearPending() {
        pendingPage = nil
        pendingRect = .null
        hoveredChipButton = nil
        needsDisplay = true
    }

    // MARK: drag & drop

    private func droppedPDF(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "pdf" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedPDF(sender) != nil else { return [] }
        dropHighlight = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        needsDisplay = true
        guard let url = droppedPDF(sender) else { return false }
        onOpenFile?(url)
        return true
    }

    // MARK: chip

    private struct ChipRects {
        let frame: CGRect
        let confirm: CGRect
        let cancel: CGRect
    }

    private func chipRects() -> ChipRects? {
        guard let pendingPage, !pendingRect.isNull,
              let sel = overlayRect(original: pendingRect, page: pendingPage) else { return nil }
        let confirmW: CGFloat = 66
        let cancelW: CGFloat = 50
        let buttonH: CGFloat = 24
        let pad: CGFloat = 4
        let gap: CGFloat = 4
        let size = CGSize(width: pad * 2 + confirmW + cancelW + gap, height: pad * 2 + buttonH)
        let x = min(max(sel.maxX - size.width, 4), max(bounds.width - size.width - 4, 4))
        var y = sel.maxY + 6
        if y + size.height > bounds.height - 4 { y = sel.minY - 6 - size.height }
        if y < 4 { y = min(max(bounds.height - size.height - 4, 4), sel.maxY + 6) }
        let origin = CGPoint(x: x, y: y)
        let confirm = CGRect(x: origin.x + pad, y: origin.y + pad, width: confirmW, height: buttonH)
        let cancel = CGRect(x: confirm.maxX + gap, y: origin.y + pad, width: cancelW, height: buttonH)
        return ChipRects(frame: CGRect(origin: origin, size: size), confirm: confirm, cancel: cancel)
    }

    private func recomputeSelection() {
        guard let page = anchorPage, let cur = currentOverlayPoint,
              var pt = originalPoint(cur, page: page), let pb = originalBounds(page: page) else { return }
        pt.x = min(max(pt.x, pb.minX), pb.maxX)
        pt.y = min(max(pt.y, pb.minY), pb.maxY)
        selectionPageRect = CGRect(
            x: min(anchorPagePoint.x, pt.x), y: min(anchorPagePoint.y, pt.y),
            width: abs(pt.x - anchorPagePoint.x), height: abs(pt.y - anchorPagePoint.y)
        )
    }

    /// Keeps the drag alive past the viewport so tall regions are selectable on a trackpad.
    private func maybeAutoScroll() {
        guard let pdfView, let dv = pdfView.documentView,
              let clip = dv.enclosingScrollView?.contentView,
              let cur = currentOverlayPoint else { return }
        let edge: CGFloat = 28
        var dy: CGFloat = 0
        if cur.y > bounds.height - edge {
            dy = (cur.y - (bounds.height - edge)) / edge * 18
        } else if cur.y < edge {
            dy = -((edge - cur.y) / edge * 18)
        }
        guard dy != 0 else { return }
        var origin = clip.bounds.origin
        origin.y += dy
        origin.y = min(max(origin.y, 0), max(dv.bounds.height - clip.bounds.height, 0))
        dv.scroll(origin)
    }

    // MARK: drawing

    private static let accent = NSColor.systemBlue

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawAnnotations(in: ctx, dirtyRect: dirtyRect)
        drawSelectionRubberBand()
        drawPendingConfirm()
        if dropHighlight { drawDropHighlight() }
    }

    private func drawPendingConfirm() {
        guard let chip = chipRects(), let pendingPage,
              let sel = overlayRect(original: pendingRect, page: pendingPage) else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        Self.accent.withAlphaComponent(0.08).setFill()
        sel.fill()
        Self.accent.setStroke()
        let selPath = NSBezierPath(rect: sel)
        selPath.lineWidth = 1
        selPath.setLineDash([4, 3], count: 2, phase: 0)
        selPath.stroke()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        let chipPath = NSBezierPath(roundedRect: chip.frame, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        chipPath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        chipPath.lineWidth = 0.5
        chipPath.stroke()

        let confirmPath = NSBezierPath(roundedRect: chip.confirm, xRadius: 5, yRadius: 5)
        let confirmColor = NSColor.controlAccentColor
        (hoveredChipButton == 0 ? confirmColor.blended(withFraction: 0.15, of: .black) ?? confirmColor : confirmColor).setFill()
        confirmPath.fill()
        if hoveredChipButton == 1 {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: chip.cancel, xRadius: 5, yRadius: 5).fill()
        }
        drawChipLabel("翻译 ↩", color: .white, in: chip.confirm)
        drawChipLabel("取消", color: .secondaryLabelColor, in: chip.cancel)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawChipLabel(_ text: String, color: NSColor, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let size = string.size()
        string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawDropHighlight() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    private func drawAnnotations(in ctx: CGContext, dirtyRect: CGRect) {
        guard let pdfView, let doc = pdfView.document, let store else { return }
        let phase = Date().timeIntervalSinceReferenceDate
        for model in store.annotations {
            guard let view = store.view(for: model.id),
                  let page = doc.page(at: model.page) else { continue }
            let rect = convert(pdfView.convert(view.bounds, from: page), from: pdfView)
            guard rect.intersects(bounds), rect.insetBy(dx: -3, dy: -3).intersects(dirtyRect) else { continue }
            let isHovered = view === hovered

            if view.showsOriginal {
                // Collapsed slot: a thin handle marking where the translation lives.
                ctx.saveGState()
                ctx.setFillColor(Self.accent.withAlphaComponent(isHovered ? 0.7 : 0.35).cgColor)
                let handle = CGRect(x: rect.minX, y: rect.midY - 1, width: min(rect.width, 36), height: 2)
                ctx.fill(handle)
                ctx.setStrokeColor(Self.accent.withAlphaComponent(isHovered ? 0.5 : 0.25).cgColor)
                ctx.setLineWidth(0.5)
                ctx.setLineDash(phase: 0, lengths: [3, 2])
                ctx.move(to: CGPoint(x: handle.maxX + 2, y: rect.midY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                ctx.strokePath()
                ctx.restoreGState()
                continue
            }

            ctx.saveGState()
            let tint: NSColor
            let rule: NSColor
            switch view.status {
            case .failed:
                tint = NSColor(calibratedRed: 1, green: 0.95, blue: 0.94, alpha: 1)
                rule = .systemRed
            default:
                tint = isHovered
                    ? NSColor(calibratedRed: 0.91, green: 0.94, blue: 1, alpha: 1)
                    : NSColor(calibratedRed: 0.955, green: 0.965, blue: 1, alpha: 1)
                rule = Self.accent
            }
            ctx.setFillColor(tint.cgColor)
            ctx.fill(rect)

            switch view.status {
            case .loading:
                drawSkeleton(in: rect, phase: phase, context: ctx)
            case .done:
                if let rendered = view.rendered {
                    rendered.draw(in: rect, context: ctx, yDown: true)
                } else {
                    TranslationAnnotation.drawText(view.displayText, color: .black, in: rect.insetBy(dx: 3, dy: 3), context: ctx)
                }
            case .failed:
                TranslationAnnotation.drawText(view.displayText, color: .systemRed, in: rect.insetBy(dx: 5, dy: 3), context: ctx)
            }
            // Left rule instead of a full frame: reads as an interlinear gloss, not a sticky note.
            ctx.setFillColor(rule.withAlphaComponent(isHovered ? 0.9 : 0.55).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: isHovered ? 2.5 : 1.5, height: rect.height))
            ctx.restoreGState()
        }
    }

    /// Placeholder lines with a soft sweep, sized like the text that's coming.
    private func drawSkeleton(in rect: CGRect, phase: TimeInterval, context ctx: CGContext) {
        // rect is in view points; size the bars in page points so they track zoom.
        let scale = pdfView?.scaleFactor ?? 1
        let lineHeight = max(5 * scale, 3)
        let spacing = max(6 * scale, 4)
        let inset = CGPoint(x: 6 * scale, y: 5 * scale)
        let widths: [CGFloat] = [0.94, 0.86, 0.9, 0.62]
        var y = rect.minY + inset.y
        var i = 0
        let available = rect.width - inset.x * 2
        guard available > 4 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        while y + lineHeight <= rect.maxY - inset.y + 0.5 {
            let isLast = y + lineHeight * 2 + spacing > rect.maxY - inset.y
            let fraction = isLast ? 0.55 : widths[i % widths.count]
            let bar = CGRect(x: rect.minX + inset.x, y: y, width: available * fraction, height: lineHeight)
            // Each bar pulses slightly out of step, so the block reads as "flowing in".
            let wave = 0.5 + 0.5 * sin(phase * 3.2 - Double(i) * 0.6)
            ctx.setFillColor(Self.accent.withAlphaComponent(0.10 + 0.10 * wave).cgColor)
            // CGPath asserts when a corner radius exceeds half the rect.
            let radius = min(lineHeight, bar.width) / 2
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            y += lineHeight + spacing
            i += 1
        }
        ctx.restoreGState()
    }

    private func drawSelectionRubberBand() {
        guard let page = anchorPage, !selectionPageRect.isNull,
              let rect = overlayRect(original: selectionPageRect, page: page) else { return }
        Self.accent.withAlphaComponent(0.15).setFill()
        rect.fill()
        Self.accent.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: capture

    static func capture(page: PDFPage, rect: CGRect, scale: CGFloat, box: PDFDisplayBox) -> Data? {
        let maxEdge: CGFloat = 2048
        let effectiveScale = min(scale, maxEdge / max(rect.width, rect.height))
        let w = Int((rect.width * effectiveScale).rounded())
        let h = Int((rect.height * effectiveScale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: effectiveScale, y: effectiveScale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: box, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
