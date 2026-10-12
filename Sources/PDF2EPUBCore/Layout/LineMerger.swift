import Foundation

/// Folds tiny line fragments back into the line they sit on.
///
/// Inline stacked fractions, raised symbols and stray operators come out of PDFs as
/// separate "lines" above and below the real one. Left alone they shred paragraphs.
public enum LineMerger {
    public static func mergeFragments(_ lines: [Line], body: Double) -> [Line] {
        func isFragment(_ l: Line) -> Bool {
            let n = l.plainText.trimmingCharacters(in: .whitespaces).count
            guard l.fontSize <= body * 1.3 else { return false }
            return n <= 2 || (l.fontSize < body * 0.85 && n <= 8)
        }
        var hosts = lines.filter { !isFragment($0) && $0.plainText.count > 6 }
        guard !hosts.isEmpty else { return lines }
        var attached: [Int: [Line]] = [:]
        var kept: [Line] = []
        for l in lines where isFragment(l) {
            let mid = Double(l.bbox.midY)
            let host = hosts.indices.filter { i in
                let h = hosts[i].bbox
                let slack = 0.35 * Double(h.height)
                return mid >= Double(h.minY) - slack && mid <= Double(h.maxY) + slack
                    && Double(l.bbox.minX) >= Double(h.minX) - 0.02 && Double(l.bbox.maxX) <= Double(h.maxX) + 0.06
            }.min { abs(Double(hosts[$0].bbox.midY) - mid) < abs(Double(hosts[$1].bbox.midY) - mid) }
            if let host { attached[host, default: []].append(l) } else { kept.append(l) }
        }
        for (i, frags) in attached {
            hosts[i] = insert(frags, into: hosts[i])
        }
        // Preserve original order: hosts and unattached fragments, by position.
        let others = lines.filter { !isFragment($0) && $0.plainText.count <= 6 }
        return (hosts + others + kept).sorted {
            $0.bbox.minY != $1.bbox.minY ? $0.bbox.minY < $1.bbox.minY : $0.bbox.minX < $1.bbox.minX
        }
    }

    static func insert(_ fragments: [Line], into host: Line) -> Line {
        // Pair stacked fragments (numerator over denominator) into fractions.
        var pieces: [(x: Double, text: String)] = []
        var used = Set<Int>()
        let sorted = fragments.sorted { $0.bbox.minX < $1.bbox.minX }
        for (i, a) in sorted.enumerated() where !used.contains(i) {
            if let j = sorted.indices.first(where: { j in
                j != i && !used.contains(j) && overlapX(a, sorted[j]) > 0.5
                    && abs(Double(a.bbox.midY - sorted[j].bbox.midY)) > 0.3 * Double(host.bbox.height)
            }) {
                let (top, bottom) = a.bbox.midY < sorted[j].bbox.midY ? (a, sorted[j]) : (sorted[j], a)
                used.insert(i); used.insert(j)
                pieces.append((Double(min(a.bbox.minX, sorted[j].bbox.minX)),
                               InlineStyle.strip(top.text) + "\u{2044}" + InlineStyle.strip(bottom.text)))
            } else {
                used.insert(i)
                pieces.append((Double(a.bbox.minX), a.text))
            }
        }
        var line = host
        var text = host.text
        let width = max(Double(host.bbox.width), 0.0001)
        // Insert right to left so earlier positions stay valid.
        for piece in pieces.sorted(by: { $0.x > $1.x }) {
            let frac = (piece.x - Double(host.bbox.minX)) / width
            text = insertAt(text, fraction: frac, piece: piece.text)
        }
        line.text = InlineStyle.tidy(text)
        line.bbox = fragments.reduce(host.bbox) { $0.union($1.bbox) }
        return line
    }

    /// Inserts at a proportional position, snapped to the nearest word boundary.
    static func insertAt(_ text: String, fraction: Double, piece: String) -> String {
        let chars = Array(text)
        let visible = chars.indices.filter { !InlineStyle.isMarker(chars[$0]) }
        guard !visible.isEmpty else { return piece + text }
        if fraction >= 0.98 { return text + " " + piece }
        if fraction <= 0.02 { return piece + " " + text }
        let target = visible[min(visible.count - 1, max(0, Int(fraction * Double(visible.count))))]
        let spaces = chars.indices.filter { chars[$0] == " " }
        guard let snap = spaces.min(by: { abs($0 - target) < abs($1 - target) }), abs(snap - target) <= 6 else {
            return text + " " + piece
        }
        return String(chars[..<snap]) + " " + piece + String(chars[snap...])
    }

    static func overlapX(_ a: Line, _ b: Line) -> Double {
        let o = min(a.bbox.maxX, b.bbox.maxX) - max(a.bbox.minX, b.bbox.minX)
        return Double(o) / Double(max(min(a.bbox.width, b.bbox.width), 0.0001))
    }
}
