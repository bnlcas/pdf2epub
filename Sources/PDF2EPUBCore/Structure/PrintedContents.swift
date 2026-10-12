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
            return okPrev || okNext
        }.map { (index: $0.element.0, number: $0.element.1) }
    }

    /// The PDF page index showing printed page `number`, if it can be placed.
    public func index(ofPrinted number: Int) -> Int? {
        guard !folios.isEmpty else { return nil }
        if let exact = folios.first(where: { $0.number == number }) { return exact.index }
        // Nearest folio at or below the number, else the first one above.
        let anchor = folios.last(where: { $0.number < number }) ?? folios.first!
        let idx = anchor.index + (number - anchor.number)
        return idx >= 0 ? idx : nil
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

    /// - Parameter extraNumbers: page-number lines found by OCR on contents pages whose text
    ///   layer dropped them (old-style numerals often go missing), keyed by page index.
    public static func entries(pages: [PageLines], folios: FolioMap, pageCount: Int,
                               extraNumbers: [Int: [Line]] = [:]) -> [OutlineEntry] {
        guard !folios.folios.isEmpty, let range = candidatePages(pages, pageCount: pageCount) else { return [] }

        var raw: [(title: String, number: Int, page: Int)] = []
        for p in pages[range] {
            let rows = entryRows(p.lines + (extraNumbers[p.index] ?? []))
            // Stop at the first page without entries once the contents have started.
            if rows.isEmpty { if raw.isEmpty { continue } else { break } }
            raw += rows.map { ($0.title, $0.number, p.index) }
        }
        guard raw.count >= 3 else { return [] }

        // Page numbers must rise. Repair a dropped leading digit (195 read as 95) when the
        // fix lands between the neighbours; drop entries that still don't fit.
        var numbers = raw.map(\.number)
        for k in numbers.indices {
            let prev = numbers[..<k].last ?? 0
            let next = numbers[(k + 1)...].first { $0 > prev } ?? Int.max
            if numbers[k] <= prev || numbers[k] >= next {
                if let fixed = [100, 200, 300, 1000].map({ numbers[k] + $0 }).first(where: { $0 > prev && $0 < next }) {
                    numbers[k] = fixed
                }
            }
        }
        var out: [OutlineEntry] = []
        var last = 0
        for (k, r) in raw.enumerated() where numbers[k] > last {
            guard let idx = folios.index(ofPrinted: numbers[k]), idx < pageCount, idx > r.page else { continue }
            last = numbers[k]
            out.append(OutlineEntry(title: r.title, level: 0, page: idx, y: nil, fromPrintedContents: true))
        }
        return out.count >= 3 ? out : []
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

    /// "II Men" → "Men"; also OCR-mangled numerals ("HI", "i 11").
    static func stripNumeral(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        while words.count > 1, let first = words.first,
              first.range(of: #"^(chapter|part|book)?[IVXLCDMivxlcdmHJl1|]{1,6}[.:]?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}
