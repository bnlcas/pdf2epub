import Foundation
import CoreGraphics

/// Lines for one page, as handed from ingest to layout.
public struct PageLines: Sendable {
    public var index: Int
    public var size: CGSize
    public var source: TextSource
    public var lines: [Line]
    /// Normalized regions holding pictures (placed images, OCR tables, detected figures).
    public var figureRects: [CGRect] = []
    /// Lines removed as page furniture, kept for debugging output.
    public var furniture: [(Line, BlockKind)] = []
    /// The text came from a scanner's hidden OCR layer: exact positions, but OCR mistakes.
    public var hiddenLayer = false

    public init(index: Int, size: CGSize, source: TextSource, lines: [Line], figureRects: [CGRect] = []) {
        self.index = index
        self.size = size
        self.source = source
        self.lines = lines
        self.figureRects = figureRects
    }
}

/// Removes running headers, running footers and page numbers.
///
/// Furniture lives in the top or bottom margin and repeats across pages (ignoring
/// digits), or is a bare number whose value tracks the page index.
public enum MarginFilter {
    static let topZone = 0.09
    static let bottomZone = 0.91

    public static func apply(_ pages: inout [PageLines], bodySize: [TextSource: Double] = [:]) {
        // Collect margin candidates: lines in the top/bottom zones, plus the extreme lines
        // of each page when they're close to the edge.
        struct Candidate { var page: Int; var line: Int; var key: String; var top: Bool; var extreme: Bool }
        var candidates: [Candidate] = []
        for (p, page) in pages.enumerated() {
            guard !page.lines.isEmpty else { continue }
            let sortedIdx = page.lines.indices.sorted { page.lines[$0].bbox.minY < page.lines[$1].bbox.minY }
            let topY = page.lines[sortedIdx.first!].bbox.minY
            let bottomY = page.lines[sortedIdx.last!].bbox.maxY
            for i in page.lines.indices {
                let b = page.lines[i].bbox
                let firstRow = b.minY <= topY + 0.01
                let lastRow = b.maxY >= bottomY - 0.01
                let isTop = b.maxY < topZone || (firstRow && b.minY < 0.14)
                let isBottom = b.minY > bottomZone || (lastRow && b.maxY > 0.86)
                guard isTop || isBottom || ((firstRow || lastRow) && page.lines.count > 2) else { continue }
                candidates.append(Candidate(page: p, line: i, key: key(page.lines[i].plainText), top: isTop || firstRow,
                                            extreme: (firstRow || lastRow) && page.lines.count > 2))
            }
        }

        // Page-number offset: printed number minus page index, by majority vote.
        var offsetVotes: [Int: Int] = [:]
        for c in candidates {
            for n in numbers(in: pages[c.page].lines[c.line].plainText) {
                offsetVotes[n - pages[c.page].index, default: 0] += 1
            }
        }
        let offset = offsetVotes.max { $0.value < $1.value }
        let trustedOffset = (offset?.value ?? 0) >= max(3, pages.count / 5) ? offset?.key : nil

        // Repetition counts per key, counting distinct pages. OCR'd keys also match fuzzily.
        var clusters: [(key: String, pages: Set<Int>)] = []
        var exact: [String: Int] = [:]
        var clusterOf: [Int] = []
        for c in candidates {
            if c.key.count < 3 { clusterOf.append(-1); continue }
            var idx = exact[c.key]
            if idx == nil, pages[c.page].source == .ocr {
                idx = clusters.indices.reversed().prefix(400).first { similar(clusters[$0].key, c.key) }
            }
            if let idx {
                clusters[idx].pages.insert(c.page)
                clusterOf.append(idx)
            } else {
                clusters.append((c.key, [c.page]))
                exact[c.key] = clusters.count - 1
                clusterOf.append(clusters.count - 1)
            }
        }
        let minRepeats = pages.count < 8 ? 2 : 3
        // Where each repeating line usually sits: running heads keep their position.
        var clusterY: [Int: [Double]] = [:]
        for (ci, c) in candidates.enumerated() where clusterOf[ci] >= 0 {
            clusterY[clusterOf[ci], default: []].append(Double(pages[c.page].lines[c.line].bbox.midY))
        }
        let typicalY = clusterY.mapValues { TextMetrics.median($0) ?? 0 }

        var removals: [Int: [(Int, BlockKind)]] = [:]
        for (ci, c) in candidates.enumerated() {
            let line = pages[c.page].lines[c.line]
            let text = line.plainText
            let strictZone = line.bbox.maxY < topZone || line.bbox.minY > bottomZone
            let matchesFolio = trustedOffset.map { numbers(in: text).contains(pages[c.page].index + $0) } ?? false
            // Running heads are set no larger than the text; a big line up top is a chapter
            // title. (Folios can be a touch larger than the text, so a bare number at the foot
            // of the page or in the folio sequence is still furniture.)
            let bareNumber = isPageNumber(text)
            if let body = bodySize[pages[c.page].source], line.fontSize > body * 1.12,
               !(bareNumber && (!c.top || matchesFolio)) { continue }
            var kind: BlockKind? = nil
            // Scans keep wide margins, so a folio can sit far from the page edge; but a bare
            // number that is the first or last thing on the page is still a folio.
            let isExtreme = c.extreme
            let folioText = pages[c.page].source == .ocr ? ocrFolio(text) : text
            if isPageNumber(folioText), strictZone || matchesFolio || isExtreme {
                kind = .pageNumber
            } else if clusterOf[ci] >= 0, text.count < 120,
                      clusters[clusterOf[ci]].pages.count >= (strictZone ? 2 : minRepeats),
                      abs(Double(line.bbox.midY) - (typicalY[clusterOf[ci]] ?? 0)) < 0.02 || strictZone {
                kind = c.top ? .runningHeader : .runningFooter
            } else if matchesFolio, text.count < 100 {
                kind = c.top ? .runningHeader : .runningFooter
            }
            if let kind { removals[c.page, default: []].append((c.line, kind)) }
        }
        // A line sharing its row with the folio is the running head, however rarely it repeats.
        for (p, items) in removals {
            let folios = items.filter { $0.1 == .pageNumber }.map { pages[p].lines[$0.0].bbox }
            guard !folios.isEmpty else { continue }
            let taken = Set(items.map(\.0))
            for c in candidates where c.page == p && !taken.contains(c.line) {
                let b = pages[p].lines[c.line].bbox
                let sameRow = folios.contains { abs(Double($0.midY - b.midY)) < Double(max($0.height, b.height)) * 0.8 }
                if sameRow && pages[p].lines[c.line].plainText.count < 120 {
                    removals[p, default: []].append((c.line, c.top ? .runningHeader : .runningFooter))
                }
            }
        }
        for (p, items) in removals {
            let indices = Set(items.map(\.0))
            for (i, kind) in items { pages[p].furniture.append((pages[p].lines[i], kind)) }
            pages[p].lines = pages[p].lines.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        }
    }

