import Foundation

/// Title and author when the PDF's own metadata is missing.
public enum MetadataGuesser {
    /// Library-download names: "Title _ Subtitle -- Last, First_ -- Publisher -- 1963.pdf".
    public static func fromFilename(_ url: URL) -> (title: String?, author: String?) {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: " -- ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return (nil, nil) }
        // "_" stands in for characters a filename can't hold: ":" between title parts, "." after initials.
        let title = parts[0].replacingOccurrences(of: " _ ", with: ": ").replacingOccurrences(of: "_", with: "")
        var author: String? = parts[1].replacingOccurrences(of: "_", with: ".")
        // "Schafer, Edward H." → "Edward H. Schafer" (one person; "A; B" lists stay as they are).
        if let a = author, !a.contains(";"), a.components(separatedBy: ",").count == 2 {
            let bits = a.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            author = "\(bits[1]) \(bits[0])"
        }
        if author?.isEmpty == true || author?.allSatisfy(\.isNumber) == true { author = nil }
        return (title, author)
    }

    /// The title page: the biggest text among the first pages is the title (plus a subtitle
    /// right under it), and a "by …" line or a short line of capitalized names is the author.
    public static func fromTitlePage(_ blocks: [Block], bodySize: Double, lexicon: Lexicon) -> (title: String?, author: String?) {
        // Display lettering OCRs into junk ("TßeGoß»"): a title must read as words.
        let readable = { (b: Block) -> Bool in
            let q = lexicon.quality(of: b.plainText)
            return q.tokens >= 1 && q.score >= 0.6
        }
        let front = blocks.filter { $0.page < 8 && !$0.kind.isFurniture && $0.kind != .figure }
        guard let biggest = front.filter({ $0.plainText.filter(\.isLetter).count >= 4 && $0.plainText.count <= 120 && readable($0) })
            .max(by: { ($0.fontSize ?? 0) < ($1.fontSize ?? 0) }),
              (biggest.fontSize ?? 0) >= bodySize * 1.3 else { return (nil, nil) }
        var title = oneLine(biggest.plainText)
        let samePage = front.filter { $0.page == biggest.page }
        if let i = samePage.firstIndex(where: { $0.bbox == biggest.bbox }), i + 1 < samePage.count {
            let next = samePage[i + 1]
            let nextText = oneLine(next.plainText)
            // A line of nothing but capitalized words is an author list, not a subtitle.
            let words = nextText.split(separator: " ")
            let smallWords: Set<String> = ["a", "an", "and", "of", "the", "in", "on", "to", "for", "with", "from"]
            let nameList = words.count >= 4 && words.allSatisfy { $0.first?.isUppercase == true }
                && !words.contains { smallWords.contains($0.lowercased()) }
            if (next.fontSize ?? 0) >= bodySize * 1.1, nextText.count <= 100, readable(next), !isName(nextText),
               !nameList, !nextText.lowercased().hasPrefix("by ") {
                title += ": " + nextText
            }
        }
        var author: String? = nil
        for b in samePage + front where b.bbox != biggest.bbox {
            let t = oneLine(b.plainText)
            if t.lowercased().hasPrefix("by "), isName(String(t.dropFirst(3))) { author = String(t.dropFirst(3)); break }
            if b.page == biggest.page, isName(t) { author = t; break }
        }
        return (titleCase(title), author.map(titleCase))
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "EDWARD H. SCHAFER", "Edward H. Schafer", "Jane Austen".
    static func isName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (2...4).contains(words.count), s.count <= 40 else { return false }
        return words.allSatisfy { w in
            guard let f = w.first, f.isUppercase else { return false }
            return w.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" || $0 == "'" || $0 == "’" }
        }
    }

    /// All-caps display text → title case ("THE GOLDEN PEACHES OF SAMARKAND" → "The Golden
    /// Peaches of Samarkand"). Mixed-case text is left as printed.
    static func titleCase(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy({ $0.isUppercase || !$0.isCased }) else { return s }
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        var afterColon = true
        return s.split(separator: " ").map { raw -> String in
            let w = raw.lowercased()
            defer { afterColon = raw.hasSuffix(":") }
            if !afterColon && small.contains(w) { return w }
            // Keep initials and apostrophe names: "h." → "H.", "t'ang" → "T'ang".
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
