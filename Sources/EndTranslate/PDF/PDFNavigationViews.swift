import SwiftUI
import PDFKit

struct PageNavigationControls: View {
    @ObservedObject var model: PDFViewModel
    @State private var isEditing = false
    @State private var isHoveringField = false

    private var digitCount: Int {
        max(String(max(model.pageCount, 1)).count, 1)
    }

    private var fieldWidth: CGFloat {
        CGFloat(digitCount) * 8.5 + 6
    }

    var body: some View {
        HStack(spacing: 2) {
            if model.pageCount > 1 {
                ChevronButton(
                    systemImage: "chevron.left",
                    help: "上一页（⌥⌘←）",
                    label: "上一页",
                    disabled: !model.canGoToPreviousPage,
                    action: model.previousPage
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                PageNumberField(model: model) { editing in
                    isEditing = editing
                }
                .frame(width: fieldWidth)
                .fixedSize(horizontal: false, vertical: true)

                Text("/ \(model.pageCount)")
                    .font(.system(size: NSFont.systemFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("共 \(model.pageCount) 页")
            }
            .padding(.horizontal, model.pageCount > 1 ? 7 : 10)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fieldBackground)
            }
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: ReaderTheme.chromeAccent).opacity(0.65), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHoveringField = $0 }
            .onTapGesture {
                if !isEditing {
                    model.requestPageJump()
                }
            }
            .help("点击或按 ⌘L 输入页码跳转")

            if model.pageCount > 1 {
                ChevronButton(
                    systemImage: "chevron.right",
                    help: "下一页（⌥⌘→）",
                    label: "下一页",
                    disabled: !model.canGoToNextPage,
                    action: model.nextPage
                )
            }
        }
        .padding(.horizontal, 2)
        .disabled(model.document == nil)
    }

    private var fieldBackground: Color {
        if isEditing { return Color.primary.opacity(0.08) }
        if isHoveringField { return Color.primary.opacity(0.05) }
        return .clear
    }
}

private struct ChevronButton: View {
    let systemImage: String
    let help: String
    let label: String
    let disabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(disabled ? .quaternary : (isHovering ? .primary : .secondary))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovering && !disabled ? Color.primary.opacity(0.07) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

private final class SeamlessPageField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing, let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }
}

/// An AppKit field can reliably become the first responder inside an NSToolbar.
/// SwiftUI FocusState does not always transfer keyboard focus across that boundary.
private struct PageNumberField: NSViewRepresentable {
    @ObservedObject var model: PDFViewModel
    var onEditingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onEditingChange: onEditingChange) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SeamlessPageField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("页码")
        field.identifier = NSUserInterfaceItemIdentifier("page-number")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.onEditingChange = onEditingChange
        field.isEnabled = model.document != nil
        if coordinator.document !== model.document {
            coordinator.document = model.document
            coordinator.setEditing(false)
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
        var onEditingChange: (Bool) -> Void
        weak var document: PDFDocument?
        var isEditing = false
        var lastJumpRequest: Int
        var pageNumber: String { String(model.pageCount == 0 ? 0 : model.currentPageIndex + 1) }

        init(model: PDFViewModel, onEditingChange: @escaping (Bool) -> Void) {
            self.model = model
            self.onEditingChange = onEditingChange
            self.lastJumpRequest = model.pageJumpRequest
        }

        func setEditing(_ editing: Bool) {
            guard isEditing != editing else { return }
            isEditing = editing
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onEditingChange(self.isEditing)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { setEditing(true) }

        func controlTextDidEndEditing(_ notification: Notification) {
            setEditing(false)
            (notification.object as? NSTextField)?.stringValue = pageNumber
        }

        @objc func submit(_ sender: NSTextField) {
            guard model.goToPage(sender.stringValue) else {
                sender.selectText(nil)
                return
            }
            setEditing(false)
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
            setEditing(false)
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
                Text("目录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
                        ? Color(nsColor: ReaderTheme.chromeAccent).opacity(0.10)
                        : Color.clear)
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
