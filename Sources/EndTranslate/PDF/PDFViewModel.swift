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
    @Published var editing: AnnotationEditSession?
    @Published var toast: Toast?
    @Published private(set) var activeTranslations = 0
    @Published private(set) var recentFiles: [URL] = ReadingHistory.recent()
    /// Bumped to ask the view layer to open the Settings window.
    @Published var settingsRequest = 0

    let store = AnnotationStore()
    /// Untouched copy: source for screenshots and for re-slicing pages when gaps change.
    /// `document` is the displayed copy whose pages get replaced by gapped versions.
    private var originalDocument: PDFDocument?
    /// Keeps the one-page documents backing replaced pages alive.
    private var pageSources: [Int: PDFDocument] = [:]
    private(set) var fileURL: URL?
    private var pdfSha256: String?
    private var saveTask: Task<Void, Never>?
    private var saveDirty = false
    private var positionRestored = false
    private var positionTask: Task<Void, Never>?
    /// The sidecar on disk belongs to another version of this PDF: keep a copy before replacing it.
    private var backupSidecarBeforeSave = false
    private var toastTask: Task<Void, Never>?
    weak var pdfView: PDFView?
    weak var undoManager: UndoManager?
    private var observers: [NSObjectProtocol] = []

    var pageLabel: String {
        guard let total = document?.pageCount else { return "" }
        return "第 \(currentPageIndex + 1) / \(total) 页"
    }

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let view = note.object as? PDFView, view === self.pdfView,
                      let page = view.currentPage, let doc = self.document else { return }
                let index = doc.index(for: page)
                guard index != NSNotFound else { return }
                self.currentPageIndex = index
                self.savePosition()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
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
        if url == fileURL { return }
        guard let doc = PDFDocument(url: url), let original = PDFDocument(url: url) else {
            show("无法打开 \(url.lastPathComponent)", isError: true)
            return
        }
        if doc.isLocked {
            show("暂不支持加密的 PDF", isError: true)
            return
        }
        // Flush the outgoing document before its state is replaced.
        flush()
        saveTask?.cancel()
        editing = nil

        originalDocument = original
        pageSources.removeAll()
        document = doc
        fileURL = url
        fileName = url.lastPathComponent
        currentPageIndex = 0
        pdfSha256 = nil
        store.removeAll()
        // Installing the document posts page-changed notifications; until the saved
        // position is restored they must not overwrite it with "page 1".
        positionRestored = false
        backupSidecarBeforeSave = false
        pdfView?.document = doc
        pdfView?.autoScales = true
        pdfView?.layoutDocumentView()
        finishOpening(url)

        ReadingHistory.noteOpened(url)
        recentFiles = ReadingHistory.recent()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        Task {
            // Hashing a large PDF takes a moment; keep it off the main thread.
            let sha = await Task.detached(priority: .userInitiated) { SidecarIO.sha256(of: url) }.value
            guard self.fileURL == url else { return }
            self.pdfSha256 = sha
            self.restoreAnnotations(for: url)
            // Anything created while hashing couldn't be saved yet.
            if self.saveDirty { self.scheduleSave() }
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

    private func restoreAnnotations(for url: URL) {
        let models: [Annotation]
        switch SidecarIO.load(for: url, pdfSha256: pdfSha256) {
        case .missing:
            return
        case .mismatch:
            // The PDF changed since these were made; their positions may no longer fit.
            // Keep the old file around instead of silently overwriting it on the next save.
            backupSidecarBeforeSave = true
            show("已有的译注属于此文件的另一版本，未加载（再次保存前会备份为 .bak）", isError: true)
            return
        case .loaded(let loaded):
            models = loaded
        }
        guard !models.isEmpty else { return }
        let annotations = models.map { model -> TranslationAnnotation in
            let annotation = TranslationAnnotation(model: model)
            // An empty translation was in flight or failed when the app last closed.
            annotation.status = model.translationMd.isEmpty ? .failed("上次未完成") : .done
            store.add(model, view: annotation)
            return annotation
        }
        Task {
            for chunk in stride(from: 0, to: annotations.count, by: 4).map({ Array(annotations[$0..<min($0 + 4, annotations.count)]) }) {
                await withTaskGroup(of: Void.self) { group in
                    for annotation in chunk where annotation.status == .done {
                        group.addTask { @MainActor [weak self] in
                            await self?.render(annotation, markdown: annotation.model.translationMd)
                        }
                    }
                }
            }
            guard self.fileURL == url else { return }
            for page in Set(models.map(\.page)).sorted() { relayout(page: page) }
        }
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
        guard positionRestored else { return }
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.savePosition()
        }
    }

    /// Writes everything pending right now (window closing, app quitting, switching files).
    func flush() {
        positionTask?.cancel()
        savePosition()
        saveNow()
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
        defer {
            positionRestored = true
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

    /// Scrolls so an original-coordinate point sits at the top of the viewport.
    private func scroll(toTop pin: (page: Int, point: CGPoint)) {
        guard let view = pdfView, let dv = view.documentView,
              let clip = dv.enclosingScrollView?.contentView,
              let p = documentPoint(page: pin.page, original: pin.point) else { return }
        var origin = clip.bounds.origin
        origin.y = dv.isFlipped ? p.y : p.y - clip.bounds.height
        origin.y = min(max(origin.y, 0), max(dv.bounds.height - clip.bounds.height, 0))
        dv.scroll(origin)
    }

    // MARK: gap layout

    /// Re-slices one page so every annotation on it gets a slot right above its selection,
    /// swaps the page into the displayed document and positions the boxes in their slots.
    /// `anchor` (original page coordinates) stays fixed on screen; defaults to the viewport top.
    func relayout(page index: Int, anchor: (page: Int, point: CGPoint)? = nil) {
        guard let doc = document, let original = originalDocument,
              let source = original.page(at: index), let view = pdfView else { return }
        let box = view.displayBox
        let pageBounds = source.bounds(for: box)
        let annotations = store.annotations.filter { $0.page == index }.compactMap { store.view(for: $0.id) }
        let layout = GapLayout(annotations.map {
            PageGap(id: $0.model.id, y: min($0.model.rect.maxY, pageBounds.maxY), height: $0.gapHeight(pageWidth: pageBounds.width))
        })
        let oldLayout = store.layout(for: index)

        let pin = anchor ?? viewportTopAnchor()
        let before = pin.flatMap { documentPoint(page: $0.page, original: $0.point) }
        let clip = view.documentView?.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin

        let replacement: PDFPage?
        if layout.gaps.isEmpty && oldLayout.gaps.isEmpty {
            replacement = nil
        } else if layout.gaps.isEmpty {
            replacement = source.copy() as? PDFPage
            pageSources[index] = nil
        } else if let built = PageGapper.build(from: source, layout: layout, box: box) {
            replacement = built.page
            pageSources[index] = built.document
        } else {
            Log.write("gap rebuild failed page=\(index)")
            return
        }
        store.setLayout(layout, for: index)
        if let replacement, index < doc.pageCount {
            doc.removePage(at: index)
            doc.insert(replacement, at: index)
            view.layoutDocumentView()
        }
        let expandedBounds = CGRect(x: pageBounds.minX, y: pageBounds.minY,
                                    width: pageBounds.width, height: pageBounds.height + layout.totalHeight)
        for annotation in annotations {
            guard let slot = layout.slot(for: annotation.model.id) else { continue }
            annotation.place(slotMinY: slot.minY, slotHeight: slot.height, pageBounds: expandedBounds)
        }

        if let pin, let before, let after = documentPoint(page: pin.page, original: pin.point),
           let clip, let origin, let dv = view.documentView {
            var target = origin
            target.y += after.y - before.y
            target.y = min(max(target.y, 0), max(dv.bounds.height - clip.bounds.height, 0))
            dv.scroll(target)
        }
        SelectionOverlay.requestInvalidate()
    }

    /// An original-coordinate point in documentView coordinates, under the current layout.
    private func documentPoint(page index: Int, original point: CGPoint) -> CGPoint? {
        guard let view = pdfView, let dv = view.documentView, let page = document?.page(at: index) else { return nil }
        let expanded = CGPoint(x: point.x, y: store.layout(for: index).expand(point.y))
        return dv.convert(view.convert(expanded, from: page), from: view)
    }

    private func viewportTopAnchor() -> (page: Int, point: CGPoint)? {
        guard let view = pdfView, let doc = document else { return nil }
        let top = CGPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + 1 : view.bounds.maxY - 1)
        guard let page = view.page(for: top, nearest: true) else { return nil }
        let index = doc.index(for: page)
        guard index != NSNotFound else { return nil }
        var p = view.convert(top, to: page)
        p.y = store.layout(for: index).collapse(p.y)
        return (index, p)
    }

    /// Selection's top-left stays put while its slot opens above it.
    private func anchor(for model: Annotation) -> (page: Int, point: CGPoint) {
        (model.page, CGPoint(x: model.rect.minX, y: model.rect.maxY))
    }

    // MARK: persistence

    func scheduleSave() {
        guard fileURL != nil else { return }
        saveDirty = true
        saveTask?.cancel()
        // Strong capture: a save that's already scheduled must land even if the window closes.
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Writes pending changes immediately (debounce flush on quit / document switch).
    func saveNow() {
        guard saveDirty, let fileURL, let pdfSha256 else { return }
        saveDirty = false
        if backupSidecarBeforeSave {
            backupSidecarBeforeSave = false
            SidecarIO.backup(for: fileURL)
        }
        SidecarIO.save(store.annotations, pdfSha256: pdfSha256, for: fileURL)
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
        guard AppSettings.shared.isConfigured else {
            show("先在设置中填写翻译服务，然后再点「翻译」", isError: true)
            settingsRequest += 1
            return false
        }
        guard originalDocument?.page(at: pageIndex) != nil else { return true }
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

    /// Captures the selection from the untouched page and sends it to the model.
    /// Used for first translation and for retrying.
    func translate(_ annotation: TranslationAnnotation) {
        let model = annotation.model
        guard AppSettings.shared.isConfigured else {
            show("先在设置中填写翻译服务", isError: true)
            settingsRequest += 1
            return
        }
        guard let view = pdfView, let source = originalDocument?.page(at: model.page),
              let png = SelectionOverlay.capture(page: source, rect: model.rect, scale: 3, box: view.displayBox) else {
            annotation.status = .failed("无法截取选区")
            relayout(page: model.page, anchor: anchor(for: model))
            return
        }
        annotation.status = .loading
        annotation.showsOriginal = false
        relayout(page: model.page, anchor: anchor(for: model))
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
                annotation.status = .done
                relayout(page: model.page, anchor: anchor(for: model))
            } catch {
                guard store.view(for: model.id) === annotation else { return }
                let message = LLMClient.describe(error)
                annotation.status = .failed(message)
                relayout(page: model.page, anchor: anchor(for: model))
                Log.write("translation failed: \(error)")
            }
        }
    }

    /// Compiles the translation with typst at the selection's width; the slot height follows the result.
    func render(_ annotation: TranslationAnnotation, markdown: String) async {
        let pageWidth = originalDocument?.page(at: annotation.model.page)?.bounds(for: pdfView?.displayBox ?? .cropBox).width ?? 600
        let width = min(max(annotation.model.rect.width, 140), max(pageWidth - 4, 40))
        if let doc = try? await TypstRenderer.shared.render(markdown: markdown, width: width, fontSize: 10) {
            annotation.rendered = doc
            annotation.fallbackText = nil
        } else {
            annotation.rendered = nil
            annotation.fallbackText = MarkdownToTypst.plainText(markdown)
        }
    }

    // MARK: annotation actions

    /// Single click: failed boxes retry, others switch between translation and original.
    func click(_ annotation: TranslationAnnotation) {
        switch annotation.status {
        case .failed: translate(annotation)
        case .loading: break
        case .done: toggleOriginal(annotation)
        }
    }

    func toggleOriginal(_ annotation: TranslationAnnotation) {
        annotation.showsOriginal.toggle()
        relayout(page: annotation.model.page, anchor: anchor(for: annotation.model))
    }

    func toggleAllTranslations() {
        let views = store.allViews
        guard !views.isEmpty else { return }
        let collapse = views.contains { !$0.showsOriginal }
        let pin = viewportTopAnchor()
        for view in views { view.showsOriginal = collapse }
        for page in Set(views.map(\.model.page)).sorted() { relayout(page: page, anchor: pin) }
        show(collapse ? "已收起全部译文" : "已展开全部译文")
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
            previewWidth: max(annotation.bounds.width, 220)
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
        annotation.showsOriginal = false
        Task {
            await render(annotation, markdown: session.draft)
            relayout(page: annotation.model.page, anchor: anchor(for: annotation.model))
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
        relayout(page: annotation.model.page, anchor: anchor(for: annotation.model))
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
        relayout(page: annotation.model.page, anchor: anchor(for: annotation.model))
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
