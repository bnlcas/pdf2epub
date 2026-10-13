import Foundation

/// Assigns structural kinds (headings, captions, list items) using document-wide statistics.
public enum BlockClassifier {
    static let chapterWords = ["chapter", "chap.", "book", "part", "canto", "letter", "stave", "volume", "vol.", "act", "scene", "section", "lecture", "essay", "story", "tale"]
    static let standaloneTitles: Set<String> = ["prologue", "epilogue", "preface", "introduction", "foreword", "afterword",
                                                "contents", "table of contents", "appendix", "conclusion", "index", "dedication",
                                                "acknowledgments", "acknowledgements", "notes", "bibliography", "glossary",
                                                "postscript", "abstract", "references", "the end", "finis"]
    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                              "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
                              "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "last"]

    public static func classify(_ blocks: inout [Block], context: LayoutContext) {
        // Pass 1: captions, list items, size-based heading candidates.
        var sizeHeadings: [(index: Int, rel: Double)] = []
        let docBold = Double(blocks.filter(\.isBold).count) / Double(max(blocks.count, 1)) > 0.5
        for i in blocks.indices where blocks[i].kind == .paragraph || blocks[i].kind == .blockquote {
            let b = blocks[i]
            let plain = b.plainText.trimmingCharacters(in: .whitespaces)
            let n = plain.count
            let rel = (b.fontSize ?? context.body(b.source)) / context.body(b.source)
            let short = n <= 150 && b.lines.count <= 3

            if isCaption(plain), n <= 600 {
                blocks[i].kind = .caption
                continue
            }
            if let stripped = stripBullet(b.text) {
                blocks[i].kind = .listItem
                blocks[i].text = stripped
                continue
            }
            guard short, !plain.isEmpty else { continue }
            // Headings don't start mid-sentence or break mid-word.
            if TextMetrics.startsLowercase(plain) || plain.hasSuffix("-") { continue }
            let endsWeak = plain.hasSuffix(",") || plain.hasSuffix(";")
            if isChapterHeading(plain) {
                blocks[i].kind = .heading(1)
            } else if rel >= (b.source == .ocr ? 1.3 : 1.15) && !endsWeak && plain.count >= 1 {
                sizeHeadings.append((i, rel))
            } else if isStandaloneTitle(plain) && (b.isCentered || b.isBold || rel > 1.05 || isUppercase(plain)) {
                blocks[i].kind = .heading(1)
            } else if b.isBold && !docBold && b.lines.count <= 2 && n <= 100 && !endsWeak && !TextMetrics.endsSentence(plain) {
                blocks[i].kind = .heading(3)
            } else if b.isBold && !docBold && b.lines.count <= 2 && n <= 80 && isNumberedSection(plain) {
                blocks[i].kind = .heading(3)
            } else if b.isCentered && b.lines.count <= 2 && n >= 3 && isUppercase(plain) {
                blocks[i].kind = .heading(2)
            } else if b.lines.count == 1 && BlockBuilder.isShortCapsLine(b.lines[0]) && !isBareNumeral(plain) {
                blocks[i].kind = .heading(3)
            } else if isRunInHeading(b, next: i + 1 < blocks.count ? blocks[i + 1] : nil) {
                blocks[i].kind = .heading(3)
            } else if isBareNumeral(plain) && (b.isCentered || rel > 1.05) {
                blocks[i].kind = .heading(2)
            } else if b.isCentered && b.lines.count == 1 && n < 70 && !TextMetrics.endsSentence(plain) {
                blocks[i].flags.insert(.ambiguousKind)
            }
        }

        // Size tiers → levels. The largest tier that recurs is the chapter level; anything
        // bigger (a title page) is also level 1.
        if !sizeHeadings.isEmpty {
            var tiers: [Double] = []
            for rel in sizeHeadings.map(\.rel).sorted(by: >) {
                if let last = tiers.last, last / rel < 1.06 { continue }
                tiers.append(rel)
            }
            func tier(_ rel: Double) -> Int { tiers.firstIndex { $0 / rel < 1.06 } ?? tiers.count - 1 }
            var counts = [Int](repeating: 0, count: tiers.count)
            for h in sizeHeadings { counts[tier(h.rel)] += 1 }
            let chapterTier = counts.firstIndex { $0 >= 2 } ?? 0
            for h in sizeHeadings {
                let t = tier(h.rel)
                blocks[h.index].kind = .heading(max(1, min(3, t - chapterTier + 1)))
            }
        }

        // "Headings" with almost no letters are ornaments OCR'd as text ("5 «").
        for i in blocks.indices where blocks[i].kind.isHeading {
            let plain = blocks[i].plainText
            if plain.filter(\.isLetter).count < 3 && !isBareNumeral(plain) && !isChapterHeading(plain) {
                blocks[i].kind = .runningHeader
            }
        }
        markNumberedLists(&blocks)
        mergeDropCaps(&blocks, context: context)
        mergeChapterTitles(&blocks)
        absorbShortVerse(&blocks)
    }

