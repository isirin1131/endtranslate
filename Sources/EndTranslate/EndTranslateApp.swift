import SwiftUI
import AppKit

@main
struct EndTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One reading window: opening another PDF replaces the current one.
        Window("EndTranslate", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 520)
                .tint(Color(nsColor: ReaderTheme.chromeAccent))
        }
        .defaultSize(width: 1100, height: 850)
        .commands { AppCommands() }

        Settings {
            SettingsView(settings: AppSettings.shared)
                .tint(Color(nsColor: ReaderTheme.chromeAccent))
        }
    }
}

/// Files handed to the app by Finder / `open` / the command line before or after the
/// window exists. ContentView drains it on appear and on notification. Main thread only.
enum OpenRequests {
    static let notification = Notification.Name("EndTranslateOpenRequest")
    private static var pending: URL?

    static func submit(_ url: URL) {
        pending = url
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func takePending() -> URL? {
        defer { pending = nil }
        return pending
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var reader: PDFViewModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.migrateLegacyDefaults()
        // `swift run EndTranslate paper.pdf`
        if let arg = CommandLine.arguments.dropFirst().first(where: { $0.lowercased().hasSuffix(".pdf") }) {
            let url = URL(fileURLWithPath: arg, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            if FileManager.default.fileExists(atPath: url.path) { OpenRequests.submit(url.absoluteURL) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        OpenRequests.submit(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // willTerminate is too late to cancel quitting when a write fails.
        Self.reader?.flush() == false ? .terminateCancel : .terminateNow
    }
}

struct AppCommands: Commands {
    @FocusedObject private var model: PDFViewModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { model?.openPanel() }
                .keyboardShortcut("o")
            Menu("打开最近使用") {
                ForEach(model?.recentFiles ?? [], id: \.self) { url in
                    Button(url.lastPathComponent) { model?.open(url: url) }
                }
                if !(model?.recentFiles.isEmpty ?? true) {
                    Divider()
                    Button("清除菜单") { model?.clearRecentFiles() }
                }
            }
            .disabled(model?.recentFiles.isEmpty ?? true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("导出带译文的 PDF…") { model?.exportAnnotatedPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.document == nil || model?.isExporting == true)
        }
        CommandGroup(before: .toolbar) {
            Button("前往页…") { model?.requestPageJump() }
                .keyboardShortcut("l")
                .disabled(model?.document == nil)
            Button("上一页") { model?.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model?.canGoToPreviousPage != true)
            Button("下一页") { model?.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model?.canGoToNextPage != true)
            Button("显示/收起目录") { model?.toggleOutline() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(model?.document == nil)
            Divider()
            Button("放大") { model?.zoomIn() }
                .keyboardShortcut("=")
                .disabled(model?.document == nil)
            Button("缩小") { model?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(model?.document == nil)
            Button("实际大小") { model?.actualSize() }
                .keyboardShortcut("0")
                .disabled(model?.document == nil)
            Button("适应宽度") { model?.fit() }
                .keyboardShortcut("9")
                .disabled(model?.document == nil)
            Divider()
        }
        // No help book: drop the item that would only say "Help isn't available".
        CommandGroup(replacing: .help) {}
    }
}
