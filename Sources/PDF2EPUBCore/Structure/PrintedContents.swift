import Foundation
import CoreGraphics

/// Printed page number ↔ PDF page index, from the folios found on the pages themselves.
/// Unnumbered plates and blank pages shift the offset, so map through the nearest folio.
public struct FolioMap: Sendable {
    /// (pdf page index, printed number), sorted by index.
    public var folios: [(index: Int, number: Int)]

    public init(pages: [PageLines]) {
        var out: [(Int, Int)] = []
        for p in pages {
            for (line, kind) in p.furniture where kind == .pageNumber {
                let digits = MarginFilter.ocrFolio(line.plainText).filter(\.isNumber)
                if let n = Int(digits), n > 0, n < 5000 { out.append((p.index, n)); break }
            }
        }
        // Keep only folios consistent with their neighbours (numbers rise with pages).
        folios = out.enumerated().filter { k, f in
            let prev = k > 0 ? out[k - 1] : nil, next = k + 1 < out.count ? out[k + 1] : nil
            let okPrev = prev.map { f.1 - $0.1 >= 1 && f.1 - $0.1 <= (f.0 - $0.0) + 2 } ?? true
            let okNext = next.map { $0.1 - f.1 >= 1 && $0.1 - f.1 <= ($0.0 - f.0) + 2 } ?? true
            // Keep a folio that agrees with at least one actual neighbour. A stray number
            // (a date at the foot of a page) agrees with neither.
            if prev == nil && next == nil { return true }
            return (prev != nil && okPrev) || (next != nil && okNext)
        }.map { (index: $0.element.0, number: $0.element.1) }
    }

    /// The PDF page index showing printed page `number`, if it can be placed.
    public func index(ofPrinted number: Int) -> Int? {
        guard !folios.isEmpty else { return nil }
        if let exact = folios.first(where: { $0.number == number }) { return exact.index }
        // Count forward from the folio below, or back from the folio above (chapter openings
        // often print no folio). Inserted plates only push pages later, so an estimate must
        // leave room for the pages between it and both neighbours.
        let below = folios.filter { $0.number < number }.max { $0.number < $1.number }
        let above = folios.filter { $0.number > number }.min { $0.number < $1.number }
        func fits(_ idx: Int) -> Bool {
            guard idx >= 0 else { return false }
            if let b = below, idx - b.index < number - b.number { return false }
            if let a = above, a.index - idx < a.number - number { return false }
            return true
        }
        if let b = below, fits(b.index + (number - b.number)) { return b.index + (number - b.number) }
        if let a = above, fits(a.index - (a.number - number)) { return a.index - (a.number - number) }
        return nil
    }
}

/// Reads a book's printed table of contents ("II Men ........ 40") so a scan without a PDF
/// outline still gets its real chapters, with titles, even when the chapter openings are
/// display art that no text layer contains.
public enum PrintedContents {
    /// Positions (in `pages`) of the pages that may hold the contents: from the "Contents"
    /// title onward, a few pages at most.
    public static func candidatePages(_ pages: [PageLines], pageCount: Int) -> Range<Int>? {
        let early = pages.prefix(max(25, pageCount / 8))
        guard let start = early.firstIndex(where: { p in
            p.lines.contains { isContentsTitle($0.plainText) && $0.bbox.minY < 0.5 }
        }) else { return nil }
        return start..<min(pages.count, start + 6)
    }

    /// One line of the rebuilt contents page.
    public struct Item: Sendable {
        /// Repaired numeral ("III"), if the entry is numbered.
        public var numeral: String?
        public var title: String
        /// The section list printed under the entry ("Horses — Camels — …").
        public var description: String?
        /// Index into `entries` when the item became a chapter.
        public var entry: Int?
    }

    public struct Parsed: Sendable {
        public var entries: [OutlineEntry] = []
        public var items: [Item] = []
        /// PDF page indices the contents occupy.
        public var pages: Set<Int> = []
    }