    /// One- or two-line scraps beside verse (a stanza cut by a page turn) are verse too.
    static func absorbShortVerse(_ blocks: inout [Block]) {
        func neighborIsVerse(_ i: Int, step: Int) -> Bool {
            var k = i + step
            while k >= 0 && k < blocks.count {
                switch blocks[k].kind {
                case .footnote, .figure, .caption: k += step
                case .verse: return true
                default: return false
                }
            }
            return false
        }
        for i in blocks.indices where blocks[i].kind == .paragraph && (1...2).contains(blocks[i].lines.count) {
            guard neighborIsVerse(i, step: -1) || neighborIsVerse(i, step: 1) else { continue }
            let texts = blocks[i].lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let looksLikeVerse = texts.allSatisfy { t in
                let plain = InlineStyle.strip(t)
                guard let f = plain.first(where: { $0.isLetter }) else { return false }
                return f.isUppercase && !plain.hasSuffix("-")
            }
            guard looksLikeVerse else { continue }
            blocks[i].kind = .verse
            blocks[i].text = texts.joined(separator: "\n")
        }
    }

    // MARK: - Patterns

    /// A few title-case words alone on a line, followed by a paragraph: "Poetry".
    static func isRunInHeading(_ b: Block, next: Block?) -> Bool {
        let plain = b.plainText.trimmingCharacters(in: .whitespaces)
        let words = plain.split(separator: " ")
        guard b.lines.count == 1, (1...5).contains(words.count), plain.count <= 40,
              !TextMetrics.endsSentence(plain), !plain.contains(","), !plain.contains(";"),
              let first = plain.first, first.isUppercase, plain.contains(where: \.isLowercase),
              let next, next.kind == .paragraph, next.page == b.page, next.plainText.count > 80 else { return false }
        // Title case: every long word capitalized.
        return words.allSatisfy { $0.count <= 3 || $0.first?.isUppercase == true }
    }

    public static func isChapterHeading(_ plain: String) -> Bool {
        let t = plain.lowercased().trimmingCharacters(in: .whitespaces)
        guard t.count <= 120 else { return false }
        for w in chapterWords where t.hasPrefix(w + " ") || t.hasPrefix(w + ".") || t == w {
            let rest = t.dropFirst(w.count).trimmingCharacters(in: CharacterSet(charactersIn: " .:—–-"))
            let token = rest.split(whereSeparator: { " .:—–-,".contains($0) }).first.map(String.init) ?? ""
            if token.allSatisfy(\.isNumber) && !token.isEmpty { return true }
            if MarginFilter.isRoman(token) { return true }
            if numberWords.contains(token) { return true }
            if token == "the", rest.split(separator: " ").dropFirst().first.map({ numberWords.contains(String($0)) }) == true { return true }
        }
        return false
    }

    static func isStandaloneTitle(_ plain: String) -> Bool {
        let t = plain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        return standaloneTitles.contains(t)
    }

    static func isBareNumeral(_ plain: String) -> Bool {
        let t = plain.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !t.isEmpty, t.count <= 6 else { return false }
        return t.allSatisfy(\.isNumber) || MarginFilter.isRoman(t.lowercased())
    }

