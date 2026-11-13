import AppKit
import PDFKit

/// Spans the reader workspace (PDF panel on the left + floating card sidebar on the right).
/// Paints source highlight boxes on the PDF, floating translation cards in the right sidebar,
/// and smooth cubic Bézier leader lines connecting each boxed source paragraph to its card.
final class SelectionOverlay: NSView {
    /// Page index + selection rect in PDF page coordinates.
    /// Returns false to keep the selection pending (e.g. translation not configured yet).
    var onSelection: ((Int, CGRect) -> Bool)?
    var onClickAnnotation: ((TranslationAnnotation) -> Void)?
    var onEditAnnotation: ((TranslationAnnotation) -> Void)?
    var onDeleteAnnotation: ((TranslationAnnotation) -> Void)?
    var onRetranslateAnnotation: ((TranslationAnnotation) -> Void)?
    var onCopyAnnotation: ((TranslationAnnotation) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    /// A translated card entered the viewport; the view model may typeset it now.
    var onAnnotationBecameVisible: ((TranslationAnnotation) -> Void)?
    /// Scroll / zoom / resize: lets the model remember the reading position.
    var onViewportChange: (() -> Void)?
    var onSidebarWidthChange: (() -> Void)?
    weak var store: AnnotationStore?

    private weak var pdfView: PDFView?
    /// Runs only while something moves on its own: a drag (edge auto-scroll), a loading
    /// skeleton, or briefly after a viewport change. Idle reading costs no wakeups.
    private var animationTimer: Timer?
    private var settleUntil: Date = .distantPast
    private var lastToken = ""
    private var observers: [NSObjectProtocol] = []

    var sidebarWidth: CGFloat = SelectionOverlay.storedSidebarWidth() {
        didSet {
            guard !isResizingSidebar else { return }
            SelectionOverlay.storeSidebarWidth(sidebarWidth)
        }
    }
    private var isResizingSidebar = false
    private static let sidebarWidthKey = "readerSidebarWidth"

    private static func storedSidebarWidth() -> CGFloat {
        let value = UserDefaults.standard.double(forKey: sidebarWidthKey)
        guard value.isFinite, value > 0 else { return CardSidebarLayout.defaultSidebarWidth }
        return min(max(value, CardSidebarLayout.minSidebarWidth), CardSidebarLayout.maxSidebarWidth)
    }

    private static func storeSidebarWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        UserDefaults.standard.set(Double(width), forKey: sidebarWidthKey)
    }

    /// Source highlight rects computed during the layout pass, reused by the highlight and
    /// connector painters so a frame does not convert every annotation three times.
    private var sourceRects: [UUID: CGRect] = [:]

    // A finished selection waits here until the user confirms it on the chip,
    // so a stray trackpad drag never fires a translation by itself.
    private var pendingPage: Int?
    private var pendingRect: CGRect = .null
    private var adjustment: SelectionAdjustment?
    private weak var menuAnnotation: TranslationAnnotation?
    private weak var hovered: TranslationAnnotation?
    private weak var zoomedAnnotation: TranslationAnnotation?
    private var hoverProgress: CGFloat = 0
    private var lastHoverStepTime: TimeInterval = 0
    private var hoveredChipButton: Int?
    private var dividerHovered = false
    private var dropHighlight = false

    private static var invalidateHandler: (() -> Void)?
    static func requestInvalidate() { invalidateHandler?() }

    // Selection state (page-space anchor so momentum scroll can't desync it).
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

    // MARK: panel geometry

    private var pdfScrollView: NSScrollView? {
        pdfView?.documentView?.enclosingScrollView
    }

    private static let passthroughEventTypes: Set<NSEvent.EventType> = [
        .scrollWheel, .magnify, .smartMagnify, .swipe, .rotate,
        .gesture, .beginGesture, .endGesture, .directTouch
    ]

