import Foundation
import Combine

struct GitFileChange: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let index: Character
    let worktree: Character
    let originalPath: String?
    var kind: GitChangeKind {
        if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") { return .conflicted }
        if index == "?" { return .untracked }
        if index == "D" || worktree == "D" { return .deleted }
        if index == "R" || worktree == "R" { return .renamed }
        if index == "A" || worktree == "A" { return .added }
        return .modified
    }
    var staged: Bool { index != " " && index != "?" }
    var unstaged: Bool { worktree != " " }
}

struct GitSnapshot: Sendable {
    var root: URL?
    var branch = ""
    var changes: [GitFileChange] = []
    var lines = GitLineMarkers()
    var hunks: [GitHunk] = []

    static func parseStatus(_ output: String) -> (String, [GitFileChange]) {
        let records = output.components(separatedBy: "\0")
        var branch = "", changes: [GitFileChange] = [], i = 0
        while i < records.count {
            let record = records[i]; i += 1
            if record.hasPrefix("## ") { branch = String(record.dropFirst(3)); continue }
            guard record.count >= 4 else { continue }
            let xy = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            // In -z format a rename has destination first, then a separate source record.
            var originalPath: String?
            if xy.contains("R") || xy.contains("C") {
                guard i < records.count, !records[i].isEmpty else { continue }
                originalPath = records[i]; i += 1
            }
            guard !path.components(separatedBy: "/").contains(where: { $0.hasPrefix(".typstedit-") }) else { continue }
            changes.append(GitFileChange(path: path, index: xy[0], worktree: xy[1], originalPath: originalPath))
        }
        return (branch, changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    static func parseHunks(_ diff: String, lineCount: Int) -> GitLineMarkers {
        var lines = GitLineMarkers()
        for line in diff.components(separatedBy: .newlines) where line.hasPrefix("@@ ") {
            guard let hunk = GitHunk.parse(line) else { continue }
            let removed = hunk.oldCount, start = hunk.newStart, added = hunk.newCount
            if added == 0 {
                let anchor = min(max(1, start), max(1, lineCount))
                lines.append(anchor...anchor, kind: .deleted)
            } else if start > 0, start <= lineCount {
                lines.append(start...min(start + added - 1, lineCount), kind: removed == 0 ? .added : .modified)
            }
        }
        return lines
    }
}

/// Serial, bounded Git subprocesses. No index mutations, hooks, shell, or diff drivers.
actor GitReader {
    static let shared = GitReader()
    private var baselineKey = ""
    private var baseline = ""
    private var comparedKey = ""
    private var comparedSource = ""
    private var comparedLines = GitLineMarkers()
    private var comparedHunks: [GitHunk] = []
    private var executable: String?
    private var checkedExecutable = false

    private func clearCache() {
        baselineKey = ""; baseline = ""
        comparedKey = ""; comparedSource = ""; comparedLines = GitLineMarkers(); comparedHunks = []
    }

    func snapshot(folder: URL, file: URL?, source: String?) -> GitSnapshot {
        guard !Task.isCancelled else { return GitSnapshot() }
        // Avoid launching Apple's git stub (and its installer) for ordinary folders.
        var ancestor = folder.resolvingSymlinksInPath().standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
            guard ancestor.path != "/" else { clearCache(); return GitSnapshot() }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != ancestor.path else { clearCache(); return GitSnapshot() }
            ancestor = parent
        }
        if !checkedExecutable {
            checkedExecutable = true
            executable = ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: FileManager.default.isExecutableFile(atPath:))
            if executable == nil {
                let tools = CLIProcess.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], directory: nil, timeout: 3, mergeStandardError: false)
                if tools.status == 0 { executable = "/usr/bin/git" }
            }
        }
        guard let executable, !Task.isCancelled else { return GitSnapshot() }
        func git(_ arguments: [String], at directory: URL) -> CLIResult {
            CLIProcess.run(executable: executable, arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
                           directory: directory, timeout: 3, mergeStandardError: false)
        }
        let repository = git(["rev-parse", "--show-toplevel"], at: folder)
        guard repository.status == 0, !Task.isCancelled else { clearCache(); return GitSnapshot() }
        let root = URL(fileURLWithPath: repository.output.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath()
        let status = git(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--renames"], at: root)
        guard status.status == 0, !Task.isCancelled else { return GitSnapshot() }
        let (branch, changes) = GitSnapshot.parseStatus(status.output)
        var result = GitSnapshot(root: root, branch: branch, changes: changes)
        guard let file, let source else { clearCache(); return result }
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard path.hasPrefix(prefix) else { return result }
        let relative = String(path.dropFirst(prefix.count))
        let ignored = git(["check-ignore", "--", relative], at: root)
        guard ignored.status != 0, !Task.isCancelled else { return result }
        let head = git(["rev-parse", "--verify", "HEAD"], at: root)
        let baselinePath = changes.first(where: { $0.path == relative })?.originalPath ?? relative
        let key = root.path + "\0" + head.output + "\0" + baselinePath
        if key != baselineKey {
            let blob = git(["show", "--no-ext-diff", "HEAD:" + baselinePath], at: root)
            guard !Task.isCancelled else { return result }
            if blob.status == 0 { baseline = blob.output }
            else {
                // New/staged-added files have no HEAD blob. Do not mark tracked files
                // as new merely because Git failed (permissions, missing objects, etc.).
                let tracked = git(["ls-files", "--error-unmatch", "--", relative], at: root)
                guard tracked.status != 0 || changes.contains(where: { $0.path == relative && $0.kind == .added }) else { return result }
                baseline = ""
            }
            baselineKey = key
        }
        guard !baseline.contains("\0"), !source.contains("\0") else { return result }
        if comparedKey == key, comparedSource == source {
            result.lines = comparedLines; result.hunks = comparedHunks
            return result
        }
        if baseline == source {
            comparedKey = key; comparedSource = source; comparedLines = GitLineMarkers(); comparedHunks = []
            return result
        }
        guard !Task.isCancelled, baseline != source else { return result }
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-git-\(UUID())")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let old = temporary.appendingPathComponent("before"), new = temporary.appendingPathComponent("after")
            // Match NSString's logical lines, including CRLF and Unicode separators.
            let oldText = Self.logicalLines(baseline), newText = Self.logicalLines(source)
            try oldText.write(to: old, atomically: true, encoding: .utf8)
            try newText.write(to: new, atomically: true, encoding: .utf8)
            let diff = git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=0", "--", old.path, new.path], at: temporary)
            if diff.status == 1 {
                result.hunks = diff.output.components(separatedBy: "\n").compactMap(GitHunk.parse)
                result.lines = GitSnapshot.parseHunks(diff.output, lineCount: newText.components(separatedBy: "\n").count)
                comparedKey = key; comparedSource = source; comparedLines = result.lines; comparedHunks = result.hunks
            }
        } catch { /* Decorations are optional; editing must remain available. */ }
        return result
    }

    static func logicalLines(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: "\r\u{85}\u{2028}\u{2029}")
        guard text.rangeOfCharacter(from: separators) != nil else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{85}", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

