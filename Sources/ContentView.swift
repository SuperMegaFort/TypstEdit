import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var fileSystem = FileSystemModel()
    @StateObject private var workspace = DocumentWorkspace()
    @StateObject private var git = GitModel()
    @State private var historyRequest: GitHistoryRequest?
    @State private var gitRevision = UUID()
    @AppStorage("editorShowPreview") private var showPreview = true
    private var gitRequestKey: String { (fileSystem.currentFolder?.path ?? "") + (workspace.activeID?.path ?? "") + gitRevision.uuidString }
    
    @State private var selectedFile: URL?
    @State private var currentPDFURL: URL? // Preview PDF for live viewing
    @State private var exportedPDFURL: URL?
    private var loadedFile: URL? { workspace.active?.url }
    private var sourceCode: String { workspace.active?.source ?? "" }
    private var savedSource: String { workspace.active?.savedSource ?? "" }
    @State private var operationError: String?
    @State private var isExporting = false
    @State private var pendingLine: Int?
    @ObservedObject private var settings = CompilerSettings.shared
    
    // Debounce timer
    @State private var workItem: DispatchWorkItem?
    @State private var compilationTask: Task<Void, Never>?
    @State private var compilationRequest = UUID()
    
    @StateObject private var emptyEditorController = EditorController()
    private var editorController: EditorController { workspace.active?.controller ?? emptyEditorController }
    
    @State private var reloadToken: UUID = UUID()
    @State private var lastSaved: Date?
    @State private var showSavePopup: Bool = false
    @EnvironmentObject var themeManager: ThemeManager
    
    // MARK: - Computed Properties for UI Components
    
    private var editorBox: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                documentTabs
                // Formatting Toolbar above editor
                HStack {
                    ToolbarView(controller: editorController)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.1))
               
                // Editor
                if let tab = workspace.active {
                    EditorView(text: .constant(tab.source), controller: tab.controller,
                               onCommit: {}, document: tab)
                        .environmentObject(themeManager)
                        .padding(8)
                    if !tab.controller.languageStatus.isEmpty {
                        HStack {
                            Text(tab.controller.languageStatus).font(.caption).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button { tab.controller.languageStatus = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.foregroundColor(.secondary).padding(8)
                    }
                    if let error = tab.autoSaveError {
                        HStack {
                            Text(L10n.text("Saving paused: ", "保存已暂停：") + error)
                                .font(.caption).foregroundColor(.orange).textSelection(.enabled)
                            Button(L10n.text("Save a Copy…", "保存副本…")) { saveSourceCopy() }
                        }.padding(8)
                    }
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
    }

    private var documentTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    HStack(spacing: 8) {
                        Button { activateTab(tab) } label: {
                            HStack(spacing: 5) {
                                Text(tab.url.lastPathComponent).lineLimit(1)
                                if tab.isDirty { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                            }
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.url.lastPathComponent + (tab.isDirty ? L10n.text(" (modified)", "（未保存）") : ""))
                        Button { closeTab(tab) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("Close ", "关闭 ") + tab.url.lastPathComponent)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .foregroundColor(workspace.activeID == tab.id ? themeManager.textColor : themeManager.secondaryTextColor)
                    .background(workspace.activeID == tab.id ? Color.white.opacity(0.08) : Color.clear)
                    .help(tab.url.path)
                }
            }
        }
        .frame(height: 34)
        .background(Color.black.opacity(0.15))
    }
    
    var body: some View {
        ZStack {
            // Main Background with Visual Effect
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                state: .active,
                emphasized: false
            )
            .ignoresSafeArea()
            
            themeManager.mainBackground.ignoresSafeArea() // Should be .clear
            
            if fileSystem.currentFolder == nil {
                WelcomeView(model: fileSystem, onOpen: { url in
                    self.selectedFile = url
                    let folder = url.deletingLastPathComponent()
                    fileSystem.currentFolder = folder
                    fileSystem.loadFiles()
                })
                .background(themeManager.mainBackground)
            } else {
                // Unified HSplitView for Transparency
                HSplitView {
                    // LEFT: Sidebar (starts minimized)
                    SidebarView(model: fileSystem, git: git, selectedFile: $selectedFile, compiler: compiler, editorController: editorController, onOpenFolder: openProjectFolder, onNavigateError: navigateToError)
                        .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                    
                    // RIGHT: Main Content (Editor + PDF)
                    if selectedFile != nil {
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea() 
                            themeManager.mainBackground.ignoresSafeArea() // .clear
                            
                            ResizableSplitView(initialWidth: 500, showsRight: showPreview) {
                                // Left Pane: Line Numbers + Editor
                                HStack(spacing: 8) { // Added spacing
                                    editorBox
                                        .padding(.trailing, 0) // Remove padding as handle provides spacing
                                }
                            } right: {
                                // PDF Preview Area with Shadow Box
                                ZStack {
                                    themeManager.pdfBackground
                                    
                                    if showPreview {
                                        PreviewView(url: currentPDFURL, reloadToken: reloadToken).padding(20)
                                    }
                                }
                                .cornerRadius(12)
                                .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
                                .padding(.vertical, 12)
                                .padding(.leading, 0) // Remove padding as handle provides spacing
                                .padding(.trailing, 12) // Keep trailing padding for window edge
                            }
                        }
                        .layoutPriority(1)
                    } else {
                        // Empty state when no file selected but folder open
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea()
                            Text(L10n.text("Select a file", "选择一个 Typst 文件"))
                                .foregroundColor(themeManager.textColor)
                         }
                         .frame(maxWidth: .infinity, maxHeight: .infinity)
                         .layoutPriority(1)
                    }
                }
                // Toolbar attached to the main split view
                .toolbar {
                    // Undo/Redo on the left
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 8) {
                            Button(action: editorController.undo) {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundColor(themeManager.textColor)
                            }
                            .help(L10n.text("Undo (Cmd+Z)", "撤销（Cmd+Z）"))
                            .buttonStyle(.plain)
                            
                            Button(action: editorController.redo) {
                                Image(systemName: "arrow.uturn.forward")
                                    .foregroundColor(themeManager.textColor)
                            }
                            .help(L10n.text("Redo (Cmd+Shift+Z)", "重做（Cmd+Shift+Z）"))
                            .buttonStyle(.plain)
                        }
                    }
                    
                    ToolbarItem(placement: .principal) {
                        Text((selectedFile?.lastPathComponent ?? "") + (sourceCode == savedSource ? "" : " •"))
                            .font(.headline)
                            .foregroundColor(themeManager.textColor)
                    }
                    
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            
                            // Search Bar with Popup
                            VStack(spacing: 0) {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12))
                                    TextField(L10n.text("Search", "搜索"), text: Binding(get: { editorController.searchQuery }, set: { editorController.searchQuery = $0 }))
                                        .textFieldStyle(.plain)
                                        .frame(width: 120)
                                        .foregroundColor(themeManager.textColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(6)
                                
                                // Search results popup (appears when there are matches)
                                if !editorController.searchQuery.isEmpty && editorController.matchCount > 0 {
                                    HStack(spacing: 8) {
                                        // Match counter
                                        Text("\(editorController.currentMatchIndex + 1) / \(editorController.matchCount)")
                                            .font(.caption)
                                            .foregroundColor(themeManager.secondaryTextColor)
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Previous match button
                                        Button(action: { editorController.previousMatch() }) {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Previous", "上一个"))
                                        
                                        // Next match button
                                        Button(action: { editorController.nextMatch() }) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Next", "下一个"))
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Done button
                                        Button(action: { 
                                            editorController.searchQuery = ""
                                            editorController.clearSearch()
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Done", "完成"))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(6)
                                    .offset(y: 2)
                                }
                            }
                            
                            // Divider
Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                            
                            // Actions: Save, Print, Share
                            HStack(spacing: 12) {
                                Button(action: saveFile) {
                                    Image(systemName: "square.and.arrow.down")
                                        .foregroundColor(themeManager.textColor)
                                }
                                .help(L10n.text("Save (Cmd+S)", "保存（Cmd+S）"))
                                .accessibilityLabel(L10n.text("Save", "保存"))
                                .keyboardShortcut("s", modifiers: .command)
                                .buttonStyle(.plain)
                                
                                Button(action: exportPDF) {
                                    Image(systemName: "doc.badge.arrow.up")
                                }
                                .help(L10n.text("Export PDF (Cmd+Shift+E)", "导出 PDF（Cmd+Shift+E）"))
                                .disabled(isExporting)
                                .accessibilityLabel(L10n.text("Export PDF", "导出 PDF"))
                                .buttonStyle(.plain)
                                // Print Button
                                Button(action: printPDF) {
                                    Image(systemName: "printer")
                                        .foregroundColor(themeManager.textColor)
                                }
                                .help(L10n.text("Print", "打印"))
                                .accessibilityLabel(L10n.text("Print", "打印"))
                                .disabled(currentPDFURL == nil || compiler.isCompiling || !compiler.errors.isEmpty)
                                .buttonStyle(.plain)
                                
                                // Share Button (Native Anchor)
                                ShareButton(fileURL: exportedPDFURL)
                                    .frame(width: 20, height: 20)
                                    .help(L10n.text("Share last exported PDF", "分享最近导出的 PDF"))
                            }
                            
                            Button {
                                commitActiveEditor()
                                if let tab = workspace.active, let root = git.snapshot.root {
                                    historyRequest = GitHistoryRequest(root: root, file: tab.id)
                                }
                            } label: { Image(systemName: "clock.arrow.circlepath") }
                            .buttonStyle(.plain)
                            .disabled(git.snapshot.root == nil || workspace.active == nil)
                            .help(L10n.text("File History", "文件历史"))
                            .accessibilityLabel(L10n.text("File History", "文件历史"))

                            Button { editorController.formatDocument() } label: { Image(systemName: "text.alignleft") }
                                .buttonStyle(.plain).disabled(editorController.isFormatting)
                                .help(L10n.text("Format Document (Shift+Option+F)", "格式化文档（Shift+Option+F）"))
                                .accessibilityLabel(L10n.text("Format Document", "格式化文档"))

                            Button { showPreview.toggle() } label: {
                                Image(systemName: "sidebar.right")
                                    .foregroundColor(showPreview ? themeManager.textColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("Toggle Preview", "显示或隐藏预览"))
                            .accessibilityLabel(showPreview ? L10n.text("Hide Preview", "隐藏预览") : L10n.text("Show Preview", "显示预览"))

                            Text(showPreview ? compiler.compilationStatus : L10n.text("Preview off", "预览已关闭"))
                                .font(.caption)
                                .lineLimit(1)
                                .help(compiler.compilationStatus)
                                .accessibilityLabel(compiler.compilationStatus)
                            // Save Status & Finder
                            if let lastSaved = lastSaved {
                                Text(L10n.text("Saved: ", "已保存：") + lastSaved.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        }
                    }
                }
                // Important: Hide explicit window toolbar background to use our transparency
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onChange(of: compiler.errors) { newErrors in
                    editorController.errors = newErrors.filter { error in
                        guard let path = error.filePath else { return true }
                        let file = URL(fileURLWithPath: path)
                        return file.lastPathComponent.hasPrefix(".typstedit-preview-") ||
                            DocumentTab.identity(file) == workspace.activeID
                    }
                    editorController.needsRedraw()
                }
            }
            
            // Save Popup
            if showSavePopup {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text(L10n.text("Saved!", "已保存！"))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
        }
        .sheet(item: $historyRequest) { GitHistoryView(request: $0) }
        .background(DocumentWindowGuard(edited: workspace.isDirty,
            canClose: confirmDiscard, onClose: { cancelCompilation(); compiler.cleanUp(); workspace.closeAll() },
            onTerminate: { workspace.closeAll(); cancelCompilation(); compiler.cleanUp(waitForExit: true) },
            onCancelClose: { for tab in workspace.tabs { tab.suspendAutoSave(false) } }))
        .focusedSceneValue(\.documentActions, DocumentActions(open: openFile, save: saveFile, export: exportPDF, refresh: refreshPreview, insert: insertSnippet, complete: { editorController.requestCompletion() }, format: { editorController.formatDocument() }, hasDocument: selectedFile != nil))
        .alert(L10n.text("Operation failed", "操作失败"), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button(L10n.text("OK", "确定")) { operationError = nil }
        } message: { Text(operationError ?? "") }
        .onChange(of: selectedFile) { newValue in
            guard newValue != loadedFile else { return }
            if let newValue { loadFile(url: newValue) }
        }
        .onChange(of: showPreview) { enabled in
            resetPreview()
            if enabled { scheduleCompilation() }
        }
        .onChange(of: settings.autoSaveEnabled) { enabled in
            for tab in workspace.tabs { tab.configureAutoSave(enabled) }
        }
        .task(id: gitRequestKey) {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            while !Task.isCancelled {
                await git.refresh(folder: fileSystem.currentFolder, tab: workspace.active)
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
        .onChange(of: settings.choice) { _ in refreshPreview() }
        .onChange(of: settings.customPath) { _ in refreshPreview() }
        .onChange(of: settings.lowMemoryMode) { _ in refreshPreview() }
        .onChange(of: settings.useSystemFonts) { _ in refreshPreview() }
        .onChange(of: settings.fontPaths) { _ in refreshPreview() }
        .onChange(of: settings.rootPath) { _ in refreshPreview() }
        .onDisappear { cancelCompilation(); compiler.cleanUp() }
        .onReceive(NotificationCenter.default.publisher(for: .documentDidSave)) { notification in
            guard let tab = notification.object as? DocumentTab, workspace.tabs.contains(where: { $0 === tab }) else { return }
            gitRevision = UUID()
            if workspace.active === tab { lastSaved = tab.lastSaved }
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentSourceDidChange)) { notification in
            guard let tab = notification.object as? DocumentTab, workspace.active === tab else { return }
            gitRevision = UUID()
            scheduleCompilation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidUpdate)) { notification in
            guard showPreview, let sender = notification.object as? TypstCompiler, sender === compiler,
                  let url = notification.userInfo?["url"] as? URL, compiler.previewURL == url,
                  let file = notification.userInfo?["file"] as? URL,
                  workspace.activeID == DocumentTab.identity(file) else { return }
            currentPDFURL = url
            reloadToken = UUID()
        }

        .preferredColorScheme(.dark)
    }
    
    func insertSnippet(_ key: String) {
        switch key {
        case "table": editorController.insertTableSnippet()
        case "image": editorController.insertImageSnippet()
        case "chart": editorController.insertChartSnippet()
        case "timeline": editorController.insertTimelineSnippet()
        default: break
        }
    }

    func confirmDiscard() -> Bool {
        commitActiveEditor()
        for tab in workspace.tabs { tab.suspendAutoSave(true) }
        for tab in workspace.tabs where !confirmDiscard(tab) {
            for tab in workspace.tabs { tab.suspendAutoSave(false) }
            return false
        }
        return true
    }

    func confirmDiscard(_ tab: DocumentTab) -> Bool {
        guard tab.isDirty else { return true }
        tab.suspendAutoSave(true)
        var allowed = false
        defer { if !allowed { tab.suspendAutoSave(false) } }
        let alert = NSAlert()
        alert.messageText = L10n.text("Save changes to ", "保存修改：") + tab.url.lastPathComponent + "?"
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))
        alert.addButton(withTitle: L10n.text("Discard", "放弃修改"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try tab.save(); allowed = true; return true }
            catch { operationError = error.localizedDescription; return false }
        case .alertThirdButtonReturn: allowed = true; return true
        default: return false
        }
    }

    func navigateToError(_ error: TypstError) {
        guard error.line > 0 else { return }
        if let path = error.filePath,
           !URL(fileURLWithPath: path).lastPathComponent.hasPrefix("typstedit-preview-"),
           let active = workspace.active {
            let target = URL(fileURLWithPath: path, relativeTo: active.url.deletingLastPathComponent()).standardizedFileURL
            if DocumentTab.identity(target) != active.id, target.pathExtension == "typ", FileManager.default.fileExists(atPath: target.path) {
                pendingLine = error.line
                loadFile(url: target, folderHint: active.projectFolder)
                return
            }
        }
        editorController.goToLine(error.line)
    }

    func openProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url, confirmDiscard() else { return }
        loadFile(url: nil)
        selectedFile = nil
        fileSystem.currentFolder = folder
        fileSystem.loadFiles()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "typ") ?? .plainText]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let originalFolder = fileSystem.currentFolder
            for url in panel.urls {
                let root = originalFolder.flatMap { folder in
                    let path = DocumentTab.identity(folder).path
                    return DocumentTab.identity(url).path.hasPrefix(path == "/" ? "/" : path + "/") ? folder : nil
                } ?? url.deletingLastPathComponent()
                loadFile(url: url, folderHint: root)
            }
        }
    }

    func loadFile(url: URL?, folderHint: URL? = nil) {
        guard let url else {
            resetPreview()
            workspace.closeAll()
            selectedFile = nil
            return
        }
        do {
            let folder = folderHint ?? fileSystem.currentFolder
            let canonicalFolder = folder.map(DocumentTab.identity)
            let canonicalFile = DocumentTab.identity(url)
            let root = canonicalFolder.flatMap { canonicalFile.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") ? folder : nil }
                ?? url.deletingLastPathComponent()
            let tab = try workspace.open(url, projectFolder: root)
            tab.configureAutoSave(settings.autoSaveEnabled)
            if let line = pendingLine {
                pendingLine = nil
                tab.pendingLine = line
            }
            activateTab(tab)
            RecentFilesManager.shared.add(url: url)
        } catch {
            pendingLine = nil
            selectedFile = loadedFile
            operationError = error.localizedDescription
        }
    }

    func commitActiveEditor(endEditing: Bool = true) {
        guard let editor = workspace.active?.editor else { return }
        if endEditing { editor.textView.window?.makeFirstResponder(nil) }
        if editor.textView.hasMarkedText() { editor.textView.unmarkText() }
        editor.commitCurrentText()
    }

    func resetPreview() {
        cancelCompilation()
        compiler.cleanUp()
        currentPDFURL = nil
    }

    func activateTab(_ tab: DocumentTab) {
        if workspace.activeID != tab.id {
            commitActiveEditor()
            resetPreview()
            workspace.activate(tab)
            tab.controller.errors = []
            exportedPDFURL = tab.exportedPDFURL
            lastSaved = tab.lastSaved
            selectedFile = tab.url
            if fileSystem.currentFolder != tab.projectFolder {
                fileSystem.currentFolder = tab.projectFolder
                fileSystem.loadFiles()
            }
            scheduleCompilation()
        }
        selectedFile = tab.url
        if tab.pendingLine != nil { tab.objectWillChange.send() }
    }

    func closeTab(_ tab: DocumentTab) {
        if workspace.activeID == tab.id { commitActiveEditor() }
        guard confirmDiscard(tab) else { return }
        let wasActive = workspace.activeID == tab.id
        if wasActive { resetPreview() }
        workspace.close(tab)
        if wasActive {
            selectedFile = workspace.active?.url
            exportedPDFURL = workspace.active?.exportedPDFURL
            lastSaved = workspace.active?.lastSaved
            if let active = workspace.active {
                fileSystem.currentFolder = active.projectFolder
                fileSystem.loadFiles()
                scheduleCompilation()
            }
        }
    }

    func saveFile() {
        commitActiveEditor(endEditing: false)
        guard let tab = workspace.active else { return }
        Task { @MainActor in
            do {
                try await tab.savePrepared()
                NotificationCenter.default.post(name: .documentDidSave, object: tab)
                RecentFilesManager.shared.add(url: tab.url)
                guard workspace.active === tab else { return }
                gitRevision = UUID(); scheduleCompilation(); lastSaved = tab.lastSaved
                withAnimation { showSavePopup = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { showSavePopup = false } }
            } catch is CancellationError { /* A changed or closed draft must never be saved by an old request. */ }
            catch { operationError = error.localizedDescription }
        }
    }

    func saveSourceCopy() {
        commitActiveEditor(endEditing: false)
        guard let tab = workspace.active else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.url.deletingPathExtension().lastPathComponent + "-copy.typ"
        panel.directoryURL = tab.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try tab.source.write(to: destination, atomically: true, encoding: .utf8) }
        catch { operationError = error.localizedDescription }
    }
    
    func exportPDF() {
        commitActiveEditor(endEditing: false)
        guard let tab = workspace.active, !isExporting else { return }
        let file = tab.url
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = file.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = tab.source
        let folder = tab.projectFolder
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await compiler.export(source: source, fileURL: file, projectFolder: folder, destination: destination)
                tab.exportedPDFURL = destination
                if workspace.activeID == tab.id { exportedPDFURL = destination }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { operationError = error.localizedDescription }
        }
    }

    func printPDF() {
        
        guard let url = currentPDFURL else {
            return
        }
        
        guard let document = PDFDocument(url: url) else {
            return
        }
        
        
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        
        // Scale to fit logic is complex in code, but standard print op handles typical cases
        let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        op?.run()
    }
    
    func refreshPreview() {
        cancelCompilation()
        compiler.cleanUp()
        scheduleCompilation()
    }

    func scheduleCompilation() {
        cancelCompilation()
        guard showPreview, let tab = workspace.active else { return }
        let request = compilationRequest
        let currentSource = tab.source
        let fileURL = tab.url
        let folder = tab.projectFolder
        
        let newWorkItem = DispatchWorkItem {
            guard compilationRequest == request else { return }
            compilationTask = Task { @MainActor in
                guard compilationRequest == request, !Task.isCancelled else { return }
                await compiler.updateContent(source: currentSource, fileURL: fileURL, projectFolder: folder)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: newWorkItem)
    }

    func cancelCompilation() {
        compilationRequest = UUID()
        workItem?.cancel()
        compilationTask?.cancel()
    }
}
import PDFKit



extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
