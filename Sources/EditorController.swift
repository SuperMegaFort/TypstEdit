import SwiftUI
import AppKit

@MainActor
class EditorController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published var languageStatus = ""
    @Published private(set) var isFormatting = false
    private var formatTask: Task<Void, Never>?
    weak var document: DocumentTab?
    @Published var errors: [TypstError] = [] { didSet { needsRedraw() } }
    var gitRoot: URL?
    var gitFile: URL?
    private var gitPopover: NSPopover?
    var gitChanges = GitLineMarkers() { didSet { needsRedraw() } }
    @Published var scrollPosition: CGFloat = 0
    
    // Référence faible vers la vue native pour manipuler le texte directement
    weak var textView: NSTextView? {
        didSet {
            needsRedraw()
        }
    }
    
    // Recherche
    @Published var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                performSearch()
            }
        }
    }
    @Published var searchMatches: [NSRange] = []
    @Published var currentMatchIndex: Int = -1
    
    var matchCount: Int {
        searchMatches.count
    }
    
    // Demande de redessiner la règle (numéros de ligne)
    func needsRedraw() {
        if let ruler = textView?.enclosingScrollView?.verticalRulerView as? LineNumberRulerView {
            ruler.errors = Set(errors.filter { $0.line > 0 }.map(\.line))
            ruler.gitChanges = gitChanges
            ruler.onGitClick = { [weak self, weak ruler] line, rect in
                guard let ruler else { return }
                self?.showGitChange(line: line, rect: rect, ruler: ruler)
            }
        }
    }
    
    func showGitChange(line: Int, rect: NSRect, ruler: LineNumberRulerView) {
        guard let root = gitRoot, let file = gitFile, let textView,
              textView.window != nil, !textView.hasMarkedText() else { return }
        closeGitReview()
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 620, height: 340)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: GitHunkPopover(root: root, file: file,
            source: textView.string, line: line, close: { [weak self] in self?.closeGitReview() }))
        gitPopover = popover
        popover.show(relativeTo: rect, of: ruler, preferredEdge: .maxX)
    }

    func closeGitReview() {
        let old = gitPopover
        gitPopover = nil
        old?.close()
        old?.contentViewController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === gitPopover {
            gitPopover = nil
            closed.contentViewController = nil
        }
    }

    func requestCompletion() { document?.editor?.complete(explicit: true) }
    func formatDocument() {
        guard let document, !isFormatting, document.editor?.textView.hasMarkedText() != true else { return }
        isFormatting = true; languageStatus = L10n.text("Formatting…", "正在格式化…")
        formatTask = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            defer { self.isFormatting = false; self.formatTask = nil }
            do { try await document.formatSource(requireActive: true); self.languageStatus = L10n.text("Formatted", "已格式化") }
            catch is CancellationError { self.languageStatus = L10n.text("Formatting cancelled; draft retained.", "格式化已取消，草稿保留。") }
            catch { self.languageStatus = error.localizedDescription }
        }
    }
    func cancelFormatting() { formatTask?.cancel() }

    // --- Undo/Redo Functions ---
    
    func undo() {
        textView?.undoManager?.undo()
    }
    
    func redo() {
        textView?.undoManager?.redo()
    }
    
    // --- Snippet Functions ---
    
    func insertTableSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("table", into: textView)
    }
    
    func insertImageSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("image", into: textView)
    }
    
    func insertChartSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("chart", into: textView)
    }
    
    func insertTimelineSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("timeline", into: textView)
    }
    
    // --- Search Functions ---
    
    func performSearch(scrollToFirst: Bool = true) {
        guard let textView = textView, !searchQuery.isEmpty else {
            clearSearch()
            return
        }
        
        let text = textView.string
        searchMatches = []
        
        // Find all matches (case-insensitive)
        let searchOptions: NSString.CompareOptions = [.caseInsensitive]
        var searchRange = NSRange(location: 0, length: text.utf16.count)
        
        while searchRange.location < text.utf16.count {
            let foundRange = (text as NSString).range(of: searchQuery, options: searchOptions, range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            searchMatches.append(foundRange)
            searchRange = NSRange(location: foundRange.location + foundRange.length, 
                                length: text.utf16.count - (foundRange.location + foundRange.length))
        }
        
        // Highlight all matches
        if !searchMatches.isEmpty {
            currentMatchIndex = scrollToFirst ? 0 : min(max(0, currentMatchIndex), searchMatches.count - 1)
            highlightMatches()
            if scrollToFirst { scrollToMatch(at: 0) }
        } else {
            clearSearch()
        }
    }
    
    func highlightMatches() {
        guard let textView = textView, let textStorage = textView.textStorage else { return }
        
        // Remove previous highlights
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
        
        // Highlight all matches in yellow
        for (index, range) in searchMatches.enumerated() {
            let isCurrentMatch = (index == currentMatchIndex)
            let highlightColor = isCurrentMatch ? 
                NSColor.systemYellow : // Current match
                NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.0, alpha: 0.3) // Other matches
            if NSMaxRange(range) <= textStorage.length {
                textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
            }
        }
    }
    
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func scrollToMatch(at index: Int) {
        guard let textView = textView, index >= 0, index < searchMatches.count else { return }
        let range = searchMatches[index]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
    
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
        if let textView = textView, let textStorage = textView.textStorage {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
    }
    
    // --- Commandes d'édition de texte ---
    
    // Insère du texte à la position du curseur
    func insertText(_ text: String) {
        guard let textView = textView else { return }
        
        let range = textView.selectedRange()
        if range.location != NSNotFound {
            textView.insertText(text, replacementRange: range)
        } else {
            // Fallback: ajout à la fin si pas de sélection valide
            let endRange = NSRange(location: textView.string.utf16.count, length: 0)
            textView.insertText(text, replacementRange: endRange)
        }
    }
    
    // Entoure la sélection actuelle avec un préfixe et un suffixe
    func wrapSelection(prefix: String, suffix: String) {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        if range.length == 0 {
            // Si rien n'est sélectionné : on insère les marqueurs et on place le curseur au milieu
            textView.insertText(prefix + suffix, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: 0))
        } else {
            // Si du texte est sélectionné : on l'entoure
            if let string = textView.string as NSString? {
                let selectedText = string.substring(with: range)
                let newText = prefix + selectedText + suffix
                textView.insertText(newText, replacementRange: range)
            }
        }
    }
    
    // --- Raccourcis de formatage Typst ---
    
    func toggleBold() { wrapSelection(prefix: "*", suffix: "*") }
    
    func toggleItalic() { wrapSelection(prefix: "_", suffix: "_") }
    
    func toggleCode() { wrapSelection(prefix: "`", suffix: "`") }
    
    func insertHeading() { insertText("= ") }
    
    func insertMath() { wrapSelection(prefix: "$", suffix: "$") }
    
    // --- Navigation ---
    
    func refreshSearch() {
        guard !searchQuery.isEmpty else { return }
        performSearch(scrollToFirst: false)
    }

    @MainActor
    func goToLine(_ lineNumber: Int) {
        guard lineNumber > 0, let textView else { return }
        let text = textView.string as NSString
        var line = 1
        var offset = 0
        while line < lineNumber && offset < text.length {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
        let range = NSRange(location: min(offset, text.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
}