@MainActor
final class GitModel: ObservableObject {
    @Published private(set) var snapshot = GitSnapshot()
    private var generation = UUID()
    private var worker: Task<GitSnapshot, Never>?

    func refresh(folder: URL?, tab: DocumentTab?) async {
        worker?.cancel()
        let token = UUID(); generation = token
        guard let folder else { snapshot = GitSnapshot(); return }
        let file = tab?.id, source = tab?.source
        let task = Task.detached(priority: .utility) { await GitReader.shared.snapshot(folder: folder, file: file, source: source) }
        worker = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, generation == token, tab?.source == source else { return }
        snapshot = result
        tab?.controller.gitRoot = result.root
        tab?.controller.gitFile = file
        tab?.controller.gitChanges = result.lines
    }

    func change(for url: URL, directory: Bool = false) -> GitChangeKind? {
        guard let root = snapshot.root else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        if let exact = snapshot.changes.first(where: { $0.path == relative || $0.path == relative + "/" }) { return exact.kind }
        if directory { return snapshot.changes.contains(where: { $0.path.hasPrefix(relative + "/") }) ? .modified : nil }
        return snapshot.changes.contains(where: { $0.kind == .untracked && relative.hasPrefix($0.path) && $0.path.hasSuffix("/") }) ? .untracked : nil
    }
}


extension GitReader {
    private func reviewGit(_ arguments: [String], root: URL) -> CLIResult {
        guard let executable else { return CLIResult(status: -1, output: "") }
        return CLIProcess.run(executable: executable,
            arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
            directory: root, timeout: 3, mergeStandardError: false, maxOutputBytes: 4 * 1024 * 1024)
    }

