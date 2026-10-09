import SwiftUI
import AppKit

/// SwiftUI owns the window delegate. Forward its callbacks while checking that
/// pending annotations are saved before the reading window is allowed to close.
struct WindowSaveGuard: NSViewRepresentable {
    let model: PDFViewModel

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.model = model
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.model = model
        view.install()
    }

    static func dismantleNSView(_ view: GuardView, coordinator: ()) {
        view.detach()
    }

    final class GuardView: NSView, NSWindowDelegate {
        weak var model: PDFViewModel?
        private weak var guardedWindow: NSWindow?
        private weak var originalDelegate: NSWindowDelegate?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            if guardedWindow !== window { detach() }
            guard let window, window.delegate !== self else { return }
            guardedWindow = window
            originalDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if guardedWindow?.delegate === self {
                guardedWindow?.delegate = originalDelegate
            }
            guardedWindow = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model?.flush() != false else { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
