import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Transient message shown in the bottom status pill.
struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var isError = false
    var actionTitle: String?
    var action: (() -> Void)?
}

@MainActor
final class PDFViewModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileName: String = ""
    @Published var currentPageIndex: Int = 0
    @Published private(set) var outline: [PDFOutlineEntry] = []
    @Published var showsOutline = false
    @Published private(set) var selectedOutlineID: String?
    @Published private(set) var pageJumpRequest = 0
    @Published var editing: AnnotationEditSession?
    @Published var toast: Toast?
    @Published private(set) var activeTranslations = 0
    @Published private(set) var recentFiles: [URL] = ReadingHistory.recent()
    @Published private(set) var saveError: String?
    @Published private(set) var isPreparingDocument = false
    /// Bumped to ask the view layer to open the Settings window.
    @Published var settingsRequest = 0

    let store = AnnotationStore()
    private(set) var fileURL: URL?
    private var persistence: AnnotationPersistence?
    private var saveTask: Task<Void, Never>?
    private var positionRestored = false
    private var positionTask: Task<Void, Never>?
    private var sidebarRenderTask: Task<Void, Never>?
    private var lastRenderedMaxInnerWidth: CGFloat = TranslationAnnotation.defaultRenderWidth
    private var toastTask: Task<Void, Never>?
    weak var pdfView: PDFView?
    weak var undoManager: UndoManager?
    private var observers: [NSObjectProtocol] = []

    var pageLabel: String {
        guard let total = document?.pageCount else { return "" }
        return "第 \(currentPageIndex + 1) / \(total) 页"
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    var canGoToPreviousPage: Bool { currentPageIndex > 0 && pageCount > 0 }
    var canGoToNextPage: Bool { currentPageIndex + 1 < pageCount }

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let view = note.object as? PDFView, view === self.pdfView else { return }
                self.refreshCurrentPage()
                self.savePosition()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flush() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: toasts

    func show(_ message: String, isError: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let next = Toast(message: message, isError: isError, actionTitle: actionTitle, action: action)
        toast = next
        toastTask?.cancel()
        let seconds: UInt64 = action != nil ? 6 : (isError ? 5 : 2)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == next.id else { return }
            self.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "选择要阅读的 PDF"
        if let window = pdfView?.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { self?.open(url: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        let url = url.standardizedFileURL
        if url == fileURL {
            if let persistence, !persistence.isReady, !isPreparingDocument {
                prepareAnnotations(persistence)
            }
            return
        }
        guard let doc = PDFDocument(url: url) else {
            show("无法打开 \(url.lastPathComponent)", isError: true)
            return
        }
        if doc.isLocked {
            show("暂不支持加密的 PDF", isError: true)
            return
        }
        // Flush the outgoing document before its state is replaced.
        guard flush() else { return }
        editing = nil
        undoManager?.removeAllActions()
        dismissToast()

        let session = AnnotationPersistence(pdfURL: url)
        persistence = session
        outline = PDFOutlineEntry.read(from: doc)
        selectedOutlineID = nil
        document = doc
        fileURL = url
        fileName = url.lastPathComponent
        currentPageIndex = 0
        saveError = nil
        store.removeAll()
        // Installing the document posts page-changed notifications; until the saved
        // position is restored they must not overwrite it with "page 1".
        positionRestored = false
        pdfView?.document = doc
        pdfView?.autoScales = true
        pdfView?.layoutDocumentView()
        finishOpening(url)

        ReadingHistory.noteOpened(url)
        recentFiles = ReadingHistory.recent()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        prepareAnnotations(session)
    }

    private func prepareAnnotations(_ session: AnnotationPersistence) {
        guard persistence === session else { return }
        isPreparingDocument = true
        let url = session.pdfURL
        Task {
            do {
                // Reading may fail partway through; never attach notes to a partial hash.
                let sha = try await Task.detached(priority: .userInitiated) {
                    try SidecarIO.sha256(of: url)
                }.value
                guard self.persistence === session else { return }
                self.restoreAnnotations(session.load(pdfSha256: sha), session: session)
                self.isPreparingDocument = false
            } catch {
                guard self.persistence === session else { return }
                self.isPreparingDocument = false
                Log.write("PDF hash failed: \(error)")
                self.show("无法读取 PDF，译注暂未加载", isError: true, actionTitle: "重试") { [weak self] in
                    self?.prepareAnnotations(session)
                }
            }
        }
    }

    /// Reopens the document the reader had open last time.
    func restoreLastSession() {
        guard document == nil, let last = recentFiles.first else { return }
        open(url: last)
    }

    func clearRecentFiles() {
        ReadingHistory.clearRecent()
        recentFiles = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func restoreAnnotations(_ result: SidecarIO.LoadResult, session: AnnotationPersistence) {
        let models: [Annotation]
        switch result {
        case .missing:
            return
        case .mismatch:
            // The PDF changed since these were made; their positions may no longer fit.
            // Keep the old file around instead of silently overwriting it on the next save.
            show("已有的译注属于此文件的另一版本，未加载（再次保存前会备份为 .bak）", isError: true)
            return
        case .unreadable(let reason):
            Log.write("existing sidecar requires backup: \(reason)")
            show("已有译注无法读取，未加载；再次保存前会先备份原文件", isError: true)
            return
        case .loaded(let loaded):
            models = loaded
        }
        guard !models.isEmpty else { return }
        let annotations = models.map { model -> TranslationAnnotation in
            let annotation = TranslationAnnotation(model: model)
            // An empty translation was in flight or failed when the app last closed.
            annotation.status = model.translationMd.isEmpty ? .failed("上次未完成") : .done
            annotation.fallbackText = MarkdownText.plainText(model.translationMd)
            store.add(model, view: annotation)
            return annotation
        }
        SelectionOverlay.requestInvalidate()
        Task {
            for chunk in stride(from: 0, to: annotations.count, by: 4).map({ Array(annotations[$0..<min($0 + 4, annotations.count)]) }) {
                guard self.persistence === session else { return }
                await withTaskGroup(of: Void.self) { group in
                    for annotation in chunk where annotation.status == .done {
                        group.addTask { @MainActor [weak self] in
                            guard let self, self.persistence === session,
                                  self.store.view(for: annotation.model.id) === annotation else { return }
                            await self.render(annotation, markdown: annotation.model.translationMd)
                        }
                    }
                }
            }
            guard self.persistence === session else { return }
            SelectionOverlay.requestInvalidate()
        }
    }

    // MARK: navigation

    func requestPageJump() {
        guard document != nil else { return }
        pageJumpRequest += 1
    }

    func toggleOutline() {
        guard document != nil else { return }
        showsOutline.toggle()
    }

    @discardableResult
    func goToPage(_ text: String) -> Bool {
        guard let index = PDFNavigationTarget.pageIndex(from: text, pageCount: pageCount) else {
            show("请输入 1 到 \(pageCount) 之间的页码", isError: true)
            return false
        }
        selectedOutlineID = nil
        return navigate(to: PDFNavigationTarget(pageIndex: index))
    }

    func previousPage() {
        guard canGoToPreviousPage else { return }
        _ = goToPage(String(currentPageIndex))
    }

    func nextPage() {
        guard canGoToNextPage else { return }
        _ = goToPage(String(currentPageIndex + 2))
    }

    func goToOutline(_ entry: PDFOutlineEntry) {
        guard let target = entry.target, navigate(to: target) else { return }
        selectedOutlineID = entry.id
    }

    private func navigate(to target: PDFNavigationTarget) -> Bool {
        guard let view = pdfView, let document,
              let destination = target.destination(in: document, box: view.displayBox) else { return false }
        let overlays = (view.superview?.subviews ?? []) + view.subviews
        overlays.compactMap { $0 as? SelectionOverlay }.forEach { $0.clearPending() }
        view.go(to: destination)
        currentPageIndex = target.pageIndex
        savePosition()
        SelectionOverlay.requestInvalidate()
        return true
    }

    // MARK: reading position

    private func savePosition() {
        guard positionRestored, let url = fileURL, let view = pdfView, let top = viewportTopAnchor() else { return }
        ReadingHistory.save(.init(
            page: top.page, x: top.point.x, y: top.point.y,
            scale: view.autoScales ? nil : Double(view.scaleFactor)
        ), for: url)
    }

    /// Scrolling settles → remember where the reader is (debounced).
    func viewportDidChange() {
        refreshCurrentPage()
        guard positionRestored else { return }
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.savePosition()
        }
    }

    private func refreshCurrentPage() {
        // PDFKit's cached currentPage can still refer to the previous scroll position
        // after replacing a document. Use the page actually at the viewport's top.
        guard let view = pdfView, view.document === document,
              let top = viewportTopAnchor(), currentPageIndex != top.page else { return }
        currentPageIndex = top.page
    }

    /// Writes everything pending right now (window closing, app quitting, switching files).
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        positionTask?.cancel()
        savePosition()
        return saveNow()
    }

    /// Waits for the view to be on screen with a real size (at launch it may not be yet),
    /// then attaches the file to the window and jumps to where the reader left off.
    /// Opens the gate for `savePosition` either way.
    private func finishOpening(_ url: URL, attempt: Int = 0) {
        guard fileURL == url else { return }
        guard let view = pdfView, let window = view.window, view.bounds.height >= 1 else {
            if attempt < 40 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self?.finishOpening(url, attempt: attempt + 1)
                }
            } else {
                positionRestored = true
            }
            return
        }
        // Title-bar proxy icon: ⌘-click shows the path, drag it like the file itself.
        window.representedURL = url
        if window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(view)
        }
        defer {
            positionRestored = true
            refreshCurrentPage()
            SelectionOverlay.requestInvalidate()
        }
        guard let position = ReadingHistory.position(for: url),
              let doc = document, position.page < doc.pageCount else { return }
        if let scale = position.scale {
            view.autoScales = false
            view.scaleFactor = CGFloat(scale)
        }
        view.layoutDocumentView()
        scroll(toTop: (position.page, CGPoint(x: position.x, y: position.y)))
    }

    /// Scrolls so a page-coordinate point sits at the top of the viewport.
    private func scroll(toTop pin: (page: Int, point: CGPoint)) {
        guard let view = pdfView, let dv = view.documentView,
              let clip = dv.enclosingScrollView?.contentView,
              let p = documentPoint(page: pin.page, point: pin.point) else { return }
        var origin = clip.bounds.origin
        origin.y = dv.isFlipped ? p.y : p.y - clip.bounds.height
        origin.y = min(max(origin.y, 0), max(dv.bounds.height - clip.bounds.height, 0))
        dv.scroll(origin)
    }

    private func documentPoint(page index: Int, point: CGPoint) -> CGPoint? {
        guard let view = pdfView, let dv = view.documentView, let page = document?.page(at: index) else { return nil }
        return dv.convert(view.convert(point, from: page), from: view)
    }

    private func viewportTopAnchor() -> (page: Int, point: CGPoint)? {
        guard let view = pdfView, let doc = document else { return nil }
        let top = CGPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + 1 : view.bounds.maxY - 1)
        guard let page = view.page(for: top, nearest: true) else { return nil }
        let index = doc.index(for: page)
        guard index != NSNotFound else { return nil }
        let p = view.convert(top, to: page)
        return (index, p)
    }

    // MARK: persistence

    func scheduleSave() {
        guard let persistence else { return }
        persistence.markChanged()
        saveTask?.cancel()
        // Strong capture: a save that's already scheduled must land even if the window closes.
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Writes pending changes immediately (debounce flush on quit / document switch).
    @discardableResult
    func saveNow() -> Bool {
        guard let persistence else { return true }
        do {
            try persistence.save(store.annotations)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            Log.write("sidecar save failed: \(error)")
            return false
        }
    }

    func exportAnnotatedPDF() {
        guard let fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "-译注.pdf"
        if let window = pdfView?.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { self?.export(to: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            export(to: url)
        }
    }

    private func export(to url: URL) {
        guard let document else { return }
        do {
            try PDFExporter.export(document: document, overlays: store.allViews, to: url)
            show("已导出 \(url.lastPathComponent)", actionTitle: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            show("导出失败：\(error.localizedDescription)", isError: true)
            Log.write("export failed: \(error)")
        }
    }

    // MARK: translation

    /// Called when the user confirms a selection. Returns false to keep the selection
    /// pending (the translation service isn't configured yet).
    func handleSelection(pageIndex: Int, rect: CGRect) -> Bool {
        guard persistence?.isReady == true else {
            show("译注尚未加载完成，请稍后再点「翻译」", isError: true)
            return false
        }
        guard AppSettings.shared.isConfigured else {
            show("先在设置中填写翻译服务，然后再点「翻译」", isError: true)
            settingsRequest += 1
            return false
        }
        guard document?.page(at: pageIndex) != nil else { return true }
        let model = Annotation(
            id: UUID(),
            page: pageIndex,
            rect: rect,
            translationMd: "",
            createdAt: Date()
        )
        let annotation = TranslationAnnotation(model: model)
        store.add(model, view: annotation)
        scheduleSave()
        translate(annotation)
        return true
    }

    /// Captures the selection from the page and sends it to the model.
    /// Used for first translation and for retrying.
    func translate(_ annotation: TranslationAnnotation) {
        let model = annotation.model
        guard AppSettings.shared.isConfigured else {
            show("先在设置中填写翻译服务", isError: true)
            settingsRequest += 1
            return
        }
        guard let view = pdfView, let source = document?.page(at: model.page),
              let png = SelectionOverlay.capture(page: source, rect: model.rect, scale: 3, box: view.displayBox) else {
            annotation.status = .failed("无法截取选区")
            SelectionOverlay.requestInvalidate()
            return
        }
        annotation.status = .loading
        SelectionOverlay.requestInvalidate()
        activeTranslations += 1
        Log.write("translate page=\(model.page) rect=\(Int(model.rect.width))x\(Int(model.rect.height))pt png=\(png.count / 1024)KB")
        let settings = AppSettings.shared
        Task {
            defer { activeTranslations -= 1 }
            do {
                let text = try await LLMClient(settings: settings).translate(imagePNG: png)
                guard store.view(for: model.id) === annotation else { return }
                annotation.model.translationMd = text
                store.update(annotation.model)
                scheduleSave()
                await render(annotation, markdown: text)
                guard store.view(for: model.id) === annotation else { return }
                annotation.status = .done
                SelectionOverlay.requestInvalidate()
            } catch {
                guard store.view(for: model.id) === annotation else { return }
                let message = LLMClient.describe(error)
                annotation.status = .failed(message)
                SelectionOverlay.requestInvalidate()
                if let error = error as? LLMClient.LLMError, error.needsSettingsReview {
                    show("请检查翻译服务设置，修改后点击失败的译文框重试", isError: true,
                         actionTitle: "打开设置") { [weak self] in
                        self?.settingsRequest += 1
                    }
                }
                Log.write("translation failed (\((error as NSError).domain), \((error as NSError).code))")
            }
        }
    }

    var currentMaxInnerWidth: CGFloat {
        if let workspace = pdfView?.superview as? ReaderWorkspaceView, workspace.bounds.width > 0 {
            let sRect = workspace.overlay.sidebarRect
            let cardWidth = max(sRect.width - CardSidebarLayout.cardHorizontalInset * 2, 100)
            return max(cardWidth - 2 * TranslationAnnotation.cardInsetX, TranslationAnnotation.minInnerWidth)
        }
        return TranslationAnnotation.defaultRenderWidth
    }

    func sidebarWidthDidChange() {
        let newMaxInner = currentMaxInnerWidth
        guard abs(newMaxInner - lastRenderedMaxInnerWidth) >= 6 else { return }
        sidebarRenderTask?.cancel()
        sidebarRenderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            let targetInner = self.currentMaxInnerWidth
            guard abs(targetInner - self.lastRenderedMaxInnerWidth) >= 6 else { return }
            self.lastRenderedMaxInnerWidth = targetInner
            let candidates = self.store.allViews.filter {
                $0.status == .done && TranslationAnnotation.isFullWidthContent($0.model.translationMd)
            }
            guard !candidates.isEmpty else { return }
            for annotation in candidates {
                guard !Task.isCancelled else { return }
                await self.render(annotation, markdown: annotation.model.translationMd)
            }
            SelectionOverlay.requestInvalidate()
        }
    }

    /// Typesets Markdown/LaTeX at an adaptive content width so compact cards shrink-to-fit
    /// while full-width paragraphs expand to match the current sidebar width.
    func render(_ annotation: TranslationAnnotation, markdown: String) async {
        let maxInner = currentMaxInnerWidth
        lastRenderedMaxInnerWidth = maxInner
        let width = TranslationAnnotation.preferredRenderWidth(for: markdown, maxInnerWidth: maxInner)
        let doc = try? await MarkdownRenderer.shared.render(
            markdown: markdown,
            width: width,
            fontSize: TranslationAnnotation.renderFontSize,
            fitToContent: true
        )
        guard store.view(for: annotation.model.id) === annotation,
              annotation.model.translationMd == markdown else { return }
        if let doc {
            annotation.rendered = doc
            annotation.fallbackText = nil
        } else {
            annotation.rendered = nil
            annotation.fallbackText = MarkdownText.plainText(markdown)
        }
    }

    // MARK: annotation actions

    /// Single click retries failed translations; completed translations remain visible in the sidebar.
    func click(_ annotation: TranslationAnnotation) {
        if case .failed = annotation.status {
            translate(annotation)
        }
    }

    func copyTranslation(_ annotation: TranslationAnnotation) {
        let text = annotation.model.translationMd
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("译文已拷贝")
    }

    func beginEdit(_ annotation: TranslationAnnotation) {
        guard !annotation.isLoading else { return }
        editing = AnnotationEditSession(
            id: annotation.model.id,
            draft: annotation.model.translationMd,
            pageIndex: annotation.model.page,
            previewWidth: max(annotation.bounds.width - 2 * TranslationAnnotation.cardInsetX,
                              TranslationAnnotation.defaultRenderWidth)
        )
    }

    func commitEdit(_ session: AnnotationEditSession) {
        editing = nil
        guard let annotation = store.view(for: session.id),
              session.draft != annotation.model.translationMd || annotation.status != .done else { return }
        annotation.model.translationMd = session.draft
        store.update(annotation.model)
        scheduleSave()
        annotation.status = .done
        annotation.rendered = nil
        annotation.fallbackText = MarkdownText.plainText(session.draft)
        SelectionOverlay.requestInvalidate()
        Task {
            await render(annotation, markdown: session.draft)
            guard store.view(for: session.id) === annotation else { return }
            SelectionOverlay.requestInvalidate()
        }
    }

    func cancelEdit() {
        editing = nil
    }

    func delete(_ annotation: TranslationAnnotation) {
        let id = annotation.model.id
        guard let index = store.remove(id: id) else { return }
        if editing?.id == id { editing = nil }
        scheduleSave()
        SelectionOverlay.requestInvalidate()
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.reinsert(annotation, at: index) }
        }
        undoManager?.setActionName("删除译文框")
        show("已删除译文框", actionTitle: "撤销") { [weak self] in
            self?.undoManager?.undo()
        }
    }

    private func reinsert(_ annotation: TranslationAnnotation, at index: Int) {
        guard store.view(for: annotation.model.id) == nil else { return }
        store.insert(annotation.model, view: annotation, at: index)
        scheduleSave()
        SelectionOverlay.requestInvalidate()
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.delete(annotation) }
        }
        undoManager?.setActionName("删除译文框")
        dismissToast()
    }

    // MARK: zoom

    func zoomIn() { pdfView?.zoomIn(nil); savePosition() }
    func zoomOut() { pdfView?.zoomOut(nil); savePosition() }

    func actualSize() {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = 1.0
        savePosition()
    }

    func fit() {
        guard let view = pdfView else { return }
        view.autoScales = true
        view.layoutDocumentView()
        savePosition()
    }
}
