import Foundation
import Combine

struct TypstError: Identifiable, Equatable {
    let id = UUID()
    let line: Int
    let message: String
    var filePath: String? = nil
}

/// Watch output can arrive split anywhere, including inside UTF-8 characters and diagnostics.
struct WatchOutputParser {
    private var buffer = Data()
    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
                .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(line)
            buffer.removeSubrange(...end)
        }
        // Bound retained partial output from an unexpected custom executable.
        if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
        return lines
    }

    static func diagnostic(_ line: String) -> TypstError? {
        guard let range = line.range(of: ":\\d+:\\d+: (error|warning):", options: .regularExpression) else {
            if line.hasPrefix("error:") {
                return TypstError(line: 0, message: String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        let location = String(line[range]).split(separator: ":")
        guard location.count >= 3, location[2].trimmingCharacters(in: .whitespaces) == "error",
              let lineNumber = Int(location[0]) else { return nil }
        return TypstError(line: lineNumber,
                          message: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces),
                          filePath: String(line[..<range.lowerBound]))
    }
}

@MainActor
final class TypstCompiler: ObservableObject {
    @Published var compilationStatus = L10n.text("Ready", "就绪")
    @Published var isCompiling = false
    @Published var errors: [TypstError] = []
    @Published private(set) var previewURL: URL?
    private let settings: CompilerSettings
    init(settings: CompilerSettings? = nil) { self.settings = settings ?? .shared }
    var hasRunningProcess: Bool { currentProcess?.isRunning == true }
    private var currentProcess: Process?
    private var outputPipe: Pipe?
    private var shadowSource: URL?
    private var shadowPDF: URL?
    private var watchedFile: URL?
    private var watchedRoot: URL?
    private var watchedExecutable: String?
    private var watchedLowMemory = false
    private var watchedFontArguments: [String] = []
    private var retirement: Task<Void, Never>?
    private var session = UUID()
    private var parser = WatchOutputParser()
    private var lastSource: String?
    private var lastWrite = UUID()

    func cleanUp(waitForExit: Bool = false) {
        session = UUID()
        lastWrite = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        let oldProcess = currentProcess
        let artifacts = [shadowSource, shadowPDF].compactMap { $0 }
        currentProcess = nil
        outputPipe = nil
        shadowSource = nil
        shadowPDF = nil
        watchedFile = nil
        watchedRoot = nil
        watchedExecutable = nil
        lastSource = nil
        previewURL = nil
        errors = []
        isCompiling = false
        // Send the termination signal before returning, including during application quit.
        if let oldProcess, oldProcess.isRunning { oldProcess.terminate() }
        let finished = DispatchSemaphore(value: 0)
        let priorRetirement = retirement
        retirement = Task.detached(priority: .utility) {
            await priorRetirement?.value
            await ShadowWriter.shared.barrier()
            if let oldProcess { CLIProcess.stopAndWait(oldProcess) }
            for artifact in artifacts { try? FileManager.default.removeItem(at: artifact) }
            finished.signal()
        }
        // The application termination callback must finish artifact cleanup before the app exits.
        if waitForExit { _ = finished.wait(timeout: .now() + 3) }
    }

    func updateContent(source: String, fileURL: URL, projectFolder: URL? = nil) async {
        guard !Task.isCancelled else { return }
        var operationSession = session
        do {
            guard let executable = settings.resolvedPath() else { throw CompilerFailure.missingExecutable }
            let root = try settings.projectRoot(fileURL: fileURL, folder: projectFolder)
            let fontArguments = try settings.fontArguments()
            let mustRestart = watchedFile != fileURL || watchedRoot != root || watchedExecutable != executable || watchedLowMemory != settings.lowMemoryMode || watchedFontArguments != fontArguments || currentProcess?.isRunning != true || (settings.lowMemoryMode && source != lastSource)
            if mustRestart {
                cleanUp()
                let name = ".typstedit-preview-\(UUID().uuidString)"
                // A sibling shadow preserves imports relative to the editing file.
                shadowSource = fileURL.deletingLastPathComponent().appendingPathComponent(name + ".typ")
                shadowPDF = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
                watchedFile = fileURL
                watchedRoot = root
                watchedExecutable = executable
                watchedLowMemory = settings.lowMemoryMode
                watchedFontArguments = fontArguments
                parser = WatchOutputParser()
            }
            guard let shadowSource, let shadowPDF else { return }
            guard mustRestart || source != lastSource else { return }
            let writeID = UUID()
            lastWrite = writeID
            let currentSession = session
            operationSession = currentSession
            // Do not overlap old and new compiler/font caches during rapid restarts.
            await retirement?.value
            guard currentSession == session, lastWrite == writeID, !Task.isCancelled else { return }
            // A serial background queue keeps rapid writes ordered and off the UI thread.
            try await ShadowWriter.shared.write(source, to: shadowSource)
            guard currentSession == session else {
                // A stale write may have queued after retirement's writer barrier.
                await ShadowWriter.shared.remove(shadowSource)
                return
            }
            guard lastWrite == writeID, !Task.isCancelled else { return }
            lastSource = source
            isCompiling = true
            compilationStatus = L10n.text("Compiling…", "编译中…")
            if mustRestart || currentProcess?.isRunning != true {
                try startWatching(executable: executable, source: shadowSource, output: shadowPDF, root: root)
            }
        } catch {
            guard !Task.isCancelled, operationSession == session else { return }
            isCompiling = false
            compilationStatus = error.localizedDescription
            errors = [TypstError(line: 0, message: error.localizedDescription)]
        }
    }

    private func startWatching(executable: String, source: URL, output: URL, root: URL) throws {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = source.deletingLastPathComponent()
        // Typst defaults to the available CPU count. Keep one watch process for incremental caching.
        process.arguments = [watchedLowMemory ? "compile" : "watch", "--root", root.path, "--diagnostic-format", "short"] + watchedFontArguments + [source.path, output.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        outputPipe = pipe
        currentProcess = process
        let activeSession = session
        let oneShot = watchedLowMemory
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, let process, self.session == activeSession, self.currentProcess === process else { return }
                for line in self.parser.append(data) { self.consume(line, output: output) }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.session == activeSession, self.currentProcess === process else { return }
                self.isCompiling = false
                if oneShot {
                    if process.terminationStatus == 0 {
                        self.publishSuccess(output)
                    } else {
                        self.compilationStatus = L10n.text("Compilation error", "编译错误")
                        if self.errors.isEmpty { self.errors = [TypstError(line: 0, message: self.compilationStatus)] }
                    }
                } else {
                    self.compilationStatus = L10n.text("Typst watch stopped", "Typst 预览进程已停止") + " (\(process.terminationStatus))"
                }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }
        try process.run()
    }

    private func consume(_ line: String, output: URL) {
        if line.contains("compiling") {
            errors = []
            isCompiling = true
        }
        if line.contains("compiled successfully") {
            publishSuccess(output)
        } else if let diagnostic = WatchOutputParser.diagnostic(line) {
            let path = diagnostic.filePath.map { raw -> String in
                let reported = URL(fileURLWithPath: raw, relativeTo: watchedFile?.deletingLastPathComponent()).resolvingSymlinksInPath().standardizedFileURL
                if reported == shadowSource?.resolvingSymlinksInPath().standardizedFileURL {
                    return watchedFile?.path ?? reported.path
                }
                return reported.path
            }
            let error = TypstError(line: diagnostic.line, message: diagnostic.message, filePath: path)
            isCompiling = false
            compilationStatus = L10n.text("Compilation error", "编译错误")
            errors.append(error)
        } else if line.contains("compiled with errors") {
            isCompiling = false
            compilationStatus = L10n.text("Compilation error", "编译错误")
        }
    }

    private func publishSuccess(_ output: URL) {
        isCompiling = false
        compilationStatus = L10n.text("Compiled successfully", "编译成功")
        errors = []
        previewURL = output
        if let file = watchedFile {
            NotificationCenter.default.post(name: .pdfDidUpdate, object: self, userInfo: ["url": output, "file": file])
        }
    }

    /// Export a captured editor revision; never copy a possibly stale live-preview PDF.
    func export(source: String, fileURL: URL, projectFolder: URL?, destination: URL) async throws {
        guard let executable = settings.resolvedPath() else { throw CompilerFailure.missingExecutable }
        let root = try settings.projectRoot(fileURL: fileURL, folder: projectFolder)
        let fontArguments = try settings.fontArguments()
        try await Task.detached(priority: .userInitiated) {
            let name = ".typstedit-export-\(UUID().uuidString)"
            let shadow = fileURL.deletingLastPathComponent().appendingPathComponent(name + ".typ")
            let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
            defer {
                try? FileManager.default.removeItem(at: shadow)
                try? FileManager.default.removeItem(at: pdf)
            }
            try source.write(to: shadow, atomically: true, encoding: .utf8)
            let result = CLIProcess.run(executable: executable,
                arguments: ["compile", "--root", root.path, "--diagnostic-format", "short"] + fontArguments + [shadow.path, pdf.path],
                directory: fileURL.deletingLastPathComponent())
            guard result.status == 0 else { throw CompilerFailure.compilation(result.output) }
            // Atomic replacement preserves the prior export if compilation or writing fails.
            try Data(contentsOf: pdf).write(to: destination, options: .atomic)
        }.value
    }
}

private actor ShadowWriter {
    static let shared = ShadowWriter()
    func barrier() {}
    func write(_ source: String, to url: URL) throws {
        try Task.checkCancellation()
        try source.write(to: url, atomically: true, encoding: .utf8)
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

extension Notification.Name {
    static let pdfDidUpdate = Notification.Name("pdfDidUpdate")
}
