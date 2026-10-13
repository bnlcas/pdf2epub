import Foundation
import CoreGraphics

/// Document-wide facts the per-page heuristics need.
public struct LayoutContext: Sendable {
    /// Median body font size per text source, in points.
    public var bodySize: [TextSource: Double]
    public var lexicon: Lexicon
    public var forceVerse: Bool
    /// Hyphenated compounds seen mid-line in the document ("to-day"), lowercased.
    public var hyphenatedWords: Set<String>
    /// Words seen mid-line in the document, lowercased.
    public var knownWords: Set<String>

    public init(bodySize: [TextSource: Double], lexicon: Lexicon, forceVerse: Bool = false,
                hyphenatedWords: Set<String> = [], knownWords: Set<String> = []) {
        self.bodySize = bodySize
        self.lexicon = lexicon
        self.forceVerse = forceVerse
        self.hyphenatedWords = hyphenatedWords
        self.knownWords = knownWords
    }

    func body(_ source: TextSource) -> Double { bodySize[source] ?? bodySize.values.first ?? 10 }
}

/// Groups a page's lines into blocks: paragraphs, stanzas, footnotes.
public enum BlockBuilder {
    public static func build(page: PageLines, context: LayoutContext) -> [Block] {
        var blocks: [Block] = []
        let pageHeight = Double(page.size.height), pageWidth = Double(page.size.width)
        let body = context.body(page.source)
        let merged = LineMerger.mergeFragments(page.lines, body: body)
        for seg in ReadingOrder.segments(for: merged) {
            let geom = SegmentGeometry(segment: seg, pageWidth: pageWidth, pageHeight: pageHeight, body: body)
            var lines = seg.lines
            // Footnotes: small-type lines at the bottom of a column, below the body text.
            var noteLines: [Line] = []
            while let last = lines.last, last.bbox.minY > 0.55, last.fontSize < body * 0.9,
                  lines.contains(where: { $0.fontSize >= body * 0.95 && $0.bbox.maxY < last.bbox.minY }) {
                noteLines.insert(lines.removeLast(), at: 0)
            }
            // The notes must start like notes: with a marker, or set apart by space. (On OCR'd
            // pages sizes are too noisy to go on alone, so a marker is required.)
            if let first = noteLines.first {
                let marked = footnoteMarker(first.text) != nil
                let gapAbove = lines.last.map { Double(first.bbox.minY - $0.bbox.maxY) } ?? 1
                let setApart = gapAbove > 1.2 * Double(first.bbox.height)
                if !(marked || (page.source == .textLayer && setApart)) {
                    lines += noteLines
                    noteLines = []
                }
            }
            var segmentBlocks = buildBody(lines, page: page, geom: geom, context: context)
            if let first = segmentBlocks.indices.first {
                segmentBlocks[first].flags.insert(.startsSegment)
            }
            blocks += segmentBlocks
            blocks += buildFootnotes(noteLines, page: page, geom: geom, context: context)
        }
        return blocks
    }

    // MARK: - Geometry

    struct SegmentGeometry {
        var left: Double
        var right: Double
        var width: Double { right - left }
        var pageWidth: Double
        var pageHeight: Double
        var body: Double

        init(segment: FlowSegment, pageWidth: Double, pageHeight: Double, body: Double) {
            left = segment.left
            right = segment.right
            self.pageWidth = pageWidth
            self.pageHeight = pageHeight
            self.body = body
        }

        /// One em of the given size, as a fraction of page width.
        func em(_ size: Double) -> Double { size / max(pageWidth, 1) }

        /// Expected baseline-to-baseline distance for text of this size (normalized height).
        func pitch(_ size: Double) -> Double { size * 1.25 / max(pageHeight, 1) }

        func isCentered(_ l: Line) -> Bool {
            let lm = Double(l.bbox.minX) - left, rm = right - Double(l.bbox.maxX)
            return lm > 0.06 * width && rm > 0.06 * width && abs(lm - rm) < max(0.06 * width, 3 * em(l.fontSize))
        }

