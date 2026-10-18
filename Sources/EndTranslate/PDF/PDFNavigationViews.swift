import SwiftUI
import PDFKit

struct PageNavigationControls: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        HStack(spacing: 7) {
            Button { model.previousPage() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoToPreviousPage)
            .help("上一页（⌥⌘←）")
            .accessibilityLabel("上一页")

            PageNumberField(model: model)
                .frame(width: 54)
                .help("输入页码后按 Return 跳转（⌘L）")
            Text("/ \(model.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel("共 \(model.pageCount) 页")

            Button { model.nextPage() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoToNextPage)
            .help("下一页（⌥⌘→）")
            .accessibilityLabel("下一页")
        }
        .buttonStyle(.borderless)
        .disabled(model.document == nil)
    }
}

/// An AppKit field can reliably become the first responder inside an NSToolbar.
/// SwiftUI FocusState does not always transfer keyboard focus across that boundary.
private struct PageNumberField: NSViewRepresentable {
    @ObservedObject var model: PDFViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.placeholderString = "页码"
        field.setAccessibilityLabel("页码")
        field.identifier = NSUserInterfaceItemIdentifier("page-number")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        field.isEnabled = model.document != nil
        if coordinator.document !== model.document {
            coordinator.document = model.document
            coordinator.isEditing = false
            if field.currentEditor() != nil { field.window?.makeFirstResponder(model.pdfView) }
        }
        if !coordinator.isEditing { field.stringValue = coordinator.pageNumber }
        guard coordinator.lastJumpRequest != model.pageJumpRequest else { return }
        coordinator.lastJumpRequest = model.pageJumpRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, field.isEnabled else { return }
            field.stringValue = coordinator.pageNumber
            let window = coordinator.model.pdfView?.window ?? field.window
            window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: PDFViewModel
        weak var document: PDFDocument?
        var isEditing = false
        var lastJumpRequest: Int
        var pageNumber: String { String(model.pageCount == 0 ? 0 : model.currentPageIndex + 1) }

        init(model: PDFViewModel) {
            self.model = model
            self.lastJumpRequest = model.pageJumpRequest
        }

        func controlTextDidBeginEditing(_ notification: Notification) { isEditing = true }

        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            (notification.object as? NSTextField)?.stringValue = pageNumber
        }

        @objc func submit(_ sender: NSTextField) {
            guard model.goToPage(sender.stringValue) else {
                sender.selectText(nil)
                return
            }
            isEditing = false
            sender.stringValue = pageNumber
            sender.window?.makeFirstResponder(model.pdfView)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let field = control as? NSTextField {
                // Handle Return before end-editing resets the field to the current page.
                submit(field)
                return true
            }
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            isEditing = false
            (control as? NSTextField)?.stringValue = pageNumber
            control.window?.makeFirstResponder(model.pdfView)
            return true
        }
    }
}

struct PDFOutlineSidebar: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目录").font(.headline)
                Spacer()
                Button { model.toggleOutline() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless)
                    .help("收起目录（⌥⌘1）")
                    .accessibilityLabel("收起目录")
            }
            .padding(12)
            Divider()
            if model.outline.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent").font(.largeTitle)
                    Text("此 PDF 没有内嵌目录").font(.callout)
                    Text("可使用顶部页码跳转").font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.outline, children: \.children) { entry in
                    Button { model.goToOutline(entry) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.title)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let target = entry.target {
                                Text(String(target.pageIndex + 1))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.target == nil)
                    .help(entry.title)
                    .listRowBackground(model.selectedOutlineID == entry.id
                        ? Color(nsColor: ReaderTheme.chromeAccent).opacity(0.14)
                        : Color.clear)
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
