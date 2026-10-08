import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    var onCommit: () -> Void
    weak var document: DocumentTab? = nil

    // A stable SwiftUI host mounts one document's retained native editor at a time.
    // Returning the same NSScrollView from distinct representables leaves stale native views.
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        let session = makeSession()
        let changed = context.coordinator.active !== session
        if changed {
            context.coordinator.mount(session, in: host)
        }
        session.parent = self
        let textView = session.textView
        textView.backgroundColor = .clear
        textView.textColor = NSColor(themeManager.textColor)
        textView.insertionPointColor = NSColor(themeManager.textColor)
        host.appearance = NSAppearance(named: .darkAqua)
        controller.document = document
        controller.textView = textView
        session.synchronizeText()
        session.ruler.errors = Set(controller.errors.filter { $0.line > 0 }.map(\.line))
        if let document, let line = document.pendingLine {
            document.pendingLine = nil
            controller.goToLine(line)
        }
        if changed {
            session.scheduleHighlighting()
            DispatchQueue.main.async { [weak host, weak textView] in
                guard let host, let textView, textView.isDescendant(of: host) else { return }
                textView.window?.makeFirstResponder(textView)
                textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeSession() -> Session {
        if let existing = document?.editor {
            existing.parent = self
            return existing
        }
        let session = Session(self)
        document?.editor = session
        return session
    }

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        coordinator.active?.detach()
        coordinator.active?.scrollView.removeFromSuperview()
        coordinator.active = nil
    }

    @MainActor
    final class Coordinator {
        var active: Session?
        func mount(_ session: Session, in host: NSView) {
            if let old = active {
                if let responder = host.window?.firstResponder as? NSView, responder.isDescendant(of: old.scrollView) {
                    host.window?.makeFirstResponder(nil)
                }
                old.detach()
                old.scrollView.removeFromSuperview()
            }
            active = session
            session.scrollView.frame = host.bounds
            session.scrollView.autoresizingMask = [.width, .height]
            host.addSubview(session.scrollView)
        }
    }

    @MainActor
    class Session: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        func synchronizeText() {
            guard let parent, !nativeEditPending else { return }
            // Read the live document, not a value captured before an asynchronous diagnostic update.
            let content = parent.document?.source ?? parent.text
            if textView.string != content && !textView.hasMarkedText() {
                let selectedRange = textView.selectedRange()
                isSynchronizing = true
                defer { isSynchronizing = false }
                highlighter.invalidate()
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: content)
                textStorage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                           .foregroundColor: NSColor(white: 0.9, alpha: 1)],
                                          range: NSRange(location: 0, length: textStorage.length))
                textStorage.endEditing()
                scheduleHighlighting()
                if selectedRange.location + selectedRange.length <= content.utf16.count {
                    textView.setSelectedRange(selectedRange)
                }
            }
        }
        var parent: EditorView?
        let highlighter = SyntaxHighlighter()
        
        let scrollView: NSScrollView
        let textView: NSTextView
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let ruler: LineNumberRulerView
        var highlightTask: DispatchWorkItem?
        var scrollObserver: NSObjectProtocol?
        var tokenTask: Task<Void, Never>?
        var tokenizer: Task<[SyntaxHighlighter.Span], Never>?
        let documentUndoManager = UndoManager()
        var completionTask: Task<Void, Never>?
        var hoverTask: Task<Void, Never>?
        var hoverCloseTask: Task<Void, Never>?
        var completionPopover: NSPopover?
        var hoverPopover: NSPopover?
        var completionModel: CompletionPresentation?
        var completionEventMonitor: Any?
        var completionInactiveObserver: NSObjectProtocol?
        var hoverEventMonitor: Any?
        var hoverInactiveObserver: NSObjectProtocol?
        var completionToken = UUID()
        var hoverToken = UUID()
        var hoverRange: NSRange?
        var isApplyingAssistance = false
        var revision = 0
        private var nativeEditPending = false
        private var isSynchronizing = false

        @MainActor init(_ parent: EditorView) {
            self.parent = parent
            
            self.textStorage = NSTextStorage()
            self.layoutManager = NSLayoutManager()
            self.textStorage.addLayoutManager(layoutManager)
            
            self.textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            self.textContainer.widthTracksTextView = true
            self.layoutManager.addTextContainer(textContainer)
            
            self.textView = AssistTextView(frame: .zero, textContainer: textContainer)
            self.scrollView = NSScrollView()
            self.ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
            
            super.init()
            
            // --- CONFIGURATION SCROLLVIEW ---
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .noBorder
            
            // --- MODIFICATION TRANSPARENCE ---
            scrollView.drawsBackground = false // CRUCIAL: Désactive le fond gris par défaut
            scrollView.backgroundColor = .clear
            
            scrollView.documentView = textView
            ruler.clientView = textView
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeHover()
                    self?.ruler.needsDisplay = true
                    if let self { self.highlighter.renderVisible(in: self.textView) }
                }
            }
            
            // --- CONFIGURATION TEXTVIEW ---
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 0, height: 10)
            
            // --- MODIFICATION TRANSPARENCE ---
            textView.drawsBackground = false // CRUCIAL: Désactive le fond blanc par défaut
            textView.backgroundColor = .clear
            
            textView.isRichText = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            
            textView.delegate = self
            textStorage.delegate = self
            configureAssistance()

        }

        deinit {
            completionTask?.cancel(); hoverTask?.cancel(); hoverCloseTask?.cancel()
            if let completionEventMonitor { NSEvent.removeMonitor(completionEventMonitor) }
            if let completionInactiveObserver { NotificationCenter.default.removeObserver(completionInactiveObserver) }
            if let hoverEventMonitor { NSEvent.removeMonitor(hoverEventMonitor) }
            if let hoverInactiveObserver { NotificationCenter.default.removeObserver(hoverInactiveObserver) }
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Do not replace attributed text or compile provisional Chinese IME composition.
            guard !textView.hasMarkedText() else { return }
            highlighter.invalidate()
            commitCurrentText()
            scheduleHighlighting()
            if !isApplyingAssistance {
                let token = revision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.complete(explicit: false)
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            dismissAssistance()
        }

        func commitCurrentText() {
            guard let parent, !textView.hasMarkedText() else { return }
            if let document = parent.document {
                let changed = document.source != textView.string
                document.source = textView.string
                nativeEditPending = false
                // Composition may be cancelled without changing the committed source.
                if !changed { document.scheduleAutoSave() }
                if changed { NotificationCenter.default.post(name: .documentSourceDidChange, object: document) }
            } else {
                parent.text = textView.string
                nativeEditPending = false
            }
            parent.onCommit()
        }

        func detach() {
            dismissAssistance()
            parent?.controller.closeGitReview()
            parent?.controller.cancelFormatting()
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            parent = nil
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            dismissAssistance()
            parent?.document?.cancelLanguageOperation()
            if !isSynchronizing { nativeEditPending = true }
            revision &+= 1
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            // Avoid layout mutations while NSTextStorage is notifying its layout managers.
            // NSTextStorage also reports provisional IME edits, so the index never gets stale.
            parent?.controller.closeGitReview()
            parent?.controller.gitChanges = GitLineMarkers()
            ruler.applyEdit(in: storage.mutableString, editedRange: editedRange, changeInLength: delta)
        }

        func scheduleHighlighting() {
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            let scheduledRevision = revision
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.revision == scheduledRevision, !self.textView.hasMarkedText() else { return }
                let snapshot = self.textView.string
                let tokenizer = Task.detached(priority: .userInitiated) {
                    await SyntaxTokenizationWorker.shared.tokenize(snapshot)
                }
                self.tokenizer = tokenizer
                self.tokenTask = Task { @MainActor [weak self] in
                    let spans = await tokenizer.value
                    guard !Task.isCancelled, let self, self.revision == scheduledRevision, !self.textView.hasMarkedText() else { return }
                    self.highlighter.install(spans, in: self.textView)
                    self.tokenizer = nil
                    self.tokenTask = nil
                    self.parent?.controller.refreshSearch()
                }
            }
            highlightTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
        }
    }
}

/// Serialize tokenization so a retiring snapshot cannot overlap the next token buffer.
private actor SyntaxTokenizationWorker {
    static let shared = SyntaxTokenizationWorker()
    func tokenize(_ source: String) -> [SyntaxHighlighter.Span] {
        guard !Task.isCancelled else { return [] }
        return SyntaxHighlighter.spans(in: source, isCancelled: { Task.isCancelled })
    }
}
