import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var fileSystem = FileSystemModel()
    
    @State private var selectedFile: URL?
    @State private var sourceCode: String = ""
    @State private var currentPDFURL: URL? // Preview PDF for live viewing
    @State private var exportedPDFURL: URL? // Exported PDF for sharing/printing
    
    // Debounce timer
    @State private var workItem: DispatchWorkItem?
    
    @StateObject private var editorController = EditorController()
    
    @State private var reloadToken: UUID = UUID()
    @State private var lastSaved: Date?
    @State private var showSavePopup: Bool = false
    @EnvironmentObject var themeManager: ThemeManager
    
    // MARK: - Computed Properties for UI Components
    
    private var lineNumbersBox: some View {
        VStack(spacing: 0) {
            // Spacer matching Toolbar height (transparent, no background)
            Rectangle()
                .fill(Color.clear)
                .frame(height: 44) // Precise: 12+44+8+10=74 matches editor 12+44+8+10=74
            
            // The visual box for line numbers starting at Line 1
            ZStack {
                Color.black.opacity(0.3)
                
                LineNumbersView(controller: editorController)
                    .environmentObject(themeManager)
                    .padding(8)
            }
            .cornerRadius(12)
            .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        }
        .frame(minWidth: 50, maxWidth: 50, maxHeight: .infinity)
        .padding(.leading, 12)
        .padding(.vertical, 12) // Match editorBox vertical padding
    }
    
    private var editorBox: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                // Formatting Toolbar above editor
                HStack {
                    ToolbarView(controller: editorController)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.1))
               
                // Editor
                EditorView(text: $sourceCode, controller: editorController, onCommit: {
                    scheduleCompilation()
                })
                .environmentObject(themeManager)
                .padding(8)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
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
                    SidebarView(model: fileSystem, selectedFile: $selectedFile)
                        .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                    
                    // RIGHT: Main Content (Editor + PDF)
                    if let selectedFile = selectedFile {
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea() 
                            themeManager.mainBackground.ignoresSafeArea() // .clear
                            
                            ResizableSplitView(initialWidth: 500) {
                                // Left Pane: Line Numbers + Editor
                                HStack(spacing: 8) { // Added spacing
                                    lineNumbersBox
                                    editorBox
                                        .padding(.trailing, 0) // Remove padding as handle provides spacing
                                }
                            } right: {
                                // PDF Preview Area with Shadow Box
                                ZStack {
                                    themeManager.pdfBackground
                                    
                                    PreviewView(url: currentPDFURL, reloadToken: reloadToken)
                                        .padding(20)
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
                            Text("Select a file")
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
                            .help("Undo (Cmd+Z)")
                            .buttonStyle(.plain)
                            
                            Button(action: editorController.redo) {
                                Image(systemName: "arrow.uturn.forward")
                                    .foregroundColor(themeManager.textColor)
                            }
                            .help("Redo (Cmd+Shift+Z)")
                            .buttonStyle(.plain)
                        }
                    }
                    
                    ToolbarItem(placement: .principal) {
                        Text(selectedFile?.lastPathComponent ?? "")
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
                                    TextField("Search", text: $editorController.searchQuery)
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
                                        Text("\(editorController.currentMatchIndex + 1) of \(editorController.matchCount)")
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
                                        .help("Previous")
                                        
                                        // Next match button
                                        Button(action: { editorController.nextMatch() }) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Next")
                                        
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
                                        .help("Done")
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
                                .help("Save (Cmd+S)")
                                .keyboardShortcut("s", modifiers: .command)
                                .buttonStyle(.plain)
                                
                                // Print Button
                                Button(action: printPDF) {
                                    Image(systemName: "printer")
                                        .foregroundColor(themeManager.textColor)
                                }
                                .help("Print")
                                .buttonStyle(.plain)
                                
                                // Share Button (Native Anchor)
                                ShareButton(fileURL: exportedPDFURL)
                                    .frame(width: 20, height: 20)
                                    .help("Share")
                            }
                            
                            // Save Status & Finder
                            if let lastSaved = lastSaved {
                                Text("Last saved: \(lastSaved.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        }
                    }
                }
                // Important: Hide explicit window toolbar background to use our transparency
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onChange(of: compiler.errors) { newErrors in
                    editorController.errors = newErrors
                    editorController.needsRedraw()
                    // Broadcast errors to sidebar
                    NotificationCenter.default.post(name: .typstErrorsUpdated, object: newErrors)
                }
            }
            
            // Save Popup
            if showSavePopup {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text("Saved!")
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
        .onChange(of: selectedFile) { newValue in
            loadFile(url: newValue)
        }
        .onChange(of: fileSystem.currentFolder) { newFolder in
            compiler.projectRoot = newFolder
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertSnippet)) { notification in
            if let snippetKey = notification.object as? String {
                switch snippetKey {
                case "table":
                    editorController.insertTableSnippet()
                case "image":
                    editorController.insertImageSnippet()
                case "chart":
                    editorController.insertChartSnippet()
                case "timeline":
                    editorController.insertTimelineSnippet()
                default:
                    break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidUpdate)) { notification in
            if let url = notification.object as? URL {
                self.currentPDFURL = url
                self.reloadToken = UUID()
                
                // Auto-export PDF to project directory when preview updates
                if let selectedFile = selectedFile {
                    exportPDF(from: selectedFile)
                }
            }
        }

        .preferredColorScheme(.dark)
    }
    
    func loadFile(url: URL?) {
        guard let url = url else { return }
        do {
            self.sourceCode = try String(contentsOf: url, encoding: .utf8)
            // Set exported PDF URL based on file path
            self.exportedPDFURL = url.deletingPathExtension().appendingPathExtension("pdf")
            // Add to recents
            RecentFilesManager.shared.add(url: url)
            // Trigger watch
            scheduleCompilation()
        } catch {
            print("Failed to read file: \(error)")
        }
    }
    
    func saveFile() {
        guard let url = selectedFile else { return }
        do {
            // Save .typ file
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            RecentFilesManager.shared.add(url: url)
            
            // Trigger compilation to generate PDF
            scheduleCompilation()
            
            // UI Feedback
            lastSaved = Date()
            withAnimation {
                showSavePopup = true
            }
            // Hide after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSavePopup = false
                }
            }
        } catch {
            print("Error saving: \(error)")
        }
    }
    
    func exportPDF(from sourceURL: URL) {
        let pdfDestination = sourceURL.deletingPathExtension().appendingPathExtension("pdf")
        let workingDirectory = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.lastPathComponent
        let shadowPDFURL = workingDirectory.appendingPathComponent(".\(filename).preview.pdf")
        
        // Export happens after a short delay to ensure compilation is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if FileManager.default.fileExists(atPath: shadowPDFURL.path) {
                do {
                    // Remove old PDF if exists
                    if FileManager.default.fileExists(atPath: pdfDestination.path) {
                        try FileManager.default.removeItem(at: pdfDestination)
                    }
                    // Copy preview PDF to final destination
                    try FileManager.default.copyItem(at: shadowPDFURL, to: pdfDestination)
                    print("[INFO] PDF exported to: \(pdfDestination.path)")
                    // Update exported PDF URL for sharing
                    self.exportedPDFURL = pdfDestination
                } catch {
                    print("[ERROR] Failed to export PDF: \(error)")
                }
            }
        }
    }
    
    func printPDF() {
        print("[DEBUG] printPDF called")
        print("[DEBUG] currentPDFURL: \(String(describing: currentPDFURL))")
        
        guard let url = currentPDFURL else {
            print("[ERROR] printPDF: currentPDFURL is nil")
            return
        }
        
        guard let document = PDFDocument(url: url) else {
            print("[ERROR] printPDF: Failed to load PDFDocument from URL: \(url)")
            return
        }
        
        print("[DEBUG] printPDF: PDF loaded successfully, page count: \(document.pageCount)")
        
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        
        // Scale to fit logic is complex in code, but standard print op handles typical cases
        let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        print("[DEBUG] printPDF: Running print operation")
        op?.run()
    }
    
    func sharePDF() {
        guard let url = currentPDFURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Need a view to attach to. For now, try standard view.
        // In SwiftUI, we need to bridge to AppKit view.
        // Simplest way: dispatch to main and find key window's content view.
        
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    func scheduleCompilation() {
        guard let url = selectedFile else { return }
        
        workItem?.cancel()
        let currentSource = sourceCode
        let fileURL = url
        
        let newWorkItem = DispatchWorkItem {
            Task {
                await compiler.updateContent(source: currentSource, fileURL: fileURL)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: newWorkItem)
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