    func currentHunk(root: URL, file: URL, source: String, line: Int) -> GitDiffPreview {
        let snapshot = snapshot(folder: root, file: file, source: source)
        guard !Task.isCancelled else { return GitDiffPreview() }
        let count = Self.logicalLines(source).components(separatedBy: "\n").count
        // Prefer a deletion anchor when it coincides with another changed range.
        let matching = snapshot.hunks.filter { $0.contains(line: line, lineCount: count) }
        guard let hunk = matching.first(where: { $0.newCount == 0 }) ?? matching.first else {
            return GitDiffPreview(error: L10n.text("This change is no longer present.", "此处修改已更新，请重新点击标记。"))
        }
        var preview = Self.hunkPreview(hunk, before: baseline, after: source)
        if let index = snapshot.hunks.firstIndex(of: hunk) {
            if index > 0 { preview.previousLine = max(1, snapshot.hunks[index - 1].newStart) }
            if index + 1 < snapshot.hunks.count { preview.nextLine = max(1, snapshot.hunks[index + 1].newStart) }
            preview.heading = L10n.text("Current changes", "当前修改") + " · \(index + 1)/\(snapshot.hunks.count) · HEAD → " + L10n.text("Draft", "草稿")
        }
        return preview
    }

    static func hunkPreview(_ hunk: GitHunk, before: String, after: String) -> GitDiffPreview {
        var preview = GitDiffPreview()
        let old = logicalLines(before).components(separatedBy: "\n")
        let new = logicalLines(after).components(separatedBy: "\n")
        func rows(_ lines: [String], start: Int, count: Int, kind: GitChangeKind) -> [GitDiffLine] {
            guard count > 0, start > 0, start <= lines.count else { return [] }
            let length = min(count, 200, lines.count - start + 1)
            if length < count { preview.truncated = true }
            return (0..<length).map { offset in
                let text = lines[start - 1 + offset]
                if text.count > 4000 { preview.truncated = true }
                return GitDiffLine(oldNumber: kind == .deleted ? start + offset : nil,
                    newNumber: kind == .added ? start + offset : nil,
                    text: String(text.prefix(4000)), kind: kind)
            }
        }
        var removed = rows(old, start: hunk.oldStart, count: hunk.oldCount, kind: .deleted)
        var added = rows(new, start: hunk.newStart, count: hunk.newCount, kind: .added)
        for i in 0..<min(removed.count, added.count) {
            let ranges = changedRanges(removed[i].text, added[i].text)
            removed[i].emphasis = ranges.0; added[i].emphasis = ranges.1
        }
        preview.rows = removed + added
        return preview
    }

    /// Prefix/suffix comparison is bounded by the displayed line; it never runs a quadratic word diff.
    static func changedRanges(_ old: String, _ new: String) -> (NSRange, NSRange) {
        let a = Array(old), b = Array(new)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let location = String(a.prefix(prefix)).utf16.count
        return (NSRange(location: location, length: String(a[prefix..<(a.count - suffix)]).utf16.count),
                NSRange(location: String(b.prefix(prefix)).utf16.count, length: String(b[prefix..<(b.count - suffix)]).utf16.count))
    }
}


