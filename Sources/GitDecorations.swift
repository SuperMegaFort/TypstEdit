import Foundation

enum GitChangeKind: String, Sendable {
    case added, modified, deleted, conflicted, untracked, renamed
    var badge: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .conflicted: return "!"
        case .untracked: return "U"
        case .renamed: return "R"
        }
    }
}

/// Compact hunk ranges: a 100,000-line addition needs one range, not 100,000 entries.
struct GitLineMarkers: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let lines: ClosedRange<Int>
        let kind: GitChangeKind
    }
    private(set) var segments: [Segment] = []
    var isEmpty: Bool { segments.isEmpty }
    mutating func append(_ range: ClosedRange<Int>, kind: GitChangeKind) {
        if let last = segments.last, last.kind == kind, range.lowerBound <= last.lines.upperBound + 1 {
            segments[segments.count - 1] = Segment(lines: last.lines.lowerBound...max(last.lines.upperBound, range.upperBound), kind: kind)
        } else { segments.append(Segment(lines: range, kind: kind)) }
    }
    subscript(line: Int) -> GitChangeKind? {
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].lines.lowerBound <= line { low = middle + 1 } else { high = middle }
        }
        guard low > 0, segments[low - 1].lines.contains(line) else { return nil }
        return segments[low - 1].kind
    }
}

/// Only coordinates are retained during normal editing; old text is loaded on demand.
struct GitHunk: Sendable, Equatable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    func contains(line: Int, lineCount: Int) -> Bool {
        if newCount == 0 { return line == min(max(1, newStart), max(1, lineCount)) }
        return line >= newStart && line < newStart + newCount
    }
    static func parse(_ header: String) -> GitHunk? {
        guard header.hasPrefix("@@ ") else { return nil }
        let parts = header.split(separator: " ")
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func pair(_ part: Substring) -> (Int, Int)? {
            let fields = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = fields.first.flatMap({ Int($0) }), start >= 0 else { return nil }
            let count = fields.count == 1 ? 1 : Int(fields[1]) ?? -1
            guard count >= 0 else { return nil }
            return (start, count)
        }
        guard let old = pair(parts[1]), let new = pair(parts[2]) else { return nil }
        return GitHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
}

struct GitDiffLine: Sendable, Equatable {
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    let kind: GitChangeKind?
    var emphasis: NSRange? = nil
}

struct GitDiffPreview: Sendable {
    var rows: [GitDiffLine] = []
    var truncated = false
    var heading = ""
    var error: String? = nil
    var previousLine: Int? = nil
    var nextLine: Int? = nil
}

struct GitCommit: Identifiable, Sendable, Equatable {
    var id: String { hash }
    let hash: String
    let parents: [String]
    let author: String
    let date: String
    let subject: String
    let path: String
    let oldPath: String
    let status: String
}