    /// Normalized comparison key: lowercase letters only, digits and roman numerals at the edges dropped.
    static func key(_ s: String) -> String {
        var words = s.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, isRoman(first) { words.removeFirst() }
        while let last = words.last, isRoman(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func isRoman(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 7 && s.allSatisfy { "ivxlcdm".contains($0) }
    }

    public static func isPageNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—.[]()|•·*"))
        guard !t.isEmpty, t.count <= 8 else { return false }
        if t.allSatisfy(\.isNumber) { return true }
        if isRoman(t.lowercased()) { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("page ") || lower.hasPrefix("p. ") {
            return lower.split(separator: " ").last.map { $0.allSatisfy(\.isNumber) } ?? false
        }
        return false
    }

    /// OCR often reads folios as "I 8" or "l2": map look-alikes when the result is a number.
    static func ocrFolio(_ s: String) -> String {
        let t = s.replacingOccurrences(of: " ", with: "")
        let mapped = String(t.map { c -> Character in
            switch c {
            case "I", "l", "|", "i": return "1"
            case "O", "o", "°": return "0"
            case "S": return "5"
            default: return c
            }
        })
        return mapped.allSatisfy(\.isNumber) && mapped.count <= 4 && t.contains(where: \.isNumber) ? mapped : s
    }

    static func numbers(in s: String) -> [Int] {
        let parts = s.split(whereSeparator: { !$0.isNumber })
        guard let first = parts.first, let last = parts.last else { return [] }
        // Only numbers at the start or end of the line count as folios.
        var out: [Int] = []
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.first?.isNumber == true, let n = Int(first), first.count <= 4 { out.append(n) }
        if trimmed.last?.isNumber == true, let n = Int(last), last.count <= 4 { out.append(n) }
        return out
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let la = a.count, lb = b.count
        guard abs(la - lb) <= max(2, max(la, lb) / 6) else { return false }
        return TextMetrics.normalizedDistance(a, b) <= 0.15
    }
}
