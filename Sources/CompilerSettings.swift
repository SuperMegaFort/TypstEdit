import Foundation
import Combine
import Darwin

enum CompilerChoice: String, CaseIterable, Identifiable {
    case automatic, bundled, custom
    var id: String { rawValue }
}

/// No shell is launched: executable paths (including spaces) are passed directly to Process.
struct TypstExecutableResolver {
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> [String] {
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = search + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                                    "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin"]
        var seen = Set<String>()
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("typst").path }
            .filter { seen.insert($0).inserted }
    }

    static func resolve(choice: CompilerChoice, customPath: String, bundledPath: String?,
                        systemPaths: [String] = candidates(),
                        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        switch choice {
        case .custom:
            let path = NSString(string: customPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
            return path.hasPrefix("/") && isExecutable(path) ? path : nil
        case .bundled:
            return bundledPath.flatMap { isExecutable($0) ? $0 : nil }
        case .automatic:
            return systemPaths.first(where: isExecutable) ?? bundledPath.flatMap { isExecutable($0) ? $0 : nil }
        }
    }
}

@MainActor
final class CompilerSettings: ObservableObject {
    static let shared = CompilerSettings()
    @Published var autoSaveEnabled: Bool {
        didSet { defaults.set(autoSaveEnabled, forKey: "editorAutoSave") }
    }
    @Published var choice: CompilerChoice {
        didSet { defaults.set(choice.rawValue, forKey: "compilerChoice") }
    }
    @Published var customPath: String {
        didSet { defaults.set(customPath, forKey: "compilerCustomPath") }
    }
    @Published var rootPath: String {
        didSet { defaults.set(rootPath, forKey: "compilerRootPath") }
    }
    @Published var lowMemoryMode: Bool {
        didSet { defaults.set(lowMemoryMode, forKey: "compilerLowMemoryMode") }
    }
    @Published var useSystemFonts: Bool {
        didSet { defaults.set(useSystemFonts, forKey: "compilerUseSystemFonts") }
    }
    @Published var fontPaths: String {
        didSet { defaults.set(fontPaths, forKey: "compilerFontPaths") }
    }
    @Published private(set) var executablePath: String?
    @Published private(set) var version = ""
    @Published private(set) var detectionError: String?
    private let defaults: UserDefaults
    private var detectionID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSaveEnabled = defaults.bool(forKey: "editorAutoSave")
        choice = CompilerChoice(rawValue: defaults.string(forKey: "compilerChoice") ?? "") ?? .automatic
        customPath = defaults.string(forKey: "compilerCustomPath") ?? ""
        rootPath = defaults.string(forKey: "compilerRootPath") ?? ""
        lowMemoryMode = defaults.bool(forKey: "compilerLowMemoryMode")
        useSystemFonts = defaults.object(forKey: "compilerUseSystemFonts") as? Bool ?? true
        fontPaths = defaults.string(forKey: "compilerFontPaths") ?? ""
    }

    var bundledPath: String? {
        if let resources = Bundle.main.resourceURL {
            let path = resources.appendingPathComponent("bin/typst").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Development builds only; bundled .app builds use their Resources above.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let path = repository.appendingPathComponent("typst-aarch64-apple-darwin/typst").path
        #else
        let path = repository.appendingPathComponent("typst-x86_64-apple-darwin/typst").path
        #endif
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func resolvedPath() -> String? {
        TypstExecutableResolver.resolve(choice: choice, customPath: customPath, bundledPath: bundledPath)
    }

    /// These flags are supported by bundled Typst 0.12 and current system versions.
    func fontArguments() throws -> [String] {
        var arguments = useSystemFonts ? [] : ["--ignore-system-fonts"]
        var seen = Set<String>()
        for raw in fontPaths.components(separatedBy: .newlines) {
            let path = NSString(string: raw.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
            guard !path.isEmpty else { continue }
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                throw CompilerFailure.invalidFontDirectory(path)
            }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(canonical).inserted { arguments += ["--font-path", canonical] }
        }
        return arguments
    }

    func refresh() async {
        let id = UUID()
        detectionID = id
        executablePath = resolvedPath()
        version = ""
        detectionError = nil
        guard let path = executablePath else {
            detectionError = L10n.text("Typst executable not found. Choose a valid executable.", "未找到 Typst，请选择有效的可执行文件。")
            return
        }
        let result = await Task.detached(priority: .utility) {
            CLIProcess.run(executable: path, arguments: ["--version"], directory: nil, timeout: 5)
        }.value
        guard detectionID == id else { return }
        if result.status == 0 && result.output.hasPrefix("typst ") {
            version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            detectionError = L10n.text("This executable did not report a Typst version.", "该文件未返回有效的 Typst 版本。")
        }
    }

    func projectRoot(fileURL: URL, folder: URL?) throws -> URL {
        let root: URL
        if rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = folder ?? fileURL.deletingLastPathComponent()
        } else {
            let path = NSString(string: rootPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
            guard path.hasPrefix("/") else { throw CompilerFailure.invalidRoot }
            root = URL(fileURLWithPath: path)
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory), isDirectory.boolValue,
              canonicalFile.path.hasPrefix(canonicalRoot.path == "/" ? "/" : canonicalRoot.path + "/") else {
            throw CompilerFailure.invalidRoot
        }
        return canonicalRoot
    }
}

enum CompilerFailure: LocalizedError {
    case invalidRoot, missingExecutable, invalidFontDirectory(String), compilation(String)
    var errorDescription: String? {
        switch self {
        case .invalidRoot: return L10n.text("Choose an existing project root containing the source file and its imports.", "请选择包含源文件及其引用文件的项目根目录。")
        case .missingExecutable: return L10n.text("Typst executable not found. Open Settings to select one.", "未找到 Typst，请在设置中选择。")
        case .invalidFontDirectory(let path): return L10n.text("Font directory does not exist: ", "字体目录不存在：") + path
        case .compilation(let message): return message
        }
    }
}

struct CLIResult: Sendable {
    let status: Int32
    let output: String
    var truncated = false
}

enum CLIProcess {
    /// Called off the main actor. Reap even an executable that ignores SIGTERM.
    static func stopAndWait(_ process: Process) {
        guard process.processIdentifier > 0 else { return }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    /// Drain the pipe while running to avoid deadlock on large diagnostics. A watchdog bounds custom binaries.
    static func run(executable: String, arguments: [String], directory: URL?, timeout: TimeInterval = 60, mergeStandardError: Bool = true, maxOutputBytes: Int? = nil) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice
        do {
            try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { stopAndWait(process) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
            var data = Data(), truncated = false
            if let limit = maxOutputBytes {
                // Keep draining even after the cap so Git cannot block on a full pipe.
                while true {
                    let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                    if chunk.isEmpty { break }
                    let remaining = max(0, limit - data.count)
                    data.append(chunk.prefix(remaining))
                    if chunk.count > remaining { truncated = true }
                }
            } else { data = pipe.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            watchdog.cancel()
            return CLIResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), truncated: truncated)
        } catch {
            return CLIResult(status: -1, output: error.localizedDescription)
        }
    }
}
