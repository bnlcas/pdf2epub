import Foundation
import CoreGraphics

/// A run of lines that flow top-to-bottom within one column.
public struct FlowSegment: Sendable {
    public var lines: [Line]
    /// Left and right text edges of the column this segment sits in (normalized).
    public var left: Double
    public var right: Double
    public var column: Int
}

public enum ReadingOrder {
    /// Orders a page's lines into flow segments: single column top to bottom, or for two-column
    /// pages, each band of the left column then the right, broken by full-width lines.
    public static func segments(for lines: [Line]) -> [FlowSegment] {
        guard !lines.isEmpty else { return [] }
        let sorted = sortRows(lines)

        if let gutter = detectGutter(sorted) {
            enum Side { case left, right, span }
            func side(_ l: Line) -> Side {
                if l.bbox.maxX <= gutter + 0.01 { return .left }
                if l.bbox.minX >= gutter - 0.01 { return .right }
                return .span
            }
            let leftLines = sorted.filter { side($0) == .left }
            let rightLines = sorted.filter { side($0) == .right }
            let leftEdges = edges(leftLines), rightEdges = edges(rightLines)
            let spanEdges = edges(sorted)

            var out: [FlowSegment] = []
            var bandLeft: [Line] = [], bandRight: [Line] = [], span: [Line] = []
            func flushBand() {
                if !bandLeft.isEmpty { out.append(FlowSegment(lines: bandLeft, left: leftEdges.0, right: leftEdges.1, column: 0)) }
                if !bandRight.isEmpty { out.append(FlowSegment(lines: bandRight, left: rightEdges.0, right: rightEdges.1, column: 1)) }
                bandLeft = []; bandRight = []
            }
            func flushSpan() {
                if !span.isEmpty { out.append(FlowSegment(lines: span, left: spanEdges.0, right: spanEdges.1, column: -1)) }
                span = []
            }
            for l in sorted {
                switch side(l) {
                case .left: flushSpan(); bandLeft.append(l)
                case .right: flushSpan(); bandRight.append(l)
                case .span: flushBand(); span.append(l)
                }
            }
            flushSpan()
            flushBand()
            return out
        }
        let e = edges(sorted)
        return [FlowSegment(lines: sorted, left: e.0, right: e.1, column: 0)]
    }

    /// Sorts top to bottom; lines sharing a row (vertical overlap) go left to right.
    static func sortRows(_ lines: [Line]) -> [Line] {
        let byY = lines.sorted { $0.bbox.minY < $1.bbox.minY }
        var rows: [[Line]] = []
        for l in byY {
            if var last = rows.last, let ref = last.first {
                let overlap = min(ref.bbox.maxY, l.bbox.maxY) - max(ref.bbox.minY, l.bbox.minY)
                if overlap > 0.6 * min(ref.bbox.height, l.bbox.height) {
                    last.append(l)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append([l])
        }
        return rows.flatMap { $0.sorted { $0.bbox.minX < $1.bbox.minX } }
    }

    /// Finds a vertical gutter splitting the page into two text columns, if there is one.
    static func detectGutter(_ lines: [Line]) -> Double? {
        let narrow = lines.filter { $0.bbox.width < 0.48 && $0.plainText.count > 8 }
        let left = narrow.filter { $0.bbox.maxX < 0.56 }
        let right = narrow.filter { $0.bbox.minX > 0.44 }
        guard left.count >= 5, right.count >= 5,
              Double(left.count + right.count) >= 0.45 * Double(lines.count) else { return nil }
        guard let leftMax = TextMetrics.percentile(left.map { Double($0.bbox.maxX) }, 0.9),
              let rightMin = TextMetrics.percentile(right.map { Double($0.bbox.minX) }, 0.1),
              rightMin > leftMax else { return nil }
        // Both columns must run down a good part of the page side by side.
        let lTop = left.map(\.bbox.minY).min()!, lBottom = left.map(\.bbox.maxY).max()!
        let rTop = right.map(\.bbox.minY).min()!, rBottom = right.map(\.bbox.maxY).max()!
        guard min(lBottom, rBottom) - max(lTop, rTop) > 0.2 else { return nil }
        return (leftMax + rightMin) / 2
    }

    /// Typical left and right text edges for a set of lines.
    static func edges(_ lines: [Line]) -> (Double, Double) {
        let body = lines.filter { $0.plainText.count > 20 }
        let use = body.count >= 3 ? body : lines
        let l = TextMetrics.percentile(use.map { Double($0.bbox.minX) }, 0.1) ?? 0
        let r = TextMetrics.percentile(use.map { Double($0.bbox.maxX) }, 0.9) ?? 1
        return (l, max(r, l + 0.01))
    }
}
