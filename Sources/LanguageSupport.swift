import Foundation
import Combine

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "languageEnabled"); if !enabled { Task { await TypstLanguageService.shared.stop() } } } }
    @Published var autoComplete: Bool { didSet { defaults.set(autoComplete, forKey: "languageAutoComplete") } }
    @Published var hover: Bool { didSet { defaults.set(hover, forKey: "languageHover") } }
    @Published var formatOnSave: Bool { didSet { defaults.set(formatOnSave, forKey: "languageFormatOnSave") } }
    @Published var customPath: String { didSet { defaults.set(customPath, forKey: "languageCustomPath") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "languageEnabled") as? Bool ?? true
        autoComplete = defaults.object(forKey: "languageAutoComplete") as? Bool ?? true
        hover = defaults.object(forKey: "languageHover") as? Bool ?? true
        formatOnSave = defaults.bool(forKey: "languageFormatOnSave")
        customPath = defaults.string(forKey: "languageCustomPath") ?? ""
    }
    var executable: String? {
        let custom = NSString(string: customPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        if !custom.isEmpty { return custom.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.cargo/bin", NSHomeDirectory() + "/.local/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("tinymist").path }.first(where: FileManager.default.isExecutableFile(atPath:))
    }
    func context(for tab: DocumentTab) throws -> LanguageDocument {
        guard enabled else { throw LanguageFailure.disabled }
        guard let executable else { throw LanguageFailure.missing }
        let root = try CompilerSettings.shared.projectRoot(fileURL: tab.id, folder: tab.projectFolder)
        let fonts = try CompilerSettings.shared.fontArguments()
        return LanguageDocument(file: tab.id, root: root, source: tab.source, executable: executable, fontArguments: fonts)
    }
}

enum LanguageFailure: LocalizedError {
    case disabled, missing, stopped, timeout, invalidMessage, server(String), stale, invalidEdit
    var errorDescription: String? {
        switch self {
        case .disabled: return L10n.text("Language assistance is disabled in Settings.", "语言辅助已在设置中关闭。")
        case .missing: return L10n.text("Tinymist not found. Install it or choose its executable in Settings → Language Assistance.", "未找到 Tinymist。请安装它，或在设置 → 语言辅助选择可执行文件。")
        case .stopped: return L10n.text("Language service stopped. Try again.", "语言服务已停止，请重试。")
        case .timeout: return L10n.text("Language request timed out. Try again.", "语言请求超时，请重试。")
        case .invalidMessage: return L10n.text("Invalid language-server response.", "语言服务响应无效。")
        case .server(let message): return String(message.prefix(1000))
        case .stale: return L10n.text("The document changed; the old result was discarded.", "文档已修改，旧结果已丢弃。")
        case .invalidEdit: return L10n.text("The server returned an invalid text edit; your draft is unchanged.", "语言服务返回了无效编辑，草稿未修改。")
        }
    }
}

struct LanguageDocument: Sendable {
    let file: URL
    let root: URL
    let source: String
    let executable: String
    let fontArguments: [String]
    var uri: String { file.absoluteString }
    var key: String { executable + "\0" + root.path + "\0" + fontArguments.joined(separator: "\0") }
}

