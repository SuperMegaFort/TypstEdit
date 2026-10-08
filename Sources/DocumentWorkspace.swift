import AppKit
import Combine

@MainActor
final class DocumentTab: ObservableObject, Identifiable {
    let id: URL
    let url: URL
    let projectFolder: URL
    // Notify only after the canonical text changes: synchronous redraws must see the new text.
    var source: String { didSet { if source != oldValue { sourceRevision &+= 1; objectWillChange.send(); if !isApplyingFormat { cancelLanguageOperation(); scheduleAutoSave() } } } }
    private(set) var sourceRevision = 0
    private var isApplyingFormat = false
    private var disposed = false
    private var languageTail: Task<Void, Never>?
    private var languageOperations: [UUID: Task<Void, Error>] = [:]
    private var activeLanguageOperation: UUID?
    @Published private(set) var savedSource: String
    @Published private(set) var autoSaveError: String?
    private var autoSaveEnabled = false
    private var autoSaveSuspended = false
    private var autoSaveTask: Task<Void, Never>?
    let controller = EditorController()
    private var controllerObservation: AnyCancellable?
    var editor: EditorView.Session?
    var exportedPDFURL: URL?
    var lastSaved: Date?
    var pendingLine: Int?
    var isDirty: Bool { source != savedSource }

