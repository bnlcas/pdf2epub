import Foundation
import PDFKit
import CoreGraphics

/// Text and geometry pulled from one page's text layer.
public struct ExtractedPage: Sendable {
    public var lines: [Line]
    /// Displayed page size in points.
    public var size: CGSize
    /// Fraction of glyphs drawn invisibly (render mode 3), the signature of a scanner's OCR layer.
    public var invisibleFraction: Double
    /// Normalized rectangles where images are painted.
    public var imageRects: [CGRect]
    public var plainText: String
}

/// Maps between PDF user space and normalized, top-left-origin page coordinates,
/// honouring the crop box and page rotation.
public struct PageGeometry: Sendable {
    public var box: CGRect
    public var rotation: Int

    public init(page: PDFPage) {
        box = page.bounds(for: .cropBox)
        rotation = ((page.rotation % 360) + 360) % 360
    }

    public init(box: CGRect, rotation: Int) {
        self.box = box
        self.rotation = rotation
    }

    public var displaySize: CGSize {
        rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    public func normalize(_ p: CGPoint) -> CGPoint {
        let w = box.width, h = box.height
        switch rotation {
        case 90: return CGPoint(x: (p.y - box.minY) / h, y: (p.x - box.minX) / w)
        case 180: return CGPoint(x: (box.maxX - p.x) / w, y: (p.y - box.minY) / h)
        case 270: return CGPoint(x: (box.maxY - p.y) / h, y: (box.maxX - p.x) / w)
        default: return CGPoint(x: (p.x - box.minX) / w, y: (box.maxY - p.y) / h)
        }
    }

    public func normalize(_ r: CGRect) -> CGRect {
        let a = normalize(CGPoint(x: r.minX, y: r.minY))
        let b = normalize(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

public enum TextLayerExtractor {
    struct Char {
        var ch: Character
        var rect: CGRect
        var glyph: Int?
    }

    public static func extract(page: PDFPage) -> ExtractedPage {
        let geometry = PageGeometry(page: page)
        let scan = page.pageRef.map { GlyphScanner.scan($0) } ?? ContentScan()
        let grid = GlyphGrid(glyphs: scan.glyphs)
        let ns = (page.string ?? "") as NSString

        var rawLines: [[Char]] = []
        var current: [Char] = []
        var lastSize = 0.0

        func flush() {
            if current.contains(where: { !$0.ch.isWhitespace }) { rawLines.append(current) }
            current = []
        }

        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            let s = ns.substring(with: range)
            i = range.location + range.length
            guard let ch = s.first else { continue }
            if ch == "\n" || ch == "\r" || ch == "\u{2028}" || ch == "\u{2029}" {
                flush()
                continue
            }
            let rect = page.selection(for: range)?.bounds(for: page) ?? .null
            if ch.isWhitespace || rect.isNull || rect.isEmpty || rect.width.isNaN {
                if !current.isEmpty { current.append(Char(ch: " ", rect: .null, glyph: nil)) }
                continue
            }
            let glyph = grid.match(rect)
            if let glyph, scan.glyphs[glyph].rotated { continue }
            let size = glyph.map { scan.glyphs[$0].size } ?? Double(rect.height)
            // Split a PDFKit "line" that jumps a large horizontal gap (e.g. across columns)
            // or moves to a different baseline at full size.
            if let prev = current.last(where: { !$0.rect.isNull }) {
                let gap = rect.minX - prev.rect.maxX
                let ref = max(lastSize, size, 4)
                let dy = abs(rect.midY - prev.rect.midY)
                if gap > 2.5 * ref || gap < -3 * ref || (dy > 0.8 * ref && size > 0.85 * lastSize) {
                    flush()
                }
            }
            // PDFKit sometimes misses a word space, e.g. after an italic math letter.
            // Selection rects swallow trailing gaps, so measure with the painted glyphs when we can.
            if let prev = current.last, !prev.rect.isNull, !prev.ch.isWhitespace,
               abs(rect.midY - prev.rect.midY) < 0.5 * max(rect.height, prev.rect.height) {
                let gap: Double
                if let g0 = prev.glyph, let g1 = glyph, g0 != g1 {
                    gap = Double(scan.glyphs[g1].box.minX - scan.glyphs[g0].box.maxX)
                } else {
                    gap = Double(rect.minX - prev.rect.maxX)
                }
                if gap > 0.22 * max(size, lastSize) {
                    current.append(Char(ch: " ", rect: .null, glyph: nil))
                }
            }
            for c in s {
                current.append(Char(ch: c, rect: rect, glyph: glyph))
            }
            lastSize = size
        }
        flush()

        let lines = rawLines.compactMap { buildLine($0, scan: scan, geometry: geometry) }
        let visible = scan.glyphs.filter { !$0.invisible }.count
        let invisibleFraction = scan.glyphs.isEmpty ? 0 : 1 - Double(visible) / Double(scan.glyphs.count)
        let images = scan.imageRects.map { geometry.normalize($0) }
            .map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            .filter { !$0.isNull && $0.width * $0.height > 0.0004 }
        return ExtractedPage(lines: lines, size: geometry.displaySize, invisibleFraction: invisibleFraction,
                             imageRects: images, plainText: ns as String)
    }

    /// Letter-spaced display type ("T R I B U T E", "A  S T U D Y  O F") reads as one letter
    /// per word. Within a spaced word the gaps are even; a word break is clearly wider.
    static func closeLetterSpacing(_ chars: [Char], scan: ContentScan) -> [Char] {
        // Tokens: runs of non-space characters, with their painted extents.
        struct Token { var range: Range<Int>; var minX: Double; var maxX: Double }
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i].ch.isWhitespace { i += 1; continue }
            var j = i
            var lo = Double.infinity, hi = -Double.infinity
            while j < chars.count, !chars[j].ch.isWhitespace {
                let box = chars[j].glyph.map { scan.glyphs[$0].box } ?? chars[j].rect
                if !box.isNull { lo = min(lo, Double(box.minX)); hi = max(hi, Double(box.maxX)) }
                j += 1
            }
            tokens.append(Token(range: i..<j, minX: lo, maxX: hi))
            i = j
        }
        // Runs of single-character tokens (the letter-spaced stretch may be just the opening
        // words of a paragraph: "I N  T H E  F I R S T chapter of this book").
        var drop = Set<Int>()
        var k = 0
        while k < tokens.count {
            guard tokens[k].range.count == 1 else { k += 1; continue }
            var e = k
            while e + 1 < tokens.count, tokens[e + 1].range.count == 1 { e += 1 }
            let run = Array(tokens[k...e])
            k = e + 1
            guard run.count >= 3 else { continue }
            let gaps = zip(run, run.dropFirst()).map { $1.minX - $0.maxX }.filter { $0.isFinite }
            guard let median = TextMetrics.median(gaps), median > 0 else { continue }
            // Drop spaces no wider than the letter spacing; wider ones are word breaks.
            for (a, b) in zip(run, run.dropFirst()) where (b.minX - a.maxX) <= median * 1.5 {
                for c in a.range.upperBound..<b.range.lowerBound { drop.insert(c) }
            }
        }
        return chars.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    struct Style: Equatable {
        var italic = false
        var bold = false
        var sup = false
    }

    static func buildLine(_ chars: [Char], scan: ContentScan, geometry: PageGeometry) -> Line? {
        var trimmed = chars
        while trimmed.last?.ch.isWhitespace == true { trimmed.removeLast() }
        while trimmed.first?.ch.isWhitespace == true { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        trimmed = closeLetterSpacing(trimmed, scan: scan)

        let glyphs = trimmed.compactMap { $0.glyph.map { scan.glyphs[$0] } }
        let sizes = glyphs.map(\.size).sorted()
        let heights = trimmed.filter { !$0.rect.isNull }.map { Double($0.rect.height) }.sorted()
        let fontSize = sizes.isEmpty ? (heights.isEmpty ? 10 : heights[heights.count / 2]) : sizes[sizes.count / 2]
        let baselines = glyphs.filter { $0.size > fontSize * 0.85 }.map(\.y).sorted()
        let baseline = baselines.isEmpty ? nil : baselines[baselines.count / 2]

        var styles: [Style] = []
        var smallCaps: [Bool] = []
        for c in trimmed {
            guard let gi = c.glyph else {
                styles.append(styles.last ?? Style())
                smallCaps.append(false)
                continue
            }
            let g = scan.glyphs[gi]
            let font = scan.fonts[g.font]
            var st = Style(italic: font.isItalic, bold: font.isBold, sup: false)
            if let baseline, g.size < fontSize * 0.8, g.y > baseline + fontSize * 0.15 {
                st.sup = true
            }
            styles.append(st)
            smallCaps.append(font.isSmallCaps)
        }

        // Digits and punctuation alone don't carry style: OCR layers often set old-style
        // numerals in a bold or italic font. They take the style of the letters around them.
        var k2 = 0
        while k2 < trimmed.count {
            if trimmed[k2].ch.isLetter || trimmed[k2].ch.isWhitespace || styles[k2].sup { k2 += 1; continue }
            var e = k2
            while e + 1 < trimmed.count, !trimmed[e + 1].ch.isLetter, !trimmed[e + 1].ch.isWhitespace, !styles[e + 1].sup { e += 1 }
            let before = trimmed[..<k2].lastIndex(where: { $0.ch.isLetter }).map { styles[$0] } ?? Style()
            let after = trimmed[(e + 1)...].firstIndex(where: { $0.ch.isLetter }).map { styles[$0] } ?? Style()
            for j in k2...e {
                styles[j].bold = before.bold && after.bold
                styles[j].italic = before.italic && after.italic
            }
            k2 = e + 1
        }

        // Whitespace takes the style of its surroundings so spans don't fragment at spaces.
        for k in trimmed.indices where trimmed[k].ch.isWhitespace {
            let before = k > 0 ? styles[k - 1] : Style()
            let after = trimmed[(k + 1)...].firstIndex(where: { !$0.ch.isWhitespace }).map { styles[$0] } ?? Style()
            styles[k] = Style(italic: before.italic && after.italic, bold: before.bold && after.bold, sup: false)
        }

        let letters = trimmed.indices.filter { trimmed[$0].ch.isLetter }
        let italicLetters = letters.filter { styles[$0].italic }.count
        let boldLetters = letters.filter { styles[$0].bold }.count
        let lineItalic = !letters.isEmpty && Double(italicLetters) / Double(letters.count) > 0.6
        let lineBold = !letters.isEmpty && Double(boldLetters) / Double(letters.count) > 0.6

        var text = ""
        var cur = Style()
        for (k, c) in trimmed.enumerated() {
            let st = styles[k]
            if st != cur {
                if cur.sup && !st.sup { text.append(InlineStyle.supOff) }
                if cur.italic && !st.italic { text.append(InlineStyle.italicOff) }
                if cur.bold && !st.bold { text.append(InlineStyle.boldOff) }
                if !cur.bold && st.bold { text.append(InlineStyle.boldOn) }
                if !cur.italic && st.italic { text.append(InlineStyle.italicOn) }
                if !cur.sup && st.sup { text.append(InlineStyle.supOn) }
                cur = st
            }
            text.append(smallCaps[k] ? Character(String(c.ch).uppercased()) : c.ch)
        }
        if cur.sup { text.append(InlineStyle.supOff) }
        if cur.italic { text.append(InlineStyle.italicOff) }
        if cur.bold { text.append(InlineStyle.boldOff) }

        let union = trimmed.filter { !$0.rect.isNull }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return nil }
        return Line(text: InlineStyle.tidy(text), bbox: geometry.normalize(union), fontSize: fontSize,
                    isBold: lineBold, isItalic: lineItalic, confidence: 1)
    }
}

/// Spatial hash over glyphs for nearest-glyph lookup from PDFKit character rectangles.
struct GlyphGrid {
    let glyphs: [PlacedGlyph]
    let cell = 12.0
    var buckets: [Int: [Int]] = [:]

    init(glyphs: [PlacedGlyph]) {
        self.glyphs = glyphs
        for (i, g) in glyphs.enumerated() {
            let x0 = Int((g.box.midX / cell).rounded(.down))
            let y0 = Int((g.box.midY / cell).rounded(.down))
            buckets[key(x0, y0), default: []].append(i)
        }
    }

    func key(_ x: Int, _ y: Int) -> Int { (x & 0xFFFF) << 16 | (y & 0xFFFF) }

    func match(_ r: CGRect) -> Int? {
        let cx = Double(r.midX), cy = Double(r.midY)
        let bx = Int((cx / cell).rounded(.down))
        let by = Int((cy / cell).rounded(.down))
        var best: Int? = nil
        var bestScore = Double.infinity
        for y in (by - 2)...(by + 2) {
            for x in (bx - 2)...(bx + 2) {
                for i in buckets[key(x, y)] ?? [] {
                    let g = glyphs[i]
                    let dx = abs(g.box.midX - cx), dy = abs(g.box.midY - cy)
                    guard dx < max(g.box.width, 2) / 2 + 2, dy < max(g.box.height, 2) / 2 + 2 else { continue }
                    let score = dx + dy
                    if score < bestScore { bestScore = score; best = i }
                }
            }
        }
        return best
    }
}