/// LSP positions count UTF-16 code units and use CR/LF logical lines, not Swift Characters.
struct LSPText {
    let text: NSString
    let starts: [Int]
    let ends: [Int]
    init(_ source: String) {
        text = source as NSString
        var starts = [0], ends: [Int] = [], offset = 0
        while offset < text.length {
            let character = text.character(at: offset)
            if character == 10 || character == 13 {
                ends.append(offset)
                if character == 13, offset + 1 < text.length, text.character(at: offset + 1) == 10 { offset += 1 }
                starts.append(offset + 1)
            }
            offset += 1
        }
        ends.append(text.length)
        self.starts = starts; self.ends = ends
    }
    func position(_ offset: Int) -> [String: Int] {
        let offset = min(max(offset, 0), text.length)
        var low = 0, high = starts.count
        while low < high { let middle = (low + high) / 2; if starts[middle] <= offset { low = middle + 1 } else { high = middle } }
        let line = max(0, low - 1)
        return ["line": line, "character": min(offset, ends[line]) - starts[line]]
    }
    func offset(_ position: [String: Any]) -> Int? {
        guard let line = position["line"] as? Int, let character = position["character"] as? Int,
              line >= 0, line < starts.count, character >= 0, character <= ends[line] - starts[line] else { return nil }
        let value = starts[line] + character
        // Never split a surrogate pair supplied by a broken server.
        if value > 0, value < text.length, (0xDC00...0xDFFF).contains(text.character(at: value)), (0xD800...0xDBFF).contains(text.character(at: value - 1)) { return nil }
        return value
    }
    func range(_ value: [String: Any]) -> NSRange? {
        guard let start = value["start"] as? [String: Any], let end = value["end"] as? [String: Any],
              let lower = offset(start), let upper = offset(end), upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}

struct LanguageEdit: Sendable, Equatable {
    let range: NSRange
    let text: String
    static func decode(_ values: [[String: Any]], source: String) throws -> [LanguageEdit] {
        let positions = LSPText(source)
        let edits = try values.map { value -> LanguageEdit in
            guard let range = value["range"] as? [String: Any], let mapped = positions.range(range), let text = value["newText"] as? String else { throw LanguageFailure.invalidEdit }
            return LanguageEdit(range: mapped, text: text)
        }.sorted { $0.range.location < $1.range.location }
        for index in 1..<max(1, edits.count) {
            guard NSMaxRange(edits[index - 1].range) <= edits[index].range.location,
                  edits[index - 1].range.location != edits[index].range.location else { throw LanguageFailure.invalidEdit }
        }
        return edits
    }
    static func applying(_ edits: [LanguageEdit], to source: String) -> String {
        let result = NSMutableString(string: source)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        return result as String
    }
}

struct LanguageCompletion: Sendable {
    let label: String
    let detail: String
    let edit: LanguageEdit
    let additional: [LanguageEdit]
    let documentation: String
    let selection: NSRange?
    static func decode(_ response: Any, source: String, fallback: NSRange) -> [LanguageCompletion] {
        let list = response as? [[String: Any]] ?? (response as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let defaults = (response as? [String: Any])?["itemDefaults"] as? [String: Any] ?? [:]
        return list.prefix(80).compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let snippet = (item["insertTextFormat"] as? Int ?? defaults["insertTextFormat"] as? Int) == 2
            var range = fallback, insertion = item["insertText"] as? String ?? item["textEditText"] as? String ?? label
            if let edit = item["textEdit"] as? [String: Any] {
                guard let value = edit["range"] as? [String: Any] ?? edit["replace"] as? [String: Any], let mapped = LSPText(source).range(value), let text = edit["newText"] as? String else { return nil }
                range = mapped; insertion = text
            } else if let value = defaults["editRange"] as? [String: Any] {
                guard let mapped = LSPText(source).range(value["replace"] as? [String: Any] ?? value) else { return nil }
                range = mapped
            }
            let expanded = snippet ? LanguageSnippet.expand(insertion) : (insertion, nil)
            if let value = item["additionalTextEdits"], !(value is [[String: Any]]) { return nil }
            guard let additional = try? LanguageEdit.decode(item["additionalTextEdits"] as? [[String: Any]] ?? [], source: source) else { return nil }
            // Reject overlapping edits instead of guessing at server intent.
            let primary = LanguageEdit(range: range, text: expanded.0)
            let all = ([primary] + additional).sorted { $0.range.location < $1.range.location }
            for index in 1..<all.count where NSMaxRange(all[index - 1].range) > all[index].range.location || all[index - 1].range.location == all[index].range.location { return nil }
            return LanguageCompletion(label: String(label.prefix(200)), detail: String((item["detail"] as? String ?? "").prefix(500)),
                edit: primary, additional: additional, documentation: documentation(item["documentation"]), selection: expanded.1)
        }
    }
    static func documentation(_ value: Any?) -> String {
        var result = "", remaining = 10000
        func append(_ text: String) {
            guard remaining > 0 else { return }
            let part = String(text.prefix(remaining)); result += part; remaining -= part.count
        }
        func collect(_ value: Any?, depth: Int) {
            guard remaining > 0, depth < 8 else { return }
            if let string = value as? String { append(string) }
            else if let markup = value as? [String: Any] { append(markup["value"] as? String ?? "") }
            else if let values = value as? [Any] {
                for value in values {
                    guard remaining > 0 else { break }
                    if !result.isEmpty { append("\n\n") }
                    collect(value, depth: depth + 1)
                }
            }
        }
        collect(value, depth: 0)
        return result
    }
}

/// Expand common LSP tabstops into plain native text; never execute completion commands.
enum LanguageSnippet {
    static func expand(_ snippet: String) -> (String, NSRange?) {
        let chars = Array(snippet)
        var result = "", i = 0, stops: [(Int, NSRange)] = [], values: [Int: String] = [:]
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { result.append(chars[i + 1]); i += 2; continue }
            guard chars[i] == "$", i + 1 < chars.count else { result.append(chars[i]); i += 1; continue }
            let start = i; i += 1
            if chars[i].isNumber {
                var number = ""
                while i < chars.count, chars[i].isNumber { number.append(chars[i]); i += 1 }
                let identifier = Int(number) ?? 0, value = values[identifier] ?? "", offset = result.utf16.count
                result += value
                stops.append((identifier, NSRange(location: offset, length: value.utf16.count))); continue
            }
            if chars[i] == "{" {
                i += 1; var number = ""
                while i < chars.count, chars[i].isNumber { number.append(chars[i]); i += 1 }
                if !number.isEmpty, i < chars.count {
                    var body = "", depth = 0
                    if chars[i] == ":" { i += 1
                        while i < chars.count {
                            if chars[i] == "\\", i + 1 < chars.count { body.append(chars[i + 1]); i += 2; continue }
                            if chars[i] == "}", depth == 0 { break }
                            if chars[i] == "{" { depth += 1 }; if chars[i] == "}" { depth -= 1 }
                            body.append(chars[i]); i += 1
                        }
                    } else if chars[i] == "|" {
                        i += 1; var choice = ""
                        while i < chars.count, chars[i] != "|" { choice.append(chars[i]); i += 1 }
                        body = choice.components(separatedBy: ",").first ?? ""
                        if i < chars.count { i += 1 }
                    }
                    if i < chars.count, chars[i] == "}" {
                        i += 1
                        let expanded = expand(body).0, offset = result.utf16.count
                        result += expanded; values[Int(number) ?? 0] = expanded; stops.append((Int(number) ?? 0, NSRange(location: offset, length: expanded.utf16.count))); continue
                    }
                }
            }
            i = start + 1; result.append("$")
        }
        return (result, stops.sorted { ($0.0 == 0 ? Int.max : $0.0) < ($1.0 == 0 ? Int.max : $1.0) }.first?.1)
    }
}