    /// - Parameter extraNumbers: page-number lines found by OCR on contents pages whose text
    ///   layer dropped them (old-style numerals often go missing), keyed by page index.
    public static func parse(pages: [PageLines], folios: FolioMap, pageCount: Int,
                             extraNumbers: [Int: [Line]] = [:]) -> Parsed {
        guard !folios.folios.isEmpty, let range = candidatePages(pages, pageCount: pageCount) else { return Parsed() }

        var rows: [(row: Row, page: Int)] = []
        var contentsPages = Set<Int>()
        for p in pages[range] {
            let pageRows = allRows(p.lines + (extraNumbers[p.index] ?? []))
            // Stop at the first page without entries once the contents have started.
            if !pageRows.contains(where: { $0.number != nil }) {
                if rows.contains(where: { $0.row.number != nil }) { break } else { continue }
            }
            contentsPages.insert(p.index)
            rows += pageRows.map { ($0, p.index) }
        }
        let raw = rows.filter { $0.row.number != nil }
        guard raw.count >= 3 else { return Parsed() }

        // Page numbers must rise. Repair a dropped leading digit (195 read as 95) when the
        // fix lands between the neighbours; drop entries that still don't fit.
        var numbers = raw.map { $0.row.number! }
        for k in numbers.indices {
            let prev = numbers[..<k].last ?? 0
            let next = numbers[(k + 1)...].first { $0 > prev } ?? Int.max
            if numbers[k] <= prev || numbers[k] >= next {
                if let fixed = [100, 200, 300, 1000].map({ numbers[k] + $0 }).first(where: { $0 > prev && $0 < next }) {
                    numbers[k] = fixed
                }
            }
        }
        // Chapter numerals, repaired from their order: OCR reads small-caps roman numerals
        // as "HI", "v i", "i x"; if most parse to their position, number them all by position.
        let numbered = raw.indices.filter { raw[$0].row.numeral != nil }
        let agree = numbered.enumerated().filter { pos, k in romanValue(raw[k].row.numeral!) == pos + 1 }.count
        let trustOrder = numbered.count >= 3 && Double(agree) >= 0.5 * Double(numbered.count)

        if ProcessInfo.processInfo.environment["PDF2EPUB_DEBUG_CONTENTS"] != nil {
            FileHandle.standardError.write(Data("folios: \(folios.folios.map { "\($0.index):\($0.number)" }.joined(separator: " "))\n".utf8))
            for (k, r) in raw.enumerated() {
                FileHandle.standardError.write(Data("entry \(r.row.title) p\(numbers[k]) → \(folios.index(ofPrinted: numbers[k]).map(String.init) ?? "nil") (contents page \(r.page))\n".utf8))
            }
        }
        var parsed = Parsed(pages: contentsPages)
        var last = 0
        var itemForRaw: [Int: Int] = [:]
        for (k, r) in raw.enumerated() {
            var item = Item(numeral: nil, title: r.row.title)
            if let pos = numbered.firstIndex(of: k) {
                item.numeral = trustOrder ? roman(pos + 1) : r.row.numeral.flatMap { romanValue($0) }.map(roman)
            }
            if numbers[k] > last, let idx = folios.index(ofPrinted: numbers[k]), idx < pageCount, idx > r.page {
                last = numbers[k]
                item.entry = parsed.entries.count
                parsed.entries.append(OutlineEntry(title: r.row.title, level: 0, page: idx, y: nil, fromPrintedContents: true))
            }
            itemForRaw[k] = parsed.items.count
            parsed.items.append(item)
        }
        // Rows without a page number between entries describe the entry above them.
        var current: Int? = nil
        var rawIndex = 0
        for (row, _) in rows {
            if row.number != nil {
                current = itemForRaw[rawIndex]
                rawIndex += 1
            } else if let c = current, !isContentsTitle(row.text), row.text.filter(\.isLetter).count >= 3 {
                let d = parsed.items[c].description
                parsed.items[c].description = d.map { TextJoiner.joinLines([$0, row.text], context: LayoutContext(bodySize: [:], lexicon: Lexicon())).text } ?? row.text
            }
        }
        if parsed.entries.count < 3 { parsed.entries = [] }
        return parsed
    }

    public static func entries(pages: [PageLines], folios: FolioMap, pageCount: Int,
                               extraNumbers: [Int: [Line]] = [:]) -> [OutlineEntry] {
        parse(pages: pages, folios: folios, pageCount: pageCount, extraNumbers: extraNumbers).entries
    }

    struct Row {
        var text: String
        var title: String
        var number: Int?
        /// The entry's leading numeral as printed (OCR-mangled maybe): "HI", "v i".
        var numeral: String?
    }

