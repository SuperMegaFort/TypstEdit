import SwiftUI
import AppKit

/// Detached actor work stays off AppKit's main thread and discards cancelled results.
enum GitReviewTask {
    static func read<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let worker = Task.detached(priority: .utility) { await operation() }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}

struct GitHunkPopover: View {
    let root: URL
    let file: URL
    let source: String
    @State var line: Int
    let close: () -> Void
    @State private var preview: GitDiffPreview?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button { if let previous = preview?.previousLine { line = previous } } label: { Image(systemName: "arrow.up") }
                    .disabled(preview?.previousLine == nil).help(L10n.text("Previous change", "上一处修改"))
                Button { if let next = preview?.nextLine { line = next } } label: { Image(systemName: "arrow.down") }
                    .disabled(preview?.nextLine == nil).help(L10n.text("Next change", "下一处修改"))
                Button(action: close) { Image(systemName: "xmark") }.help(L10n.text("Close", "关闭"))
            }.buttonStyle(.borderless).padding(12)
            if let preview {
                Text(preview.heading).font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                GitDiffContent(preview: preview)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 620, height: 340)
        .preferredColorScheme(.dark)
        .task(id: line) {
            preview = nil
            let requestedLine = line
            let result = await GitReviewTask.read { await GitReader.shared.currentHunk(root: root, file: file, source: source, line: requestedLine) }
            guard !Task.isCancelled else { return }
            preview = result
        }
    }
}

struct GitHistoryRequest: Identifiable {
    let id = UUID()
    let root: URL
    let file: URL
}

struct GitHistoryView: View {
    let request: GitHistoryRequest
    @Environment(\.dismiss) private var dismiss
    @State private var commits: [GitCommit] = []
    @State private var selected: String?
    @State private var root: URL?
    @State private var loading = true
    @State private var error: String?
    @State private var preview: GitDiffPreview?
    private var commit: GitCommit? { commits.first { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("File History", "文件历史") + " · " + request.file.lastPathComponent).font(.headline)
                    Text(L10n.text("Recent 100 commits · first-parent history", "最近 100 次提交 · 主线历史")).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(L10n.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { Text(error).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if commits.isEmpty {
                Text(L10n.text("This file has no commits yet.", "此文件尚无提交记录。")).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(commits, selection: $selected) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(String(entry.hash.prefix(8)) + " · " + entry.author).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Text(String(entry.date.prefix(10))).font(.caption2).foregroundColor(.secondary)
                        }.padding(.vertical, 4).tag(entry.id)
                    }.frame(minWidth: 210, idealWidth: 240, maxWidth: 330)
                    VStack(alignment: .leading, spacing: 8) {
                        if let commit {
                            Text(commit.subject).font(.headline).textSelection(.enabled)
                            Text(String(commit.hash.prefix(8)) + " · " + commit.author + " · " + commit.date).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                            Text(commit.path == commit.oldPath ? commit.path : commit.oldPath + " → " + commit.path).font(.caption).textSelection(.enabled)
                            Text(commit.parents.isEmpty ? L10n.text("Initial commit", "首次提交") : L10n.text("Compared with first parent", "与第一个父提交比较")).font(.caption).foregroundColor(.secondary)
                        }
                        if let preview { GitDiffContent(preview: preview) }
                        else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.padding(12).frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 780, idealWidth: 940, minHeight: 480, idealHeight: 620)
        .preferredColorScheme(.dark)
        .task {
            let result = await GitReviewTask.read { await GitReader.shared.history(root: request.root, file: request.file) }
            guard !Task.isCancelled else { return }
            root = result.0; commits = result.1; error = result.2; selected = commits.first?.id; loading = false
        }
        .task(id: selected) {
            preview = nil
            guard let commit, let root else { return }
            let result = await GitReviewTask.read { await GitReader.shared.commitDiff(root: root, commit: commit) }
            guard !Task.isCancelled else { return }
            preview = result
        }
    }
}

struct GitDiffContent: View {
    let preview: GitDiffPreview
    var body: some View {
        VStack(spacing: 0) {
            if let error = preview.error { Text(error).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if preview.rows.isEmpty {
                Text(L10n.text("No text changes (for example, a rename or permission change).", "没有文本改动（可能是重命名或权限变化）。")).foregroundColor(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { GitDiffTextView(rows: preview.rows) }
            if preview.truncated {
                Text(L10n.text("Large change: showing a limited preview.", "改动较大，仅显示部分内容。")).font(.caption).foregroundColor(.secondary).padding(8)
            }
        }
    }
}

/// Selectable native text, independent of the source editor's storage and undo manager.
struct GitDiffTextView: NSViewRepresentable {
    let rows: [GitDiffLine]
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false; text.isSelectable = true; text.allowsUndo = false
        text.isRichText = false; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let content = Self.attributed(rows)
        guard text.textStorage?.isEqual(to: content) != true else { return }
        text.textStorage?.setAttributedString(content)
        text.sizeToFit()
        text.setSelectedRange(NSRange(location: 0, length: 0)); scroll.contentView.scroll(to: .zero)
    }
    static func attributed(_ rows: [GitDiffLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let width = max(3, String(rows.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 1).count)
        for row in rows {
            func number(_ value: Int?) -> String { String(repeating: " ", count: max(0, width - String(value ?? 0).count)) + (value.map(String.init) ?? " ") }
            let sign = row.kind == .deleted ? "−" : row.kind == .added ? "+" : " "
            let prefix = number(row.oldNumber) + " " + number(row.newNumber) + " " + sign + "  "
            let string = prefix + row.text + "\n"
            let entry = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            entry.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: prefix.utf16.count))
            if let kind = row.kind {
                let color: NSColor = kind == .deleted ? .systemRed : .systemGreen
                entry.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.16), range: NSRange(location: 0, length: entry.length))
                if let emphasis = row.emphasis, emphasis.length > 0, NSMaxRange(emphasis) <= row.text.utf16.count {
                    entry.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.36), range: NSRange(location: prefix.utf16.count + emphasis.location, length: emphasis.length))
                }
            }
            result.append(entry)
        }
        return result
    }
}
