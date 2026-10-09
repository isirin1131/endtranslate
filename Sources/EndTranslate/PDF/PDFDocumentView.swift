import SwiftUI
import PDFKit

struct PDFDocumentView: NSViewRepresentable {
    @ObservedObject var model: PDFViewModel

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // Follows light/dark appearance like Preview's page backdrop.
        view.backgroundColor = .underPageBackgroundColor
        model.pdfView = view
        let overlay = SelectionOverlay(pdfView: view)
        overlay.frame = view.bounds
        overlay.store = model.store
        view.addSubview(overlay)
        overlay.onSelection = { [weak model] page, rect in
            model?.handleSelection(pageIndex: page, rect: rect) ?? true
        }
        overlay.onClickAnnotation = { [weak model] annotation in
            model?.click(annotation)
        }
        overlay.onToggleOriginal = { [weak model] annotation in
            model?.toggleOriginal(annotation)
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
        overlay.onViewportChange = { [weak model] in
            model?.viewportDidChange()
        }
        if let doc = model.document {
            view.document = doc
        }
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var document: PDFDocument?
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // The model installs documents itself (it needs the view laid out right away);
        // here we only drop interaction state that belonged to the previous one.
        guard context.coordinator.document !== model.document else { return }
        context.coordinator.document = model.document
        if nsView.document !== model.document {
            nsView.document = model.document
        }
        nsView.subviews.compactMap { $0 as? SelectionOverlay }.forEach { $0.clearPending() }
    }
}
