import SwiftUI

struct AnnotationEditSession: Identifiable {
    let id: UUID
    var draft: String
    var pageIndex: Int
    var previewWidth: CGFloat
}

struct AnnotationEditorView: View {
    let session: AnnotationEditSession
    @ObservedObject var model: PDFViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var rendering = false
    private var width: CGFloat { min(max(session.previewWidth, 180), 460) }

    init(session: AnnotationEditSession, model: PDFViewModel) {
        self.session = session
        self.model = model
        _draft = State(initialValue: session.draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑译文 — 第 \(session.pageIndex + 1) 页")
                    .font(.headline)
                Spacer()
                Text(verbatim: "支持 Markdown 与 LaTeX：$x^2$ / $$\\int_0^1 x\\,dx$$")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("译文内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 300)
                }
                .padding(10)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("排版预览")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if rendering { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(Int(width)) pt 宽")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if let preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: width)
                                    .background(Color.white)
                                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                            } else if let previewError {
                                Text(previewError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    if let annotation = model.store.view(for: session.id) {
                        model.delete(annotation)
                    }
                    dismiss()
                } label: {
                    Label("删除译文框", systemImage: "trash")
                }
                Spacer()
                Text("⌘↩ 保存 · esc 取消")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("取消") {
                    model.cancelEdit()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                // ⌘↩ rather than ↩: plain Return belongs to the text editor.
                Button("保存") {
                    var updated = session
                    updated.draft = draft
                    model.commitEdit(updated)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 540)
        .task(id: draft) {
            await refreshPreview()
        }
    }

    private func refreshPreview() async {
        let source = draft
        rendering = true
        defer { if !Task.isCancelled { rendering = false } }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let doc = try? await MarkdownRenderer.shared.render(markdown: source, width: width, fontSize: TranslationAnnotation.renderFontSize)
        guard !Task.isCancelled else { return }
        if let image = doc?.nsImage(scale: 2) {
            preview = image
            previewError = nil
        } else {
            preview = nil
            previewError = "排版预览暂不可用，保存后会保留译文文本"
        }
    }
}