    init(url: URL, projectFolder: URL, source: String) {
        self.url = url.standardizedFileURL
        self.id = Self.identity(url)
        self.projectFolder = projectFolder.standardizedFileURL
        self.source = source
        self.savedSource = source
        controllerObservation = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static func identity(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    func save() throws {
        do {
            // Refuse to silently replace edits made by another application.
            guard try String(contentsOf: id, encoding: .utf8) == savedSource else { throw DocumentSaveError.externalChange }
            // Write through the canonical path so opening a symlink does not replace the link.
            try source.write(to: id, atomically: true, encoding: .utf8)
            savedSource = source
            lastSaved = Date()
            autoSaveError = nil
            autoSaveTask?.cancel()
        } catch {
            autoSaveError = error.localizedDescription
            throw error
        }
    }

    private func languageOperation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = languageTail, id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.disposed, !Task.isCancelled else { throw CancellationError() }
            self.activeLanguageOperation = id
            defer { if self.activeLanguageOperation == id { self.activeLanguageOperation = nil } }
            try await operation()
        }
        languageOperations[id] = task
        languageTail = Task { _ = try? await task.value }
        defer { languageOperations.removeValue(forKey: id) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func cancelLanguageOperation() {
        guard !isApplyingFormat, let id = activeLanguageOperation else { return }
        languageOperations[id]?.cancel()
    }
    func formatSource(requireActive: Bool = false) async throws {
        try await languageOperation { [self] in try await performFormat(requireActive: requireActive) }
        scheduleAutoSave()
    }
    private func performFormat(requireActive: Bool) async throws {
        guard !disposed else { throw CancellationError() }
        let context = try LanguageSettings.shared.context(for: self)
        let revision = sourceRevision, session = editor, selection = editor?.textView.selectedRange()
        guard editor?.textView.hasMarkedText() != true else { throw CancellationError() }
        let response = try await TypstLanguageService.shared.request("textDocument/formatting", document: context)
        guard !disposed, !Task.isCancelled, sourceRevision == revision, source == context.source,
              editor?.textView.hasMarkedText() != true else { throw CancellationError() }
        if requireActive {
            guard let session, session.parent?.document === self, session.textView.selectedRange() == selection else { throw CancellationError() }
        }
        guard let values = response as? [[String: Any]] else {
            if response is NSNull { return }; throw LanguageFailure.invalidMessage
        }
        let edits = try LanguageEdit.decode(values, source: context.source)
        let formatted = LanguageEdit.applying(edits, to: context.source)
        guard formatted != source else { return }
        isApplyingFormat = true
        defer { isApplyingFormat = false }
        let nativeNotifies = session?.parent?.document === self
        if let session {
            guard session.textView.string == context.source else { throw CancellationError() }
            session.applyAssistedSource(formatted)
            source = session.textView.string
        } else { source = formatted }
        if !nativeNotifies { NotificationCenter.default.post(name: .documentSourceDidChange, object: self) }
    }

    /// Formatting failures never prevent saving the current draft.
    func savePrepared() async throws {
        try await languageOperation { [self] in try await performSave() }
    }
    private func performSave() async throws {
        guard !disposed else { throw CancellationError() }
        let revision = sourceRevision
        if LanguageSettings.shared.enabled && LanguageSettings.shared.formatOnSave {
            do { try await performFormat(requireActive: false) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard sourceRevision == revision else { throw CancellationError() }
                controller.languageStatus = L10n.text("Formatting unavailable; saving the original draft. ", "格式化不可用，保存原稿。") + error.localizedDescription
            }
        }
        guard !disposed, !Task.isCancelled else { throw CancellationError() }
        try save()
    }

    func configureAutoSave(_ enabled: Bool) {
        autoSaveEnabled = enabled
        autoSaveTask?.cancel()
        if enabled { scheduleAutoSave() }
    }

    func suspendAutoSave(_ suspended: Bool) {
        autoSaveSuspended = suspended
        autoSaveTask?.cancel()
        if !suspended { scheduleAutoSave() }
    }

    func scheduleAutoSave(delay: Duration = .seconds(1)) {
        autoSaveTask?.cancel()
        guard autoSaveEnabled, !autoSaveSuspended, isDirty, autoSaveError == nil else { return }
        let revision = source
        autoSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.autoSaveEnabled, !self.autoSaveSuspended, !Task.isCancelled, self.source == revision,
                  self.editor?.textView.hasMarkedText() != true else { return }
            do {
                try await self.savePrepared()
                NotificationCenter.default.post(name: .documentDidSave, object: self)
            } catch is CancellationError { return } catch {
                self.autoSaveError = error.localizedDescription
            }
        }
    }

    func dispose() {
        disposed = true
        for operation in languageOperations.values { operation.cancel() }
        configureAutoSave(false)
        editor?.detach()
        editor = nil
        let file = id
        Task { await TypstLanguageService.shared.close(file: file) }
    }
}

enum DocumentSaveError: LocalizedError {
    case externalChange
    var errorDescription: String? {
        L10n.text("The file changed outside TypstEdit. Your draft is retained; reopen the file to review the disk version before saving.",
                  "文件已在 TypstEdit 外修改。草稿已保留，请先核对磁盘版本再保存。")
    }
}

@MainActor
final class DocumentWorkspace: ObservableObject {
    @Published private(set) var tabs: [DocumentTab] = []
    @Published private(set) var activeID: URL?
    private var observations: [URL: AnyCancellable] = [:]
    var active: DocumentTab? { tabs.first { $0.id == activeID } }
    var isDirty: Bool { tabs.contains { $0.isDirty } }

    func open(_ url: URL, projectFolder: URL) throws -> DocumentTab {
        let id = DocumentTab.identity(url)
        if let existing = tabs.first(where: { $0.id == id }) { return existing }
        let tab = DocumentTab(url: url, projectFolder: projectFolder,
                              source: try String(contentsOf: url, encoding: .utf8))
        observations[id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tabs.append(tab)
        return tab
    }

    func activate(_ tab: DocumentTab) { activeID = tab.id }

    /// Call only after the document's Save/Cancel/Discard check succeeds.
    func close(_ tab: DocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.dispose()
        observations.removeValue(forKey: tab.id)
        tabs.remove(at: index)
        if activeID == tab.id { activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs { tab.dispose() }
        observations.removeAll()
        tabs.removeAll()
        activeID = nil
    }
}

extension Notification.Name {
    static let documentSourceDidChange = Notification.Name("documentSourceDidChange")
    static let documentDidSave = Notification.Name("documentDidSave")
}
