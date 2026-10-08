import SwiftUI
import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static var closeChecks: [UUID: () -> Bool] = [:]
    static var cleanups: [UUID: () -> Void] = [:]
    static var closeCancellations: [UUID: () -> Void] = [:]
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for check in Array(Self.closeChecks.values) where !check() {
            for resume in Array(Self.closeCancellations.values) { resume() }
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        for cleanup in Array(Self.cleanups.values) { cleanup() }
    }
}

/// Forward SwiftUI's window delegate methods while adding the unsaved-document check.
struct DocumentWindowGuard: NSViewRepresentable {
    let edited: Bool
    let canClose: () -> Bool
    let onClose: () -> Void
    let onTerminate: () -> Void
    var onCancelClose: () -> Void = {}

    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {
        view.proxy.canClose = canClose
        view.proxy.onClose = onClose
        view.proxy.onCancelClose = onCancelClose
        view.edited = edited
        view.window?.isDocumentEdited = edited
        ApplicationDelegate.closeChecks[view.proxy.id] = canClose
        ApplicationDelegate.cleanups[view.proxy.id] = onTerminate
        ApplicationDelegate.closeCancellations[view.proxy.id] = onCancelClose
    }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) {
        ApplicationDelegate.closeChecks.removeValue(forKey: view.proxy.id)
        ApplicationDelegate.cleanups.removeValue(forKey: view.proxy.id)
        ApplicationDelegate.closeCancellations.removeValue(forKey: view.proxy.id)
        if view.window?.delegate === view.proxy { view.window?.delegate = view.proxy.previous }
    }

    final class GuardView: NSView {
        let proxy = DelegateProxy()
        var edited = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if window.delegate !== proxy {
                proxy.previous = window.delegate
                window.delegate = proxy
            }
            window.isDocumentEdited = edited
        }
    }
    final class DelegateProxy: NSObject, NSWindowDelegate {
        let id = UUID()
        weak var previous: NSWindowDelegate?
        var canClose: () -> Bool = { true }
        var onClose: () -> Void = {}
        var onCancelClose: () -> Void = {}
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let allowed = canClose() && (previous?.windowShouldClose?(sender) ?? true)
            if !allowed { onCancelClose() }
            return allowed
        }
        func windowWillClose(_ notification: Notification) {
            ApplicationDelegate.closeChecks.removeValue(forKey: id)
            ApplicationDelegate.cleanups.removeValue(forKey: id)
            ApplicationDelegate.closeCancellations.removeValue(forKey: id)
            onClose()
            previous?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous }
    }
}
