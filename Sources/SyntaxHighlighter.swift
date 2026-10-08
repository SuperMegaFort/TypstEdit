import AppKit

final class SyntaxHighlighter {
    struct Span: Sendable { let range: NSRange; let style: Int }
    private static let rules: [NSRegularExpression] = [
        #"\b(?:let|set|show|import|include|if|else|for|while|break|continue|return)\b"#,
        #"#[\p{L}\p{N}_-]+"#,
        #""(?:\\.|[^"\\])*""#,
        #"\$[^\$]+\$"#,
        #"^=+\s+.*"#,
        #"//.*|/\*(?:[^*]|\*(?!/))*\*/"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    private let colors: [NSColor] = [
        NSColor(red: 0.77, green: 0.40, blue: 0.38, alpha: 1),
        NSColor(red: 0.77, green: 0.49, blue: 0.88, alpha: 1),
        NSColor(red: 0.60, green: 0.77, blue: 0.49, alpha: 1),
        NSColor(red: 0.85, green: 0.73, blue: 0.45, alpha: 1),
        NSColor(red: 0.38, green: 0.69, blue: 0.93, alpha: 1),
        NSColor(red: 0.48, green: 0.54, blue: 0.58, alpha: 1)
    ]

    static func spans(in string: String, isCancelled: () -> Bool = { false }) -> [Span] {
        let range = NSRange(location: 0, length: string.utf16.count)
        var result: [Span] = []
        for (style, expression) in rules.enumerated() {
            guard !isCancelled() else { return [] }
            var events = 0
            // Check each rule and every 64 matches. Progress callbacks per scanned character
            // cost more than the matching itself; the worker serializes retiring snapshots.
            expression.enumerateMatches(in: string, range: range) { match, _, stop in
                events &+= 1
                if events % 64 == 0 && isCancelled() { stop.pointee = true }
                else if let match { result.append(Span(range: match.range, style: style)) }
            }
        }
        return isCancelled() ? [] : result
    }

    private var cachedSpans: [Span] = []
    private var styleRanges: [Range<Int>] = []
    private var renderedRange: NSRange?
    private weak var renderedLayout: NSLayoutManager?

    func invalidate() { clearRendered(); cachedSpans = []; styleRanges = [] }

    private func clearRendered() {
        if let layout = renderedLayout, let range = renderedRange {
            let length = layout.textStorage?.length ?? 0
            let safe = NSIntersectionRange(range, NSRange(location: 0, length: length))
            if safe.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: safe) }
        }
        renderedRange = nil
        renderedLayout = nil
    }

    func install(_ spans: [Span], in view: NSTextView) {
        cachedSpans = spans
        styleRanges = (0..<colors.count).map { style in
            func boundary(_ value: Int) -> Int {
                var low = 0
                var high = spans.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans[middle].style < value { low = middle + 1 } else { high = middle }
                }
                return low
            }
            return boundary(style)..<boundary(style + 1)
        }
        renderVisible(in: view)
    }

    /// Temporary colors affect drawing only: editing never restyles or relays out the entire document.
    func renderVisible(in view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer, !styleRanges.isEmpty else { return }
        let rect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        clearRendered()
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visible)
        renderedRange = visible
        renderedLayout = layout
        for (style, range) in styleRanges.enumerated() {
            var low = range.lowerBound
            var high = range.upperBound
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(cachedSpans[middle].range) <= visible.location { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < range.upperBound && cachedSpans[index].range.location < NSMaxRange(visible) {
                let intersection = NSIntersectionRange(cachedSpans[index].range, visible)
                if intersection.length > 0 {
                    layout.addTemporaryAttribute(.foregroundColor, value: colors[style], forCharacterRange: intersection)
                }
                index += 1
            }
        }
    }
}