        func isIndented(_ l: Line, from base: Double) -> Bool {
            let d = Double(l.bbox.minX) - base
            return d > 0.6 * em(l.fontSize) && d < 0.3 * width
        }

        func reachesRight(_ l: Line) -> Bool { Double(l.bbox.maxX) >= right - 0.04 * width }
    }

    // MARK: - Body text

    static func buildBody(_ lines: [Line], page: PageLines, geom: SegmentGeometry, context: LayoutContext) -> [Block] {
        guard !lines.isEmpty else { return [] }
        // Measured pitch for body-size lines in this segment.
        var pitches: [Double] = []
        for (a, b) in zip(lines, lines.dropFirst()) where abs(a.fontSize - b.fontSize) < 0.1 * a.fontSize {
            let d = Double(b.bbox.minY - a.bbox.minY)
            if d > 0, d < 3 * geom.pitch(a.fontSize) { pitches.append(d / a.fontSize) }
        }
        let pitchPerPoint = TextMetrics.percentile(pitches, 0.3) ?? (1.25 / geom.pageHeight)

        // 1. Hard breaks: vertical gaps, size changes, OCR paragraph changes, bold/title changes.
        var regions: [[Line]] = [[lines[0]]]
        for (a, b) in zip(lines, lines.dropFirst()) {
            let size = max(a.fontSize, b.fontSize)
            let step = Double(b.bbox.minY - a.bbox.minY)
            let expected = pitchPerPoint * size
            let ratio = max(a.fontSize, b.fontSize) / max(min(a.fontSize, b.fontSize), 0.1)
            // OCR line heights are noisy (±30%), so only big size jumps count there.
            let sizeJump = page.source == .ocr ? 1.45 : 1.12
            var hard = step > 1.45 * expected || step < -0.5 * expected || ratio > sizeJump
            if a.isBold != b.isBold, a.plainText.count < 80 || b.plainText.count < 80 { hard = true }
            if hard { regions.append([b]) } else { regions[regions.count - 1].append(b) }
        }

        // A short all-caps line opening a region is a title, not the first line of text.
        regions = regions.flatMap { region -> [[Line]] in
            guard region.count >= 3, let first = region.first else { return [region] }
            let plain = first.plainText
            let letters = plain.filter(\.isLetter)
            let caps = letters.count >= 3 && letters.allSatisfy(\.isUppercase)
            let nextCaps = region[1].plainText.filter(\.isLetter).allSatisfy(\.isUppercase)
            return caps && !nextCaps && plain.count <= 60 ? [[first], Array(region.dropFirst())] : [region]
        }

        // 2. Within each region: verse stays whole; prose splits into paragraphs.
        var blocks: [Block] = []
        for region in regions {
            if isVerse(region, geom: geom, context: context) {
                blocks.append(makeVerse(region, page: page, geom: geom))
                continue
            }
            let base = regionLeft(region, geom: geom)
            var current: [Line] = [region[0]]
            for (a, b) in zip(region, region.dropFirst()) {
                var split = false
                if TOCEntry.hasLeader(a.text) { split = true }
                // A short line that doesn't end a sentence can't be the end of a paragraph:
                // it's a run-in heading ("Poetry") or a deliberate line break.
                if Double(a.bbox.width) < 0.4 * geom.width, !TextMetrics.endsSentence(a.text),
                   !a.plainText.hasSuffix(","), !a.plainText.hasSuffix(";"), !a.plainText.hasSuffix("-"),
                   TextMetrics.firstLetter(b.text)?.isUppercase == true { split = true }
                // A short all-caps line over the text is a section head ("HORSES", "WAR PRISONERS").
                if Self.isShortCapsLine(a) && !Self.isShortCapsLine(b) { split = true }
                // Stacked headings: "3. Method" then "3.1. Setup", or a short bold line.
                if !geom.reachesRight(a) && BlockClassifier.isNumberedSection(b.plainText) && (b.isBold || a.isBold) { split = true }
                if a.isBold && !b.isBold && Double(a.bbox.width) < 0.6 * geom.width { split = true }
                // (Vision's own paragraph grouping is unreliable around dialogue, so OCR'd
                // lines are segmented by geometry like everything else.)
                if geom.isIndented(b, from: base) && !geom.isIndented(a, from: base) { split = true }
                if geom.isIndented(b, from: base) && geom.isIndented(a, from: base)
                    && abs(Double(a.bbox.minX - b.bbox.minX)) < 0.3 * geom.em(a.fontSize)
                    && !geom.reachesRight(a) && TextMetrics.endsSentence(a.text) { split = true }
                if !geom.reachesRight(a), TextMetrics.endsSentence(a.text), !TextMetrics.startsLowercase(b.text) {
                    split = true
                }
                if (geom.isCentered(a) || geom.isCentered(b)) && (!geom.reachesRight(a) || !geom.reachesRight(b))
                    && (geom.isCentered(a) != geom.isCentered(b)) { split = true }
                if split {
                    blocks.append(makeProse(current, page: page, geom: geom, base: base, context: context))
                    current = [b]
                } else {
                    current.append(b)
                }
            }
            blocks.append(makeProse(current, page: page, geom: geom, base: base, context: context))
        }
        return blocks
    }

