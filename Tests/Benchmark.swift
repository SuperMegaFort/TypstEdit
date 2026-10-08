import Foundation
import AppKit

@main
struct Benchmark {
    @MainActor
    static func main() {
        let ruler = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        for lines in [10_000, 100_000] {
            let source = String(repeating: "#let x = \"中文😀\" // comment\n", count: lines)
            let start = ContinuousClock.now
            let tokens = SyntaxHighlighter.spans(in: source)
            let tokenDuration = start.duration(to: .now)
            let offsetStart = ContinuousClock.now
            ruler.updateLineStarts(source)
            let offsetDuration = offsetStart.duration(to: .now)
            print("\(lines) lines / \(source.utf8.count) UTF-8 bytes: tokenization \(tokenDuration), line-offset cache \(offsetDuration), spans \(tokens.count)")
            for position in [0, lines / 2, lines - 1] {
                ruler.updateLineStarts(source)
                let offset = ruler.lineStarts[position]
                let edited = (source as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "x")
                var full: [Double] = [], incremental: [Double] = []
                func milliseconds(_ duration: Duration) -> Double {
                    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                }
                for _ in 0..<20 {
                    ruler.updateLineStarts(source)
                    let start = ContinuousClock.now
                    ruler.applyEdit(in: edited as NSString, editedRange: NSRange(location: offset, length: 1), changeInLength: 1)
                    incremental.append(milliseconds(start.duration(to: .now)))
                    let fullStart = ContinuousClock.now
                    ruler.updateLineStarts(edited)
                    full.append(milliseconds(fullStart.duration(to: .now)))
                }
                full.sort(); incremental.sort()
                print("  edit at line \(position + 1): full median \(full[10]) ms / p95 \(full[18]) ms; incremental median \(incremental[10]) ms / p95 \(incremental[18]) ms")
            }
        }
    }
}
