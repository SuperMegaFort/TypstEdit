import Foundation

// Baseline is the first-pass implementation, retained only for reproducible A/B measurements.
private enum BaselineTokenizer {
    typealias Span = SyntaxHighlighter.Span
    static let rules: [NSRegularExpression] = [
        #"\b(?:let|set|show|import|include|if|else|for|while|break|continue|return)\b"#,
        #"#[\p{L}\p{N}_-]+"#,
        #""(?:\\.|[^"\\])*""#,
        #"\$[^\$]+\$"#,
        #"^=+\s+.*"#,
        #"//.*|/\*(?:[^*]|\*(?!/))*\*/"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    static func spans(in string: String) -> [Span] {
        let range = NSRange(location: 0, length: string.utf16.count)
        return rules.enumerated().flatMap { style, expression in
            expression.matches(in: string, range: range).map { Span(range: $0.range, style: style) }
        }
    }

}

@main
struct TokenBenchmark {
    static func main() {
        let source = String(repeating: #"#let x = "中文😀" // comment"# + "\n", count: 100_000)
        let clock = ContinuousClock.now
        if CommandLine.arguments.contains("legacy") {
            print(BaselineTokenizer.spans(in: source).count)
        } else {
            print(SyntaxHighlighter.spans(in: source).count)
        }
        print(clock.duration(to: .now))
    }
}