    static func isShortCapsLine(_ l: Line) -> Bool {
        let plain = l.plainText.trimmingCharacters(in: .whitespaces)
        let letters = plain.filter(\.isLetter)
        return letters.count >= 4 && plain.count <= 40 && plain.split(separator: " ").count <= 5
            && letters.allSatisfy { $0.isUppercase || !$0.isCased } && !TextMetrics.endsSentence(plain)
    }

    /// Left edge to measure indents from: the column edge, unless the whole region is inset.
    static func regionLeft(_ region: [Line], geom: SegmentGeometry) -> Double {
        guard region.count >= 3 else { return geom.left }
        let p = TextMetrics.percentile(region.map { Double($0.bbox.minX) }, 0.2) ?? geom.left
        return max(geom.left, p - 0.002)
    }

    static func isVerse(_ region: [Line], geom: SegmentGeometry, context: LayoutContext) -> Bool {
        let minLines = context.forceVerse ? 2 : 3
        guard region.count >= minLines else { return false }
        let texts = region.map { $0.plainText.trimmingCharacters(in: .whitespaces) }
        // A word broken across lines means prose. (A detached " -" is usually scan noise.)
        if texts.contains(where: { $0.range(of: #"\p{L}-$"#, options: .regularExpression) != nil }) { return false }
        let maxRight = region.map { Double($0.bbox.maxX) }.max()!
        let nonLast = region.dropLast()
        let justified = nonLast.filter { Double($0.bbox.maxX) >= maxRight - 0.012 * geom.width }.count
        let justifiedFrac = Double(justified) / Double(max(nonLast.count, 1))
        let caps = texts.filter { t in
            guard let f = t.first(where: { $0.isLetter || $0.isNumber }) else { return false }
            return f.isUppercase
        }.count
        let capsFrac = Double(caps) / Double(texts.count)
        let terminal = texts.filter { TextMetrics.endsSentence($0) }.count
        let terminalFrac = Double(terminal) / Double(texts.count)
        let widest = region.map { Double($0.bbox.width) }.max()!
        // The fill test: prose (ragged or justified) breaks a line only when the next word
        // won't fit; verse often stops with room to spare.
        var roomy = 0
        for (a, b) in zip(region, region.dropFirst()) {
            let chars = max(a.plainText.count, 1)
            let charWidth = Double(a.bbox.width) / Double(chars)
            let nextWord = b.plainText.split(separator: " ").first.map { $0.count + 1 } ?? 1
            if maxRight - Double(a.bbox.maxX) > Double(nextWord) * charWidth * 1.15 { roomy += 1 }
        }
        let fitFrac = Double(roomy) / Double(max(region.count - 1, 1))
        // Ballads often alternate between two indents line by line.
        let shifts = zip(region, region.dropFirst()).filter { abs(Double($0.bbox.minX - $1.bbox.minX)) > 0.6 * geom.em($0.fontSize) }.count
        let altFrac = Double(shifts) / Double(max(region.count - 1, 1))
        if ProcessInfo.processInfo.environment["PDF2EPUB_DEBUG_VERSE"] != nil {
            FileHandle.standardError.write(Data(String(format: "verse? n=%d just=%.2f fit=%.2f alt=%.2f caps=%.2f term=%.2f | %@\n",
                region.count, justifiedFrac, fitFrac, altFrac, capsFrac, terminalFrac, String(texts[0].prefix(40))).utf8))
        }
        if context.forceVerse {
            return justifiedFrac < 0.7 || widest < 0.85 * geom.width
        }
        // Every line capitalized: prose essentially never does that over several lines.
        if capsFrac >= 0.8 && terminalFrac < 0.6 && justifiedFrac < 0.7 { return true }
        if capsFrac >= 0.75 && terminalFrac < 0.6 && (justifiedFrac < 0.45 || fitFrac >= 0.3) { return true }
        // Verse that doesn't capitalize every line (modern poetry): lines keep stopping with
        // room to spare, and few end a sentence. (A run of one-line dialogue paragraphs is
        // roomy too, but its lines end sentences.)
        if region.count >= 4 && terminalFrac < 0.45 && fitFrac >= 0.5 { return true }
        // Ballads that split each long line in two, the second half indented.
        return region.count >= 4 && altFrac >= 0.6 && terminalFrac < 0.35 && fitFrac >= 0.25
    }

    static func makeVerse(_ region: [Line], page: PageLines, geom: SegmentGeometry) -> Block {
        let base = TextMetrics.percentile(region.map { Double($0.bbox.minX) }, 0.2) ?? Double(region[0].bbox.minX)
        let widest = region.map { Double($0.bbox.maxX) }.max()!
        var lines: [String] = []
        var prev: Line? = nil
        for l in region {
            let indentEms = (Double(l.bbox.minX) - base) / max(geom.em(l.fontSize), 0.001)
            let text = l.text.trimmingCharacters(in: .whitespaces)
            // A turnover: the previous line ran to the margin and this indented fragment finishes it.
            if let p = prev, indentEms >= 1.5, Double(p.bbox.maxX) >= widest - 0.03 * geom.width,
               !lines.isEmpty, !TextMetrics.endsSentence(p.text) || text.count < 12 {
                lines[lines.count - 1] += " " + text
                prev = nil
                continue
            }
            let pad = indentEms >= 0.8 ? String(repeating: "\u{2003}", count: min(4, max(1, Int((indentEms / 1.5).rounded())))) : ""
            lines.append(pad + text)
            prev = l
        }
        let text = lines.joined(separator: "\n")
        var block = makeBlock(region, page: page, geom: geom, text: text, kind: .verse)
        block.firstLineIndented = false
        return block
    }

    static func makeProse(_ lines: [Line], page: PageLines, geom: SegmentGeometry, base: Double, context: LayoutContext) -> Block {
        let joined = TextJoiner.joinLines(lines.map(\.text), context: context)
        var block = makeBlock(lines, page: page, geom: geom, text: joined.text, kind: .paragraph)
        if let last = lines.last, TOCEntry.hasLeader(last.text) {
            block.text = TOCEntry.strip(block.text)
            block.flags.insert(.tocEntry)
        }
        if joined.ambiguousHyphen { block.flags.insert(.ambiguousHyphen) }
        block.firstLineIndented = geom.isIndented(lines[0], from: geom.left)
        return block
    }

    static func makeBlock(_ lines: [Line], page: PageLines, geom: SegmentGeometry, text: String, kind: BlockKind) -> Block {
        let bbox = lines.map(\.bbox).reduce(CGRect.null) { $0.union($1) }
        let sizes = lines.map(\.fontSize)
        let conf = lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        var block = Block(page: page.index, bbox: bbox, kind: kind, text: text,
                          fontSize: TextMetrics.median(sizes),
                          isBold: lines.allSatisfy(\.isBold), isItalic: lines.allSatisfy(\.isItalic),
                          confidence: conf, isCentered: lines.allSatisfy { geom.isCentered($0) },
                          source: page.source, lines: lines)
        if lines.contains(where: \.isTitle) { block.flags.insert(.ocrTitle) }
        return block
    }

    // MARK: - Footnotes

    static func buildFootnotes(_ lines: [Line], page: PageLines, geom: SegmentGeometry, context: LayoutContext) -> [Block] {
        var notes: [[Line]] = []
        var markers: [String?] = []
        for l in lines {
            if let marker = footnoteMarker(l.text) {
                notes.append([l])
                markers.append(marker)
            } else if notes.isEmpty {
                notes.append([l])
                markers.append(nil)
            } else {
                notes[notes.count - 1].append(l)
            }
        }
        return zip(notes, markers).map { group, marker in
            var text = TextJoiner.joinLines(group.map(\.text), context: context).text
            if let marker { text = stripMarker(text, marker: marker) }
            var b = makeBlock(group, page: page, geom: geom, text: text, kind: .footnote)
            b.footnoteMarker = marker
            // A note without a marker at the top of the notes continues one from the previous page.
            b.continuesFromPrevious = marker == nil
            return b
        }
    }

    static let symbolMarkers: Set<Character> = ["*", "†", "‡", "§", "¶", "‖"]

    /// Recognises "¹ text", "1 text", "1. text", "* text" at the start of a footnote line.
    public static func footnoteMarker(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(String(InlineStyle.supOn)), let end = t.firstIndex(of: InlineStyle.supOff) {
            let m = String(t[t.index(after: t.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
            if !m.isEmpty && m.count <= 4 { return m }
        }
        let plain = InlineStyle.strip(t)
        var marker = ""
        for c in plain {
            if c.isNumber || symbolMarkers.contains(c) { marker.append(c) } else { break }
            if marker.count > 3 { return nil }
        }
        guard !marker.isEmpty else { return nil }
        let rest = plain.dropFirst(marker.count)
        guard let next = rest.first, next == " " || next == "." || next == ")" || next.isUppercase else { return nil }
        if marker.allSatisfy(\.isNumber), let n = Int(marker), n > 300 { return nil }
        return marker
    }

    static func stripMarker(_ text: String, marker: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        let supped = "\(InlineStyle.supOn)\(marker)\(InlineStyle.supOff)"
        if t.hasPrefix(supped) {
            t.removeFirst(supped.count)
        } else if let r = t.range(of: marker), InlineStyle.strip(String(t[..<r.lowerBound])).isEmpty {
            t.removeSubrange(t.startIndex..<r.upperBound)
            if t.hasPrefix(".") || t.hasPrefix(")") { t.removeFirst() }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Lines from a printed table of contents: "Chapter One . . . . . 17".
public enum TOCEntry {
    static let leader = #"(\s?[.·…_]){4,}\s*([0-9]{1,4}|[ivxlcdmIVXLCDM]{1,7})?\s*$"#

    public static func hasLeader(_ text: String) -> Bool {
        InlineStyle.strip(text).range(of: leader, options: .regularExpression) != nil
    }

    /// Removes leaders and page numbers, keeping the entry's words.
    public static func strip(_ text: String) -> String {
        var t = text
        while let r = t.range(of: #"(\s?[.·…_]){4,}\s*([0-9]{1,4}|[ivxlcdmIVXLCDM]{1,7})?(?=\s|$)"#, options: .regularExpression) {
            t.replaceSubrange(r, with: "")
        }
        return InlineStyle.tidy(t.trimmingCharacters(in: .whitespaces))
    }
}