    static func isNumberedSection(_ plain: String) -> Bool {
        plain.range(of: #"^([0-9]+(\.[0-9]+)*|[A-Z])\.?\s+\S"#, options: .regularExpression) != nil
    }

    static func isUppercase(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 3 && letters.allSatisfy { $0.isUppercase || !$0.isCased }
    }

    public static func isCaption(_ plain: String) -> Bool {
        plain.range(of: #"^(fig\.|figure|table|plate|illustration|chart|map|diagram)\s*[0-9ivxlcIVXLC]+[a-z]?\s*[.:—–-]"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let bullets: Set<Character> = ["•", "◦", "▪", "‣", "●", "○", "■", "□", "–", "·"]

    static func stripBullet(_ text: String) -> String? {
        let plainFirst = text.first(where: { !InlineStyle.isMarker($0) })
        guard let c = plainFirst, bullets.contains(c) else { return nil }
        guard let idx = text.firstIndex(of: c) else { return nil }
        let after = text.index(after: idx)
        guard after < text.endIndex, text[after] == " " else { return nil }
        var t = text
        t.removeSubrange(idx...after)
        return t
    }

    // MARK: - Merges

    /// Runs of paragraphs numbered 1., 2., 3. (or a), b), c)) become an ordered list.
    static func markNumberedLists(_ blocks: inout [Block]) {
        func ordinal(_ b: Block) -> Int? {
            let plain = b.plainText.trimmingCharacters(in: .whitespaces)
            guard let m = plain.range(of: #"^\(?([0-9]{1,2}|[a-z])[.)]\s"#, options: .regularExpression) else { return nil }
            let token = plain[m].trimmingCharacters(in: CharacterSet(charactersIn: "().) "))
            if let n = Int(token) { return n }
            return token.unicodeScalars.first.map { Int($0.value) - 96 }
        }
        var i = 0
        while i < blocks.count {
            guard [.paragraph, .listItem].contains(blocks[i].kind), let start = ordinal(blocks[i]), start <= 3 else { i += 1; continue }
            var j = i + 1, expected = start + 1
            while j < blocks.count, [.paragraph, .listItem].contains(blocks[j].kind), ordinal(blocks[j]) == expected {
                j += 1; expected += 1
            }
            if j - i >= 2 {
                let lettered = blocks[i].plainText.trimmingCharacters(in: .whitespaces).dropFirst(blocks[i].plainText.hasPrefix("(") ? 1 : 0).first?.isLetter == true
                for k in i..<j {
                    blocks[k].kind = .listItem
                    blocks[k].listOrdinal = ordinal(blocks[k])
                    blocks[k].listLettered = lettered
                    blocks[k].text = blocks[k].text.replacingOccurrences(of: #"^\s*\(?([0-9]{1,2}|[a-z])[.)]\s+"#, with: "", options: .regularExpression)
                }
            }
            i = max(j, i + 1)
        }
    }

    /// A one-letter block in a big size right before a paragraph is a drop cap.
    static func mergeDropCaps(_ blocks: inout [Block], context: LayoutContext) {
        var i = 0
        while i + 1 < blocks.count {
            let b = blocks[i]
            let plain = b.plainText.trimmingCharacters(in: .whitespaces)
            let rel = (b.fontSize ?? 0) / context.body(b.source)
            if plain.count == 1, plain.first!.isLetter, rel >= 1.8, blocks[i + 1].page == b.page,
               blocks[i + 1].kind == .paragraph {
                var next = blocks[i + 1].text
                // "T" + "HE history" (small caps) or "T" + "he history"
                next = plain + next
                blocks[i + 1].text = next
                blocks[i + 1].flags.formUnion(b.flags.intersection([.startsSegment]))
                blocks.remove(at: i)
                continue
            }
            i += 1
        }
    }

    /// "CHAPTER I." followed directly by its title line becomes one heading.
    static func mergeChapterTitles(_ blocks: inout [Block]) {
        var i = 0
        while i + 1 < blocks.count {
            let a = blocks[i], b = blocks[i + 1]
            guard let level = a.kind.headingLevel, a.page == b.page else { i += 1; continue }
            let aPlain = a.plainText
            let isLabel = isChapterHeading(aPlain) || isBareNumeral(aPlain)
            let bPlain = b.plainText
            let bTitleLike = (b.kind.isHeading && !isNumberedSection(bPlain) && !isChapterHeading(bPlain))
                || (b.kind == .paragraph && b.lines.count <= 3 && bPlain.count <= 120 && (b.isCentered || isUppercase(bPlain)))
            let gap = Double(b.bbox.minY - a.bbox.maxY)
            if isLabel && bTitleLike && gap < 0.12 && !(b.kind.headingLevel.map { $0 > level + 1 } ?? false) {
                blocks[i].text = a.text + "\n" + b.text
                blocks[i].lines += b.lines
                blocks[i].bbox = a.bbox.union(b.bbox)
                blocks.remove(at: i + 1)
            }
            i += 1
        }
    }
}