    func effectiveSidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 260 else { return max(min(sidebarWidth, totalWidth * 0.4), 0) }
        let maxAllowed = min(
            CardSidebarLayout.maxSidebarWidth,
            max(min(totalWidth * 0.48, totalWidth - 220), CardSidebarLayout.minSidebarWidth)
        )
        return min(max(sidebarWidth, CardSidebarLayout.minSidebarWidth), maxAllowed)
    }

    var sidebarRect: CGRect {
        let w = effectiveSidebarWidth(for: bounds.width)
        let x = max(bounds.width - w, 0)
        return CGRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)
    }

    var pdfPanelRect: CGRect {
        CGRect(x: 0, y: 0, width: sidebarRect.minX, height: bounds.height)
    }

    private func isNearDivider(_ point: NSPoint) -> Bool {
        abs(point.x - sidebarRect.minX) <= 4
    }

    /// Routes trackpad scroll/zoom gestures anywhere in the workspace (and clicks on
    /// scroll bars) directly to PDFKit's internal scroll view so the PDF and sidebar cards
    /// scroll and zoom together natively.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        if !isDraggingSelection,
           let event = NSApp.currentEvent,
           Self.passthroughEventTypes.contains(event.type),
           let target = pdfView?.documentView ?? pdfScrollView {
            return target
        }
        if localPoint.x < sidebarRect.minX - 4,
           let scrollView = pdfScrollView {
            for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 })
            where !scroller.isHidden {
                let local = scroller.convert(point, from: superview)
                if scroller.bounds.contains(local) { return scroller }
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
        store?.allViews.filter(\.isLoading) ?? []
    }

    private var hasLoadingAnnotation: Bool { !loadingAnnotations.isEmpty }
    private var isDraggingSelection: Bool { anchorPage != nil || adjustment != nil }
    private var targetHoverProgress: CGFloat {
        (hovered != nil && !(hovered?.isLoading ?? true)) ? 1 : 0
    }
    private var isHoverAnimating: Bool {
        zoomedAnnotation != nil && abs(hoverProgress - targetHoverProgress) > 0.001
    }

    private func updateAnimationTimer() {
        let needed = isDraggingSelection || hasLoadingAnnotation || isHoverAnimating || Date() < settleUntil
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
        if isDraggingSelection {
            maybeAutoScroll()
            recomputeSelection()
            changed = true
        }
        if advanceHoverAnimation(now: Date().timeIntervalSinceReferenceDate) {
            changed = true
        }
        let token = transformToken()
        if token != lastToken { lastToken = token; changed = true }
        if changed {
            needsDisplay = true
        } else {
            // Only the skeletons animate: repaint just their card boxes in the sidebar.
            for annotation in loadingAnnotations where !annotation.bounds.isEmpty {
                setNeedsDisplay(annotation.bounds.insetBy(dx: -4, dy: -4))
            }
        }
        updateAnimationTimer()
    }

    private func advanceHoverAnimation(now: TimeInterval) -> Bool {
        guard zoomedAnnotation != nil else { return false }
        let target = targetHoverProgress
        guard abs(hoverProgress - target) > 0.001 else {
            if target == 0 {
                hoverProgress = 0
                zoomedAnnotation = nil
            }
            return false
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hoverProgress = target
            if target == 0 { zoomedAnnotation = nil }
            return true
        }
        let dt = min(max(now - lastHoverStepTime, 0), 1.0 / 15.0)
        lastHoverStepTime = now
        let duration: TimeInterval = target > hoverProgress ? 0.16 : 0.12
        let step = CGFloat(dt / duration)
        if target > hoverProgress {
            hoverProgress = min(target, hoverProgress + step)
        } else {
            hoverProgress = max(target, hoverProgress - step)
            if hoverProgress <= 0.001 {
                hoverProgress = 0
                zoomedAnnotation = nil
            }
        }
        return true
    }

    private func sidebarSharedScale() -> CGFloat {
        guard let store else { return 1.0 }
        let sRect = sidebarRect
        let visibleCards: [(RenderedTranslation, CGRect)] = store.annotations.compactMap { model in
            guard let view = store.view(for: model.id),
                  let rendered = view.rendered,
                  !view.bounds.isEmpty,
                  view.bounds.intersects(sRect) else { return nil }
            return (rendered, view.bounds)
        }
        return SidebarCardPainter.sharedScale(for: visibleCards)
    }

    private func cardPresentation(
        for view: TranslationAnnotation,
        baseScale: CGFloat
    ) -> SidebarCardPainter.HoverLayout {
        guard view === zoomedAnnotation, hoverProgress > 0, !view.bounds.isEmpty else {
            return SidebarCardPainter.HoverLayout(frame: view.bounds, scale: baseScale)
        }
        return SidebarCardPainter.hoverLayout(
            for: view,
            baseRect: view.bounds,
            baseScale: baseScale,
            sidebarRect: sidebarRect,
            viewportBounds: bounds,
            progress: hoverProgress
        )
    }

    private func activeHoveredExpandedFrame() -> CGRect? {
        guard let hovered, !hovered.isLoading, !hovered.bounds.isEmpty else { return nil }
        return cardPresentation(for: hovered, baseScale: sidebarSharedScale()).frame
    }

    private func transformToken() -> String {
        let clip = pdfScrollView?.contentView
        let o = clip?.bounds.origin ?? .zero
        let s = pdfView?.scaleFactor ?? 1
        return "\(o.x)|\(o.y)|\(s)|\(bounds.width)|\(bounds.height)|\(sidebarWidth)"
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
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setDividerHovered(false)
        setHovered(nil, chipButton: nil)
    }

    private func updateHover(at p: NSPoint) {
        let hoveredExpandedRect = activeHoveredExpandedFrame()
        let onHoveredExpanded = hoveredExpandedRect?.contains(p) ?? false
        if !onHoveredExpanded && (isResizingSidebar || isNearDivider(p)) {
            setDividerHovered(true)
            setHovered(nil, chipButton: nil)
            NSCursor.resizeLeftRight.set()
            return
        }
        setDividerHovered(false)
        if let adjustment {
            setHovered(nil, chipButton: nil)
            cursor(for: adjustment.kind, dragging: true).set()
            return
        }
        if let chip = chipRects(), chip.frame.contains(p) {
            let button = chip.confirm.contains(p) ? 0 : (chip.cancel.contains(p) ? 1 : nil)
            setHovered(nil, chipButton: button)
            NSCursor.pointingHand.set()
            return
        }
        if p.x < sidebarRect.minX, !onHoveredExpanded, let kind = pendingInteraction(at: p) {
            setHovered(nil, chipButton: nil)
            cursor(for: kind).set()
            return
        }
        let hit = annotation(at: p)
        setHovered(hit, chipButton: nil)
        if p.x >= sidebarRect.minX || (hit != nil && hit === hovered && onHoveredExpanded) {
            (hit != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if hit?.isFailed == true {
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
        if let annotation, !annotation.isLoading {
            if zoomedAnnotation !== annotation {
                zoomedAnnotation = annotation
                hoverProgress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
            } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                hoverProgress = 1
            }
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hoverProgress = 0
            zoomedAnnotation = nil
        }
        lastHoverStepTime = Date().timeIntervalSinceReferenceDate
        updateAnimationTimer()
        needsDisplay = true
    }

    private func setDividerHovered(_ isHovered: Bool) {
        guard isHovered != dividerHovered else { return }
        dividerHovered = isHovered
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func isOverPage(_ p: NSPoint) -> Bool {
        guard p.x < sidebarRect.minX, let pdfView else { return false }
        return pdfView.page(for: convert(p, to: pdfView), nearest: false) != nil
    }

    // MARK: coordinates & card layout

    private func displayedPage(_ index: Int) -> PDFPage? {
        pdfView?.document?.page(at: index)
    }

    /// Overlay point → page coordinates of the given page.
    private func originalPoint(_ overlayPoint: NSPoint, page index: Int) -> NSPoint? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        return pdfView.convert(convert(overlayPoint, to: pdfView), to: page)
    }

    private func overlayPoint(original point: CGPoint, page index: Int) -> CGPoint? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    /// Page-coordinate rect → overlay rect.
    private func overlayRect(original rect: CGRect, page index: Int) -> CGRect? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    /// Overlay-space source box for an annotation. Prefers the rect cached by the current
    /// layout pass and falls back to a live PDFKit conversion.
    private func sourceRect(for model: Annotation) -> CGRect? {
        if let cached = sourceRects[model.id] { return cached }
        guard let pdfView, let page = pdfView.document?.page(at: model.page) else { return nil }
        return convert(pdfView.convert(model.rect, from: page), from: pdfView)
    }

    private func originalBounds(page index: Int) -> CGRect? {
        guard let pdfView, let page = displayedPage(index) else { return nil }
        return page.bounds(for: pdfView.displayBox)
    }

    /// Computes and assigns non-overlapping sidebar card frames for annotations whose source
    /// selection is currently visible in the PDF viewport (SPEC §3.1.2).
    ///
    /// Annotations that scrolled out of view get `bounds = .zero` so they neither paint nor
    /// respond to sidebar mouse hits, and the remaining cards re-justify into the freed space.
    @discardableResult
    func layoutSidebarCards() -> [PlacedSidebarCard] {
        guard let pdfView, let doc = pdfView.document, let store else {
            sourceRects.removeAll(keepingCapacity: true)
            return []
        }
        sourceRects.removeAll(keepingCapacity: true)
        let sRect = sidebarRect
        let cardX = sRect.minX + CardSidebarLayout.cardHorizontalInset
        let cardWidth = max(sRect.width - CardSidebarLayout.cardHorizontalInset * 2, 100)
        let panel = pdfPanelRect

        var specs: [SidebarCardSpec] = []
        specs.reserveCapacity(store.annotations.count)
        for model in store.annotations {
            guard let view = store.view(for: model.id),
                  let page = doc.page(at: model.page) else { continue }
            let sourceRect = convert(pdfView.convert(model.rect, from: page), from: pdfView)
            sourceRects[model.id] = sourceRect
            guard Self.isSourceVisibleInViewport(sourceRect, in: panel) else {
                view.bounds = .zero
                continue
            }
            onAnnotationBecameVisible?(view)
            let metrics = view.layoutMetrics(maxCardWidth: cardWidth)
            specs.append(SidebarCardSpec(
                id: model.id,
                page: model.page,
                sourceRect: model.rect,
                desiredY: sourceRect.minY,
                preferredWidth: metrics.naturalWidth,
                height: metrics.naturalHeight,
                pageMinY: 0,
                pageMaxY: sRect.height,
                viewportRect: sourceRect,
                isFullWidth: metrics.isFullWidth,
                contentUnits: metrics.contentUnits
            ))
        }

        let placed = CardSidebarLayout.placeScreenCards(
            specs,
            cardX: cardX,
            cardWidth: cardWidth,
            viewportHeight: sRect.height
        )
        let placedIDs = Set(placed.map(\.id))
        for model in store.annotations where !placedIDs.contains(model.id) {
            store.view(for: model.id)?.bounds = .zero
        }
        for item in placed {
            store.view(for: item.id)?.bounds = item.frame
        }
        return placed
    }

    /// SPEC §3.1.2: a source box activates its translation when it is horizontally inside the
    /// PDF panel and either 25% of its height is exposed, its center is on screen, or a very
    /// tall selection shows at least 20% of the viewport.
    static func isSourceVisibleInViewport(_ sourceRect: CGRect, in panel: CGRect) -> Bool {
        guard !panel.isEmpty,
              sourceRect.width.isFinite, sourceRect.height.isFinite,
              sourceRect.minX.isFinite, sourceRect.minY.isFinite,
              !sourceRect.isNull, !sourceRect.isEmpty else { return false }
        guard sourceRect.maxX > panel.minX + 2,
              sourceRect.minX < panel.maxX - 2 else { return false }
        let top = max(sourceRect.minY, panel.minY)
        let bottom = min(sourceRect.maxY, panel.maxY)
        let visibleHeight = max(0, bottom - top)
        if visibleHeight / max(sourceRect.height, 1) >= 0.25 { return true }
        if sourceRect.midY >= panel.minY, sourceRect.midY <= panel.maxY { return true }
        return visibleHeight >= 0.20 * panel.height
    }

    // MARK: hit testing

    private func pendingHandlePoints() -> [(SelectionHandle, CGPoint)] {
        guard let pendingPage, !pendingRect.isNull else { return [] }
        return SelectionHandle.allCases.compactMap { handle in
            overlayPoint(original: handle.point(in: pendingRect), page: pendingPage).map { (handle, $0) }
        }
    }

    private func pendingInteraction(at point: CGPoint) -> SelectionAdjustment.Kind? {
        guard point.x < sidebarRect.minX,
              let pendingPage, let rect = overlayRect(original: pendingRect, page: pendingPage) else { return nil }
        let points = pendingHandlePoints()
        func distance(to other: CGPoint) -> CGFloat { hypot(point.x - other.x, point.y - other.y) }
        if let closest = points.min(by: { distance(to: $0.1) < distance(to: $1.1) }),
           distance(to: closest.1) <= 8 {
            return .resize(closest.0)
        }
        // The whole edge is draggable, not just the small handle at its midpoint.
        for handle in SelectionHandle.allCases {
            guard let (first, last) = handle.edgeCorners,
                  let a = points.first(where: { $0.0 == first })?.1,
                  let b = points.first(where: { $0.0 == last })?.1 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
            if distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy)) <= 5 { return .resize(handle) }
        }
        return rect.contains(point) ? .move : nil
    }

    private func cursor(for kind: SelectionAdjustment.Kind, dragging: Bool = false) -> NSCursor {
        switch kind {
        case .move: return dragging ? .closedHand : .openHand
        case .resize(let handle):
            let rotated = pendingPage.flatMap { displayedPage($0) }?.rotation ?? 0
            switch handle {
            case .left, .right: return rotated % 180 == 0 ? .resizeLeftRight : .resizeUpDown
            case .top, .bottom: return rotated % 180 == 0 ? .resizeUpDown : .resizeLeftRight
            default: return .crosshair
            }
        }
    }

    private func annotation(at overlayPoint: NSPoint) -> TranslationAnnotation? {
        guard let store else { return nil }
        // Keep the active magnified card stable even when its expanded frame overlaps neighbors
        // or floats across the sidebar divider.
        if let hovered, let expandedFrame = activeHoveredExpandedFrame(), expandedFrame.contains(overlayPoint) {
            return hovered
        }
        // Card frames from the last layout pass are already in `bounds`; laying out again on
        // every mouseMoved would additionally kick off lazy typesetting while merely hovering.
        if overlayPoint.x >= sidebarRect.minX {
            // Hit-test floating cards in the right sidebar.
            for model in store.annotations.reversed() {
                guard let v = store.view(for: model.id), !v.bounds.isEmpty else { continue }
                if v.bounds.contains(overlayPoint) { return v }
            }
            return nil
        }
        // Hit-test source highlight boxes on the PDF page.
        guard let pdfView, let doc = pdfView.document else { return nil }
        let viewPoint = convert(overlayPoint, to: pdfView)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        let index = doc.index(for: page)
        for model in store.annotations.reversed() where model.page == index {
            guard let v = store.view(for: model.id) else { continue }
            if model.rect.insetBy(dx: -2, dy: -2).contains(pagePoint) { return v }
        }
        return nil
    }

    // MARK: mouse & scrolling

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = pdfScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
        if isDraggingSelection {
            recomputeSelection()
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        if let scrollView = pdfScrollView {
            scrollView.magnify(with: event)
        } else {
            super.magnify(with: event)
        }
        needsDisplay = true
    }

    override func smartMagnify(with event: NSEvent) {
        if let scrollView = pdfScrollView {
            scrollView.smartMagnify(with: event)
        } else {
            super.smartMagnify(with: event)
        }
        needsDisplay = true
    }

    override func swipe(with event: NSEvent) {
        if let scrollView = pdfScrollView {
            scrollView.swipe(with: event)
        } else {
            super.swipe(with: event)
        }
        needsDisplay = true
    }

    override func rotate(with event: NSEvent) {
        if let scrollView = pdfScrollView {
            scrollView.rotate(with: event)
        } else {
            super.rotate(with: event)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let onHoveredExpanded = activeHoveredExpandedFrame()?.contains(p) ?? false
        if !onHoveredExpanded && isNearDivider(p) {
            isResizingSidebar = true
            NSCursor.resizeLeftRight.set()
            return
        }
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
        }
        if p.x < sidebarRect.minX, !onHoveredExpanded, let page = pendingPage,
           let kind = pendingInteraction(at: p), let origin = originalPoint(p, page: page) {
            window?.makeFirstResponder(self)
            adjustment = SelectionAdjustment(kind: kind, startPoint: origin, startRect: pendingRect)
            currentOverlayPoint = p
            cursor(for: kind, dragging: true).set()
            needsDisplay = true
            updateAnimationTimer()
            return
        }
        if pendingPage != nil { cancelPending() }

        // Clicking inside the right sidebar (or the floating magnified card) interacts with cards.
        if p.x >= sidebarRect.minX || onHoveredExpanded {
            if let pdfView { window?.makeFirstResponder(pdfView) }
            if let hit = annotation(at: p) {
                if event.clickCount >= 2 {
                    onEditAnnotation?(hit)
                } else {
                    onClickAnnotation?(hit)
                }
            }
            return
        }

        // Double-clicking a source highlight on the PDF page opens the translation editor.
        if event.clickCount >= 2, let hit = annotation(at: p) {
            if let pdfView { window?.makeFirstResponder(pdfView) }
            onEditAnnotation?(hit)
            return
        }

        // Box selection starts anywhere inside the left PDF panel (even over an existing highlight).
        guard let pdfView, let doc = pdfView.document else {
            if let pdfView { window?.makeFirstResponder(pdfView) }
            return
        }
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
        let p = convert(event.locationInWindow, from: nil)
        if isResizingSidebar {
            let proposed = bounds.width - p.x
            sidebarWidth = min(max(proposed, CardSidebarLayout.minSidebarWidth),
                               min(CardSidebarLayout.maxSidebarWidth, max(bounds.width * 0.48, CardSidebarLayout.minSidebarWidth)))
            onSidebarWidthChange?()
            needsDisplay = true
            return
        }
        guard isDraggingSelection else { return }
        currentOverlayPoint = CGPoint(x: min(p.x, sidebarRect.minX - 1), y: p.y)
        recomputeSelection()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isResizingSidebar {
            isResizingSidebar = false
            Self.storeSidebarWidth(sidebarWidth)
            needsDisplay = true
            return
        }
        defer { endDrag() }
        guard isDraggingSelection else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentOverlayPoint = CGPoint(x: min(p.x, sidebarRect.minX - 1), y: p.y)
        recomputeSelection()
        if adjustment != nil { return }
        guard let page = anchorPage else { return }
        let rect = selectionPageRect
        guard !rect.isNull, rect.width >= SelectionAdjustment.minimumSize,
              rect.height >= SelectionAdjustment.minimumSize else {
            if let pdfView { window?.makeFirstResponder(pdfView) }
            if let hit = annotation(at: p), hit.isFailed {
                onClickAnnotation?(hit)
            }
            return
        }
        pendingPage = page
        pendingRect = rect
    }

    private func endDrag() {
        anchorPage = nil
        adjustment = nil
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

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let annotation = menuAnnotation else { return }
        onDeleteAnnotation?(annotation)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36 where pendingPage != nil, 76 where pendingPage != nil: // return, keypad enter
            confirmPending()
        case 53 where isDraggingSelection || pendingPage != nil:
            cancelSelectionInteraction()
        default:
            // Everything else (arrows, space, page up/down) keeps scrolling the document.
            if let pdfView { pdfView.keyDown(with: event) } else { super.keyDown(with: event) }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelSelectionInteraction()
    }

    private func cancelSelectionInteraction() {
        if let adjustment {
            pendingRect = adjustment.startRect
            endDrag()
        } else if anchorPage != nil {
            endDrag()
            restoreFirstResponder()
        } else if pendingPage != nil {
            cancelPending()
        }
    }

    private func confirmPending() {
        guard let page = pendingPage, !isDraggingSelection else { return }
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
        endDrag()
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
        guard adjustment == nil, let pendingPage, !pendingRect.isNull,
              let sel = overlayRect(original: pendingRect, page: pendingPage),
              sel.intersects(pdfPanelRect) else { return nil }
        let confirmW: CGFloat = 66
        let cancelW: CGFloat = 50
        let buttonH: CGFloat = 24
        let pad: CGFloat = 4
        let gap: CGFloat = 4
        let size = CGSize(width: pad * 2 + confirmW + cancelW + gap, height: pad * 2 + buttonH)
        let maxX = max(pdfPanelRect.maxX - size.width - 6, 4)
        let x = min(max(sel.maxX - size.width, 4), maxX)
        var y = sel.maxY + 6
        if y + size.height > bounds.height - 4 { y = sel.minY - 6 - size.height }
        if y < 4 { y = min(max(bounds.height - size.height - 4, 4), sel.maxY + 6) }
        let origin = CGPoint(x: x, y: y)
        let confirm = CGRect(x: origin.x + pad, y: origin.y + pad, width: confirmW, height: buttonH)
        let cancel = CGRect(x: confirm.maxX + gap, y: origin.y + pad, width: cancelW, height: buttonH)
        return ChipRects(frame: CGRect(origin: origin, size: size), confirm: confirm, cancel: cancel)
    }

    private func recomputeSelection() {
        if let adjustment, let page = pendingPage, let cur = currentOverlayPoint,
           let point = originalPoint(cur, page: page), let pageBounds = originalBounds(page: page) {
            pendingRect = adjustment.rect(at: point, within: pageBounds)
            return
        }
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

    private struct VisibleConnectorPair {
        let view: TranslationAnnotation
        let sourceRect: CGRect
        let cardRect: CGRect
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        layoutSidebarCards()

        let pairs = visibleConnectorPairs()
        guard let activePair = pairs.first(where: { $0.view === hovered }) else {
            if hovered != nil {
                hovered = nil
                zoomedAnnotation = nil
                hoverProgress = 0
                updateAnimationTimer()
            }
            drawSidebarContent(pairs: pairs, activePair: nil, in: ctx, dirtyRect: dirtyRect)
            return
        }
        drawSidebarContent(pairs: pairs, activePair: activePair, in: ctx, dirtyRect: dirtyRect)
    }

    private func drawSidebarContent(
        pairs: [VisibleConnectorPair],
        activePair: VisibleConnectorPair?,
        in ctx: CGContext,
        dirtyRect: CGRect
    ) {
        drawSidebarBackdrop(in: ctx, dirtyRect: dirtyRect)
        if ConnectorStyle.shouldDrawQuiet(count: pairs.count, hovering: activePair != nil) {
            drawQuietConnectors(pairs, in: ctx)
        }
        drawSourceHighlights(in: ctx, dirtyRect: dirtyRect, anyHovered: activePair != nil)
        drawSidebarCards(in: ctx, dirtyRect: dirtyRect)
        if let activePair {
            drawActiveConnector(activePair, in: ctx)
            drawActiveEndpoint(activePair, in: ctx)
        }
        drawSelectionChrome()
        if dropHighlight { drawDropHighlight() }
    }

    private func visibleConnectorPairs() -> [VisibleConnectorPair] {
        guard let store, pdfView?.document != nil else { return [] }
        let visibleVertical = bounds.insetBy(dx: 0, dy: -80)
        let baseScale = sidebarSharedScale()
        var pairs: [VisibleConnectorPair] = []
        pairs.reserveCapacity(store.annotations.count)
        for model in store.annotations {
            guard let view = store.view(for: model.id), !view.bounds.isEmpty,
                  let source = sourceRect(for: model) else { continue }
            let cardRect = cardPresentation(for: view, baseScale: baseScale).frame
            guard source.maxY >= visibleVertical.minY, source.minY <= visibleVertical.maxY,
                  cardRect.maxY >= visibleVertical.minY, cardRect.minY <= visibleVertical.maxY else { continue }
            pairs.append(VisibleConnectorPair(view: view, sourceRect: source, cardRect: cardRect))
        }
        return pairs
    }

    private func connector(for pair: VisibleConnectorPair) -> CardConnector {
        CardConnector(
            sourceRect: pair.sourceRect,
            cardRect: pair.cardRect,
            minSourceX: 6,
            maxSourceX: max(sidebarRect.minX - 6, 6)
        )
    }

    /// One combined path, clipped into the PDF panel and the sidebar so the line can use a
    /// surface-appropriate accent on each side. Sparse viewports only; dense ones draw no
    /// idle leader lines at all.
    private func drawQuietConnectors(_ pairs: [VisibleConnectorPair], in ctx: CGContext) {
        guard !pairs.isEmpty else { return }
        let alpha = ConnectorStyle.quietAlpha(for: pairs.count)
        guard alpha > 0 else { return }

        let path = CGMutablePath()
        for pair in pairs {
            connector(for: pair).addPath(to: path)
        }

        ctx.saveGState()
        ctx.setLineWidth(ConnectorStyle.quietLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.saveGState()
        ctx.clip(to: pdfPanelRect)
        ctx.setStrokeColor(ReaderTheme.inkAccent.withAlphaComponent(alpha).cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: sidebarRect)
        ctx.setStrokeColor(ReaderTheme.chromeAccent.withAlphaComponent(alpha).cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /// The hovered pair gets the only visible leader line: a soft halo plus a crisp stroke.
    /// The sidebar half is clipped around every card so it never runs across card content.
    private func drawActiveConnector(_ pair: VisibleConnectorPair, in ctx: CGContext) {
        let onPaper = pair.view.isFailed ? ReaderTheme.inkError : ReaderTheme.inkAccent
        let onChrome = pair.view.isFailed ? ReaderTheme.chromeError : ReaderTheme.chromeAccent
        let path = CGMutablePath()
        connector(for: pair).addPath(to: path)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.saveGState()
        clip(pdfPanelRect, excludingCardsIn: ctx)
        ctx.setStrokeColor(onPaper.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(ConnectorStyle.activeLineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        clip(sidebarRect, excludingCardsIn: ctx)
        ctx.setStrokeColor(onChrome.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(ConnectorStyle.activeLineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    private func drawActiveEndpoint(_ pair: VisibleConnectorPair, in ctx: CGContext) {
        let connector = connector(for: pair)
        let color = pair.view.isFailed ? ReaderTheme.inkError : ReaderTheme.inkAccent
        let radius = ConnectorStyle.cardEndpointRadius
        let center = connector.end
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    private func clip(_ region: CGRect, excludingCardsIn ctx: CGContext) {
        let clipPath = CGMutablePath()
        clipPath.addRect(region)
        if let store {
            let baseScale = sidebarSharedScale()
            let radius = SidebarCardStyle.cornerRadius
            for model in store.annotations {
                guard let view = store.view(for: model.id), !view.bounds.isEmpty else { continue }
                let rect = cardPresentation(for: view, baseScale: baseScale).frame
                guard rect.intersects(region) else { continue }
                let corner = min(radius, min(rect.width, rect.height) * 0.35)
                clipPath.addPath(CGPath(roundedRect: rect, cornerWidth: corner,
                                        cornerHeight: corner, transform: nil))
            }
        }
        ctx.addPath(clipPath)
        ctx.clip(using: .evenOdd)
    }

    private func drawSidebarBackdrop(in ctx: CGContext, dirtyRect: CGRect) {
        let sRect = sidebarRect
        guard sRect.intersects(dirtyRect) else { return }

        ctx.saveGState()
        ctx.clip(to: sRect)

        let colors = [ReaderTheme.sidebarTop.cgColor, ReaderTheme.sidebarBottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: sRect.midX, y: sRect.minY),
                end: CGPoint(x: sRect.midX, y: sRect.maxY),
                options: []
            )
        } else {
            ctx.setFillColor(ReaderTheme.sidebarTop.cgColor)
            ctx.fill(sRect)
        }

        // A soft inward shadow makes the divider read as a physical panel edge.
        let shadowColors = [ReaderTheme.sidebarInnerShadow.cgColor, NSColor.clear.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: shadowColors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: sRect.minX, y: 0, width: 16, height: sRect.height))
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: sRect.minX, y: sRect.midY),
                end: CGPoint(x: sRect.minX + 16, y: sRect.midY),
                options: []
            )
            ctx.restoreGState()
        }

        if isResizingSidebar || dividerHovered {
            ctx.setFillColor(ReaderTheme.chromeAccent
                .withAlphaComponent(isResizingSidebar ? 0.70 : 0.45).cgColor)
            ctx.fill(CGRect(x: sRect.minX, y: 0, width: 3, height: sRect.height))
        } else {
            ctx.setFillColor(ReaderTheme.sidebarDivider.cgColor)
            ctx.fill(CGRect(x: sRect.minX, y: 0, width: 1, height: sRect.height))
        }

        if let store, pdfView?.document != nil, store.annotations.isEmpty {
            drawEmptySidebarHint(in: sRect)
        }

        ctx.restoreGState()
    }

    private func drawSourceHighlights(in ctx: CGContext, dirtyRect: CGRect, anyHovered: Bool) {
        let pdfArea = pdfPanelRect
        guard pdfArea.intersects(dirtyRect) else { return }
        ctx.saveGState()
        ctx.clip(to: pdfArea)

        if let store, pdfView?.document != nil {
            for model in store.annotations {
                guard let view = store.view(for: model.id),
                      let sourceRect = sourceRect(for: model) else { continue }
                guard sourceRect.intersects(pdfArea),
                      sourceRect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
                let state = SourceHighlightPainter.State(
                    isHovered: view === hovered,
                    anyHovered: anyHovered,
                    isFailed: view.isFailed,
                    isPrint: false
                )
                SourceHighlightPainter.draw(sourceRect, state: state, in: ctx)
            }
        }

        ctx.restoreGState()
    }

    private func drawSelectionChrome() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: pdfPanelRect)
        drawSelectionRubberBand()
        drawPendingConfirm()
        ctx.restoreGState()
    }

    private func drawSidebarCards(in ctx: CGContext, dirtyRect: CGRect) {
        let sRect = sidebarRect
        guard let store, pdfView?.document != nil, !store.annotations.isEmpty else { return }

        let ordered = store.annotations.compactMap { store.view(for: $0.id) }
        let preferredScale = sidebarSharedScale()
        let floatingView = zoomedAnnotation ?? hovered
        let floatingLayout = floatingView.map { cardPresentation(for: $0, baseScale: preferredScale) }
        let floatingIntersectsDirty = floatingLayout?.frame.insetBy(dx: -24, dy: -24).intersects(dirtyRect) ?? false
        guard sRect.intersects(dirtyRect) || floatingIntersectsDirty else { return }

        let phase = Date().timeIntervalSinceReferenceDate
        func drawCard(_ view: TranslationAnnotation, rect: CGRect, scale: CGFloat) {
            let state = SidebarCardPainter.State(
                isHovered: view === hovered,
                isDimmed: hovered != nil && view !== hovered,
                isFailed: view.isFailed,
                isPrint: false
            )
            SidebarCardPainter.draw(
                view,
                in: rect,
                scale: scale,
                state: state,
                phase: phase,
                context: ctx,
                yDown: true
            )
        }

        if sRect.intersects(dirtyRect) {
            ctx.saveGState()
            ctx.clip(to: sRect)
            for view in ordered where view !== floatingView {
                let cardRect = view.bounds
                guard !cardRect.isEmpty,
                      cardRect.intersects(sRect),
                      cardRect.insetBy(dx: -10, dy: -10).intersects(dirtyRect) else { continue }
                drawCard(view, rect: cardRect, scale: preferredScale)
            }
            ctx.restoreGState()
        }

        // Paint the active/zooming card last without the sidebar clip so it can float
        // across the divider when compressed or narrow, while still clamped to `bounds`.
        if let floatingView, let layout = floatingLayout,
           !layout.frame.isEmpty,
           layout.frame.intersects(bounds),
           layout.frame.insetBy(dx: -24, dy: -24).intersects(dirtyRect) {
            ctx.saveGState()
            ctx.clip(to: bounds)
            drawCard(floatingView, rect: layout.frame, scale: layout.scale)
            ctx.restoreGState()
        }
    }

    private func drawEmptySidebarHint(in sRect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let text = "在左侧页面拖拽框选段落\n译文悬浮卡片将显示在此处并与原文连线"
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        let size = attr.size()
        let cardWidth = min(max(size.width + 44, 220), max(sRect.width - 24, 100))
        let cardHeight = max(size.height + 44, 116)
        let placeholder = CGRect(
            x: sRect.midX - cardWidth / 2,
            y: sRect.midY - cardHeight / 2,
            width: cardWidth,
            height: cardHeight
        )
        let path = NSBezierPath(roundedRect: placeholder.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8, yRadius: 8)
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        ReaderTheme.hintBorder.setStroke()
        path.stroke()
        let drawRect = CGRect(
            x: placeholder.midX - size.width / 2,
            y: placeholder.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        attr.draw(in: drawRect)
    }

    private func drawPendingConfirm() {
        guard let pendingPage, !pendingRect.isNull,
              let sel = overlayRect(original: pendingRect, page: pendingPage) else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        ReaderTheme.selectionFill.setFill()
        sel.fill()
        ReaderTheme.selectionStroke.setStroke()
        let selPath = NSBezierPath(roundedRect: sel, xRadius: 2, yRadius: 2)
        selPath.lineWidth = 1
        selPath.stroke()

        for (_, point) in pendingHandlePoints() {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 3.5, y: point.y - 3.5,
                                                         width: 7, height: 7),
                                      xRadius: 1.5, yRadius: 1.5)
            ReaderTheme.handleFill.setFill()
            handle.fill()
            ReaderTheme.selectionStroke.setStroke()
            handle.lineWidth = 1.0
            handle.stroke()
        }
        guard let chip = chipRects() else { return }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        let chipPath = NSBezierPath(roundedRect: chip.frame, xRadius: 8, yRadius: 8)
        ReaderTheme.chipSurface.setFill()
        chipPath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        ReaderTheme.chipBorder.setStroke()
        chipPath.lineWidth = 0.5
        chipPath.stroke()

        let confirmPath = NSBezierPath(roundedRect: chip.confirm, xRadius: 6, yRadius: 6)
        let confirmColor = hoveredChipButton == 0
            ? ReaderTheme.inkAccentStrong
            : ReaderTheme.inkAccent
        confirmColor.setFill()
        confirmPath.fill()
        if hoveredChipButton == 1 {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: chip.cancel, xRadius: 6, yRadius: 6).fill()
        }
        drawChipLabel("翻译 ⏎", color: .white, in: chip.confirm)
        drawChipLabel("取消", color: .secondaryLabelColor, in: chip.cancel)
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
        ReaderTheme.chromeAccent.withAlphaComponent(0.07).setFill()
        path.fill()
        ReaderTheme.chromeAccent.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }

    /// Placeholder lines with a soft sweep, sized like the text that's coming.
    private func drawSkeleton(in rect: CGRect, phase: TimeInterval, context ctx: CGContext) {
        let lineHeight: CGFloat = 6
        let spacing: CGFloat = 7
        let inset = CGPoint(x: 4, y: 4)
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
            ctx.setFillColor(ReaderTheme.skeleton.withAlphaComponent(0.10 + 0.10 * wave).cgColor)
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
        ReaderTheme.selectionFill.setFill()
        rect.fill()
        ReaderTheme.selectionStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
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

