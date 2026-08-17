import Foundation
import Combine

struct TypstError: Identifiable, Equatable {
    let id = UUID()
    let line: Int // 1-based
    let message: String
}

@MainActor
class TypstCompiler: ObservableObject {
    @Published var compilationStatus: String = "Ready"
    @Published var isCompiling: Bool = false
    @Published var errors: [TypstError] = []
    @Published var projectRoot: URL?
    
    // Check if typst makes sense or we need full path
    private func resolveTypstPath() -> String? {
        // Priority 1: Check if bundled with the app
        if let bundlePath = Bundle.main.resourcePath {
            let bundledTypst = "\(bundlePath)/bin/typst"
            if FileManager.default.fileExists(atPath: bundledTypst) {
                return bundledTypst
            }
        }
        
        // Priority 2: Common system paths
        let paths = [
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "/usr/bin/typst",
            NSString(string: "~/bin/typst").expandingTildeInPath,
            NSString(string: "~/.cargo/bin/typst").expandingTildeInPath,
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private var currentProcess: Process?
    private var processOutputPipe: Pipe?
    
    // We keep track of the current shadow file being watched
    private var currentShadowSourceURL: URL?
    
    func cleanUp() {
        if let process = currentProcess {
            process.terminate()
        }
        currentProcess = nil
        // Optional: Clean up shadow files
    }
    
    // Writes content to the shadow file. If watch is not running, starts it.
    func updateContent(source: String, fileURL: URL) async {
        let filename = fileURL.lastPathComponent
        let workingDirectory = fileURL.deletingLastPathComponent()
        
        let shadowSourceURL = workingDirectory.appendingPathComponent(".\(filename).preview.typ")
        let shadowPDFURL = workingDirectory.appendingPathComponent(".\(filename).preview.pdf")
        
        // Write content to shadow file
        do {
            try source.write(to: shadowSourceURL, atomically: true, encoding: .utf8)
        } catch {
            self.compilationStatus = "Error writing shadow file: \(error)"
            return
        }
        
        // If we are already watching THIS file, we are done (typst watch will pick it up)
        if let current = currentShadowSourceURL, current == shadowSourceURL, currentProcess?.isRunning == true {
             self.compilationStatus = "Compiling..." 
             return
        }
        
        // Otherwise, stop previous watch and start new one
        cleanUp()
        startWatching(sourceURL: shadowSourceURL, outputURL: shadowPDFURL)
    }
    
    private func startWatching(sourceURL: URL, outputURL: URL) {
        guard let typstPath = resolveTypstPath() else {
            self.compilationStatus = "Error: 'typst' executable not found."
            return
        }
        
        currentShadowSourceURL = sourceURL
        self.errors = [] // Clear errors on start
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        var arguments = ["watch"]
        if let root = projectRoot {
            arguments.append("--root")
            arguments.append(root.path)
            process.currentDirectoryURL = root
        }
        arguments.append(contentsOf: [sourceURL.path, outputURL.path])
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardError = pipe // typst often logs to stderr or stdout, check both? usually stderr for logs
        process.standardOutput = pipe
        
        self.processOutputPipe = pipe
        self.currentProcess = process
        
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isCompiling = false
                self?.compilationStatus = "Watch process ended."
            }
        }
        
        do {
            try process.run()
            self.isCompiling = true
            self.compilationStatus = "Watching..."
            
            // Start reading output in background
            monitorOutput(pipe: pipe, outputURL: outputURL)
        } catch {
            self.compilationStatus = "Failed to start watch: \(error)"
        }
    }
    
    private func monitorOutput(pipe: Pipe, outputURL: URL) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            
            if let output = String(data: data, encoding: .utf8) {
                print("[TYPST-OUTPUT]: \(output)") // Enhanced logging
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    
                    // Simple heuristic: if we see "compiled" or "success", update view
                    if output.contains("compiled successfully") || output.contains("compiled") {
                         print("[TYPST] Detected success message, posting notification")
                         self.compilationStatus = "Compiled Successfully"
                         self.errors = [] // Clear errors
                         // Notify View
                         NotificationCenter.default.post(name: .pdfDidUpdate, object: outputURL)
                    } else if output.contains("error:") {
                        print("[TYPST] Detected error message")
                        self.compilationStatus = "Compilation Error"
                        self.parseErrors(from: output)
                    }
                }
            }
        }
    }
    
    private func parseErrors(from output: String) {
        // Example: "error: expected semi-colon\n  at file.typ:10:5"
        // Simple regex to find line numbers
        // We look for ":(\d+):\d+" pattern which usually indicates line:col
        
        let lines = output.components(separatedBy: .newlines)
        var newErrors: [TypstError] = []
        
        // Very basic parser - captures the last error seen
        var currentMessage = "Error"
        
        for line in lines {
            if line.contains("error:") {
                currentMessage = line.replacingOccurrences(of: "error: ", with: "")
            }
            // Check for line info "at file:line:col" or "file:line:col"
            // Regex for ":\d+:\d+"
            if let range = line.range(of: ":\\d+:\\d+", options: .regularExpression) {
                let match = String(line[range])
                // match is like ":10:5"
                let parts = match.split(separator: ":")
                if parts.count >= 1, let lineNum = Int(parts[0]) {
                    newErrors.append(TypstError(line: lineNum, message: currentMessage))
                }
            }
        }
        
        if !newErrors.isEmpty {
            self.errors = newErrors // Replace errors
            NotificationCenter.default.post(name: .typstErrorsUpdated, object: nil)
        }
    }
}

extension Notification.Name {
    static let pdfDidUpdate = Notification.Name("pdfDidUpdate")
    static let typstErrorsUpdated = Notification.Name("typstErrorsUpdated")
}