extension GitReader {
    func history(root: URL, file: URL) -> (URL?, [GitCommit], String?) {
        let current = snapshot(folder: root, file: nil, source: nil)
        guard let repository = current.root, !Task.isCancelled else {
            return (nil, [], L10n.text("Git history is unavailable for this folder.", "此文件夹没有可用的 Git 历史。"))
        }
        let prefix = repository.path == "/" ? "/" : repository.path + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return (repository, [], nil) }
        var relative = String(path.dropFirst(prefix.count))
        relative = current.changes.first(where: { $0.path == relative })?.originalPath ?? relative
        let log = reviewGit(["--literal-pathspecs", "log", "--follow", "--first-parent", "-n", "100",
            "--format=%H%x00%P%x00%an%x00%aI%x00%s%x00", "--name-status", "-z", "--", relative], root: repository)
        guard !Task.isCancelled else { return (repository, [], nil) }
        if log.status != 0 {
            let head = reviewGit(["rev-parse", "--verify", "HEAD"], root: repository)
            return (repository, [], head.status == 0 ? L10n.text("Unable to read history. Try again.", "无法读取历史，请重试。") : nil)
        }
        if log.truncated { return (repository, [], L10n.text("History metadata exceeds the preview limit.", "历史信息超出预览大小限制。")) }
        return (repository, Self.parseHistory(log.output), nil)
    }

    static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func parseHistory(_ output: String) -> [GitCommit] {
        let fields = output.components(separatedBy: "\0")
        var result: [GitCommit] = [], i = 0
        while i + 4 < fields.count {
            guard isObjectID(fields[i]) else { i += 1; continue }
            let hash = fields[i], parents = fields[i + 1].split(separator: " ").map(String.init)
            let author = fields[i + 2], date = fields[i + 3], subject = fields[i + 4]
            i += 5
            var path = "", oldPath = "", status = ""
            while i < fields.count, !isObjectID(fields[i]) {
                let change = fields[i].trimmingCharacters(in: .newlines); i += 1
                guard !change.isEmpty, i < fields.count else { continue }
                let from = fields[i]; i += 1
                var to = from
                if change.hasPrefix("R") || change.hasPrefix("C") {
                    guard i < fields.count else { break }
                    to = fields[i]; i += 1
                }
                if path.isEmpty { path = to; oldPath = from; status = change }
            }
            if !path.isEmpty { result.append(GitCommit(hash: hash, parents: parents, author: author, date: date,
                subject: subject, path: path, oldPath: oldPath, status: status)) }
        }
        return result
    }

    func commitDiff(root: URL, commit: GitCommit) -> GitDiffPreview {
        guard Self.isObjectID(commit.hash), !Task.isCancelled else { return GitDiffPreview() }
        let patch = reviewGit(["--literal-pathspecs", "show", "--format=", "-m", "--first-parent", "--root", "--find-renames",
            "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", commit.hash, "--", commit.oldPath, commit.path], root: root)
        guard !Task.isCancelled else { return GitDiffPreview() }
        guard patch.status == 0 else { return GitDiffPreview(error: L10n.text("Unable to read this commit.", "无法读取此提交。")) }
        var preview = Self.parsePatch(patch.output)
        preview.truncated = preview.truncated || patch.truncated
        preview.heading = String(commit.hash.prefix(8)) + " · " + commit.subject
        return preview
    }

    static func parsePatch(_ patch: String) -> GitDiffPreview {
        var preview = GitDiffPreview(), old = 0, new = 0, inHunk = false
        var removed: [Int] = [], added: [Int] = []
        func emphasize() {
            for i in 0..<min(removed.count, added.count) {
                let ranges = changedRanges(preview.rows[removed[i]].text, preview.rows[added[i]].text)
                preview.rows[removed[i]].emphasis = ranges.0; preview.rows[added[i]].emphasis = ranges.1
            }
            removed = []; added = []
        }
        for line in patch.components(separatedBy: "\n") {
            if preview.rows.count >= 1000 { preview.truncated = true; break }
            if let hunk = GitHunk.parse(line) {
                emphasize(); old = hunk.oldStart; new = hunk.newStart; inHunk = true
                preview.rows.append(GitDiffLine(oldNumber: nil, newNumber: nil, text: line, kind: nil)); continue
            }
            if line.hasPrefix("diff --git ") { emphasize(); inHunk = false; continue }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                preview.rows.append(GitDiffLine(oldNumber: nil, newNumber: nil,
                    text: L10n.text("Binary content changed", "二进制内容已修改"), kind: nil)); continue
            }
            guard inHunk, let prefix = line.first, ["-", "+", " "].contains(prefix) else { continue }
            let content = String(line.dropFirst())
            if content.count > 4000 { preview.truncated = true }
            let text = String(content.prefix(4000))
            switch prefix {
            case "-":
                removed.append(preview.rows.count)
                preview.rows.append(GitDiffLine(oldNumber: old, newNumber: nil, text: text, kind: .deleted)); old += 1
            case "+":
                added.append(preview.rows.count)
                preview.rows.append(GitDiffLine(oldNumber: nil, newNumber: new, text: text, kind: .added)); new += 1
            default:
                emphasize()
                preview.rows.append(GitDiffLine(oldNumber: old, newNumber: new, text: text, kind: nil)); old += 1; new += 1
            }
        }
        emphasize()
        return preview
    }
}