    /// All text rows of a contents page; entry rows end in a page number.
    static func allRows(_ lines: [Line]) -> [Row] {
        var rows: [[Line]] = []
        for l in lines.sorted(by: { $0.bbox.minY < $1.bbox.minY }) {
            if let last = rows.last?.first,
               min(last.bbox.maxY, l.bbox.maxY) - max(last.bbox.minY, l.bbox.minY) > 0.5 * min(last.bbox.height, l.bbox.height) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        var out: [Row] = []
        for row in rows {
            let parts = row.sorted { $0.bbox.minX < $1.bbox.minX }.map(\.plainText)
            // A right-hand column cell may be an OCR'd old-style numeral: "4o", "I05".
            // (A lone "I" or "l" there is an old-style 1.)
            let cells = parts.enumerated().map { k, t -> String in
                guard k == parts.count - 1, parts.count > 1 else { return t }
                return ["I", "l", "|"].contains(t.trimmingCharacters(in: .whitespaces)) ? "1" : MarginFilter.ocrFolio(t)
            }
            let text = cells.joined(separator: " ")
            guard let m = text.range(of: #"^(.*?\p{L}.*?)[\s.·…_]*?(\d{1,4})\s*$"#, options: .regularExpression),
                  let numRange = String(text[m]).range(of: #"\d{1,4}\s*$"#, options: .regularExpression) else {
                out.append(Row(text: text, title: text, number: nil, numeral: nil))
                continue
            }
            let whole = String(text[m])
            let number = Int(whole[numRange].trimmingCharacters(in: .whitespaces))
            let head = TOCEntry.strip(String(whole[..<numRange.lowerBound]))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".·…_")))
            let (numeral, title) = splitNumeral(head)
            guard title.filter(\.isLetter).count >= 3, title.count <= 120 else {
                out.append(Row(text: text, title: text, number: nil, numeral: nil))
                continue
            }
            out.append(Row(text: text, title: title, number: number, numeral: numeral))
        }
        return out
    }

    static func isContentsTitle(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return t == "contents" || t == "table of contents"
    }

    /// Rows that end in a page number: "Introduction . . . 3", or a title with its number in
    /// a separate right-aligned column.
    static func entryRows(_ lines: [Line]) -> [(title: String, number: Int)] {
        var rows: [[Line]] = []
        for l in lines.sorted(by: { $0.bbox.minY < $1.bbox.minY }) {
            if let last = rows.last?.first,
               min(last.bbox.maxY, l.bbox.maxY) - max(last.bbox.minY, l.bbox.minY) > 0.5 * min(last.bbox.height, l.bbox.height) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        var out: [(String, Int)] = []
        for row in rows {
            let parts = row.sorted { $0.bbox.minX < $1.bbox.minX }.map(\.plainText)
            // A right-hand column cell may be an OCR'd old-style numeral: "4o", "I05".
            // (A lone "I" or "l" there is an old-style 1.)
            let cells = parts.enumerated().map { k, t -> String in
                guard k == parts.count - 1, parts.count > 1 else { return t }
                return ["I", "l", "|"].contains(t.trimmingCharacters(in: .whitespaces)) ? "1" : MarginFilter.ocrFolio(t)
            }
            let text = cells.joined(separator: " ")
            guard let m = text.range(of: #"^(.*?\p{L}.*?)[\s.·…_]*?(\d{1,4})\s*$"#, options: .regularExpression) else { continue }
            let whole = String(text[m])
            guard let numRange = whole.range(of: #"\d{1,4}\s*$"#, options: .regularExpression),
                  let number = Int(whole[numRange].trimmingCharacters(in: .whitespaces)) else { continue }
            var title = TOCEntry.strip(String(whole[..<numRange.lowerBound]))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".·…_")))
            title = stripNumeral(title)
            guard title.filter(\.isLetter).count >= 3, title.count <= 120 else { continue }
            out.append((title, number))
        }
        return out
    }

    /// "II Men" → (nil… "II", "Men"); also OCR-mangled numerals ("HI", "v i", "i 11").
    static func splitNumeral(_ s: String) -> (numeral: String?, title: String) {
        var words = s.split(separator: " ").map(String.init)
        var numeral = ""
        while words.count > 1, let first = words.first,
              first.range(of: #"^(chapter|part|book)?[IVXLCDMivxlcdmHJl1|]{1,6}[.:]?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            numeral += first.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            words.removeFirst()
        }
        return (numeral.isEmpty ? nil : numeral, words.joined(separator: " "))
    }

    static func stripNumeral(_ s: String) -> String { splitNumeral(s).title }

    /// Value of a roman numeral as OCR tends to read it ("HI" = III, "l" = I, "11" = II).
    public static func romanValue(_ raw: String) -> Int? {
        // Look-alikes of I first ("l" would otherwise become L, fifty), then H = II.
        var t = String(raw.map { "l1|Jj".contains($0) ? "I" : $0 }).uppercased()
        t = t.replacingOccurrences(of: "H", with: "II")
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        guard !t.isEmpty, t.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        let v = t.map { values[$0]! }
        for (i, x) in v.enumerated() { total += (i + 1 < v.count && x < v[i + 1]) ? -x : x }
        return total > 0 && roman(total) == t ? total : nil
    }

    public static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }
}
