import SwiftUI
import PDFKit

/// Hosts the PDFView in the left panel and the floating card sidebar in the right panel,
/// with SelectionOverlay spanning both so leader lines can connect source boxes to sidebar cards.
final class ReaderWorkspaceView: NSView {
    let pdfView: PDFView
    let overlay: SelectionOverlay
    var onSidebarWidthUpdate: (() -> Void)?

    init(pdfView: PDFView, overlay: SelectionOverlay) {
        self.pdfView = pdfView
        self.overlay = overlay
        super.init(frame: .zero)
        autoresizesSubviews = false
        addSubview(pdfView)
        addSubview(overlay)
        overlay.onSidebarWidthChange = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
            self?.onSidebarWidthUpdate?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        let targetPDFRect = overlay.pdfPanelRect
        if pdfView.frame != targetPDFRect {
            pdfView.frame = targetPDFRect
            if pdfView.autoScales {
                pdfView.layoutDocumentView()
            }
            onSidebarWidthUpdate?()
        }
    }
}

struct PDFDocumentView: NSViewRepresentable {
    @ObservedObject var model: PDFViewModel

    func makeNSView(context: Context) -> ReaderWorkspaceView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // Follows light/dark appearance like Preview's page backdrop.
        view.backgroundColor = .underPageBackgroundColor
        model.pdfView = view
        let overlay = SelectionOverlay(pdfView: view)
        overlay.store = model.store
        let workspace = ReaderWorkspaceView(pdfView: view, overlay: overlay)
        overlay.onSelection = { [weak model] page, rect in
            model?.handleSelection(pageIndex: page, rect: rect) ?? true
        }
        overlay.onClickAnnotation = { [weak model] annotation in
            model?.click(annotation)
        }
        overlay.onEditAnnotation = { [weak model] annotation in
            model?.beginEdit(annotation)
        }
        overlay.onDeleteAnnotation = { [weak model] annotation in
            model?.delete(annotation)
        }
        overlay.onRetranslateAnnotation = { [weak model] annotation in
            model?.translate(annotation)
        }
        overlay.onCopyAnnotation = { [weak model] annotation in
            model?.copyTranslation(annotation)
        }
        overlay.onOpenFile = { [weak model] url in
            model?.open(url: url)
        }
        overlay.onAnnotationBecameVisible = { [weak model] annotation in
            model?.ensureRendered(annotation)
        }
        overlay.onViewportChange = { [weak model] in
            model?.viewportDidChange()
        }
        workspace.onSidebarWidthUpdate = { [weak model] in
            model?.sidebarWidthDidChange()
        }
        if let doc = model.document {
            view.document = doc
        }
        return workspace
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var document: PDFDocument?
    }

    func updateNSView(_ nsView: ReaderWorkspaceView, context: Context) {
        // The model installs documents itself (it needs the view laid out right away);
        // here we only drop interaction state that belonged to the previous one.
        guard context.coordinator.document !== model.document else { return }
        context.coordinator.document = model.document
        if nsView.pdfView.document !== model.document {
            nsView.pdfView.document = model.document
        }
        nsView.overlay.clearPending()
    }
}

