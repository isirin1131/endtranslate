import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = PDFViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HSplitView {
            if model.showsOutline {
                PDFOutlineSidebar(model: model)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 340)
            }
            reader
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
            .navigationTitle(model.document == nil ? "EndTranslate" : model.fileName)
            .navigationSubtitle(model.pageLabel)
            .toolbar { toolbar }
            .sheet(item: $model.editing) { session in
                AnnotationEditorView(session: session, model: model)
            }
            .background(WindowSaveGuard(model: model))
            .focusedSceneObject(model)
            .onAppear {
                AppDelegate.reader = model
                model.undoManager = undoManager
                if let url = OpenRequests.takePending() {
                    model.open(url: url)
                } else {
                    model.restoreLastSession()
                }
            }
            .onChange(of: undoManager) { model.undoManager = undoManager }
            .onDisappear { model.flush() }
            .onReceive(NotificationCenter.default.publisher(for: OpenRequests.notification)) { _ in
                if let url = OpenRequests.takePending() { model.open(url: url) }
            }
            .onChange(of: model.settingsRequest) { openSettings() }
    }

    private var reader: some View {
        PDFDocumentView(model: model)
            .overlay {
                if model.document == nil {
                    EmptyStateView(model: model, settings: settings)
                }
            }
            .overlay(alignment: .bottom) {
                StatusPill(model: model)
                    .padding(.bottom, 18)
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.openPanel() } label: {
                Label("打开", systemImage: "doc.badge.plus")
            }
            .help("打开 PDF（⌘O）")
        }
        ToolbarItem(placement: .navigation) {
            Button { model.toggleOutline() } label: {
                Label("目录", systemImage: "sidebar.left")
            }
            .help("显示或收起目录（⌥⌘1）")
            .disabled(model.document == nil)
        }
        ToolbarItem(placement: .principal) {
            PageNavigationControls(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { model.zoomOut() } label: {
                    Label("缩小", systemImage: "minus.magnifyingglass")
                }
                .help("缩小（⌘-）")
                Button { model.zoomIn() } label: {
                    Label("放大", systemImage: "plus.magnifyingglass")
                }
                .help("放大（⌘=）")
            }
            .disabled(model.document == nil)

            Button { model.exportAnnotatedPDF() } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出带译文的 PDF（⇧⌘E）")
            .disabled(model.document == nil)

            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .help("翻译服务设置（⌘,）")
        }
    }
}

/// First screen: what the app does, how to start, and where you left off.
private struct EmptyStateView: View {
    @ObservedObject var model: PDFViewModel
    @ObservedObject var settings: AppSettings
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                .symbolEffect(.bounce, value: dropTargeted)

            VStack(spacing: 6) {
                Text("拖入 PDF 开始阅读")
                    .font(.title2.weight(.semibold))
                Text("在页面上框选任意段落，译文卡片将显示在右侧栏并与原文连线")
                    .foregroundStyle(.secondary)
            }

            Button {
                model.openPanel()
            } label: {
                Text("打开 PDF…").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 18) {
                Tip(symbol: "rectangle.dashed", text: "框选 → 调整 → 确认")
                Tip(symbol: "point.topleft.down.curvedto.point.bottomright.up", text: "侧栏卡片随原文同步滚动")
                Tip(symbol: "cursorarrow.click.2", text: "双击编辑译文")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !settings.isConfigured {
                SettingsLink {
                    Label("尚未配置翻译服务，前往设置", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.link)
            }

            if !model.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近打开")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.bottom, 4)
                    ForEach(model.recentFiles.prefix(5), id: \.self) { url in
                        RecentRow(url: url) { model.open(url: url) }
                    }
                }
                .frame(width: 360)
                .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in model.open(url: url) }
            }
            return true
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
    }
}

/// Bottom-center capsule: progress while translating, otherwise the latest toast.
private struct StatusPill: View {
    @ObservedObject var model: PDFViewModel

    var body: some View {
        Group {
            if let error = model.saveError {
                HStack(spacing: 8) {
                    Label("译注尚未保存，请检查文件夹权限和剩余空间", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Button("重试保存") { model.saveNow() }
                        .buttonStyle(.link)
                }
                .help(error)
                .pill()
            } else if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Color.orange : Color.green)
                    Text(toast.message)
                        .lineLimit(2)
                    if let title = toast.actionTitle {
                        Button(title) {
                            toast.action?()
                            model.dismissToast()
                        }
                        .buttonStyle(.link)
                    }
                }
                .id(toast.id)
                .pill()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.isPreparingDocument {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入译注…")
                }
                .pill()
            } else if model.activeTranslations > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.activeTranslations == 1 ? "正在翻译…" : "正在翻译 \(model.activeTranslations) 处…")
                        .monospacedDigit()
                }
                .pill()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast?.id)
        .animation(.spring(duration: 0.3), value: model.activeTranslations > 0)
    }
}

private extension View {
    func pill() -> some View {
        self
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            .frame(maxWidth: 560)
    }
}
