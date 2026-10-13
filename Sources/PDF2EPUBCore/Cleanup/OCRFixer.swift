import Foundation

/// Corrections to OCR'd words that need no language model: the dictionary pins down a
/// single answer that is a plausible OCR misreading. Also the validation every model
/// answer must pass. Runs whether or not Apple Intelligence is available.
public final class OCRFixer {
    public let suspects: OCRSuspects?
    /// Human-readable record of fixes made, for --keep-intermediate.
    public var applied: [String] = []

    public init(suspects: OCRSuspects?) {
        self.suspects = suspects
    }

    /// The fragment as a bare word, if it is one ("poctry," → "poctry").
    static func plainWord(_ fragment: String) -> String? {
        let w = fragment.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        return !w.isEmpty && w.allSatisfy(\.isLetter) ? w : nil
    }

    /// Dictionary suggestions that are an OCR confusion away from `word`.
    func confusableGuesses(_ word: String) -> [String] {
        guard let lexicon = suspects?.lexicon else { return [] }
        return lexicon.guesses(word).filter {
            !$0.contains(" ") && !$0.contains("-") && $0 != word && Self.isOCRConfusion(word, $0) && lexicon.isWord($0)
        }
    }

    /// Fixes with exactly one possible answer don't need the model: "forcigner" can only be
    /// "foreigner". Words that recur in the book are left alone (likely real terms).
    func applyCertainFixes(_ blocks: inout [Block], log: Log? = nil) -> Int {
        guard let suspects else { return 0 }
        var cache: [String: String?] = [:]
        var fixed = 0
        for i in blocks.indices {
            log?.progress("preparing", i / 2 + 1, blocks.count)
            guard blocks[i].flags.contains(.lowConfidence) else { continue }
            for fragment in suspects.suspects(in: InlineStyle.stripSuperscripts(blocks[i].text)) {
                // Lowercase words, or capitalized ones whose lowercase form is the misread
                // ("Setdements" in a heading); names have no dictionary twin and are skipped.
                guard let word = Self.plainWord(fragment), word.count >= 5,
                      word.dropFirst().allSatisfy(\.isLowercase),
                      (suspects.counts[word.lowercased()] ?? 0) < 3 else { continue }
                let capitalized = word.first?.isUppercase == true
                let lower = word.lowercased()
                let answer: String?
                if let c = cache[word] { answer = c } else {
                    // The correction must be a word this book itself uses elsewhere.
                    let guesses = confusableGuesses(lower).filter {
                        $0.allSatisfy(\.isLowercase) && (suspects.counts[$0] ?? 0) >= 2
                    }
                    // Capitalized words may be foreign ("Historie"): only the multi-letter
                    // confusions (tl→d, rn→m, cl→d) are safe enough there.
                    let multi = ["tl", "rn", "cl", "li", "vv"]
                    let ok = guesses.count == 1 && (!capitalized || multi.contains { guesses[0].contains($0) && !lower.contains($0) })
                    answer = ok ? (capitalized ? guesses[0].prefix(1).uppercased() + guesses[0].dropFirst() : guesses[0]) : nil
                    cache[word] = answer
                }
                guard let answer, let valid = validFix(original: word, answer: answer) else { continue }
                let plain = blocks[i].plainText
                guard let r = plain.range(of: word) else { continue }
                if let patched = TextPatch.apply(to: blocks[i].text, newPlain: plain.replacingCharacters(in: r, with: valid)) {
                    blocks[i].text = patched
                    applied.append("### page \(blocks[i].page + 1) (dictionary)\n\(word) → \(valid)")
                    fixed += 1
                }
            }
        }
        return fixed
    }

    // MARK: - Validation

    /// Accepts a fix only if it repairs something and modernizes nothing.
    ///
    /// The model likes to "help": unnumber'd → unnumbered, favouring → favoring,
    /// Clytæmnestra → Clytemnestra. So: punctuation-only repairs are fine; a spelling change
    /// is allowed only from a non-word to a word; elisions and ligatures are never removed.
    func validFix(original: String, answer raw: String) -> String? {
        var answer = raw.components(separatedBy: .newlines).first ?? raw
        answer = answer.trimmingCharacters(in: .whitespaces)
        for prefix in ["Fragment:", "Corrected:", "Answer:"] where answer.hasPrefix(prefix) {
            answer = String(answer.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if answer.count >= 2, answer.first == "\"", answer.last == "\"", !original.hasPrefix("\"") {
            answer = String(answer.dropFirst().dropLast())
        }
        answer = SmartQuotes.apply(answer)
        guard !answer.isEmpty, answer != original else { return nil }
        // rn↔m and cl↔d cost two edits.
        guard TextMetrics.distance(original, answer) <= max(2, min(3, original.count / 3)) else { return nil }
        let ow = original.split(separator: " ").count, aw = answer.split(separator: " ").count
        guard abs(ow - aw) <= 1 else { return nil }

        // Never drop an elision mark, a diacritic or a ligature the book printed (Yüan, æ).
        for mark in ["’", "'"] where original.components(separatedBy: mark).count > answer.components(separatedBy: mark).count {
            return nil
        }
        guard Self.markedCount(answer) >= Self.markedCount(original) else { return nil }
        // Numbers are never dropped or changed (note references, dates, page numbers).
        guard original.filter(\.isNumber) == answer.filter(\.isNumber) else { return nil }
        // OCR confuses case only for letters whose shapes match (c/C, o/O, s/S…).
        let caseConfusable = Set("cosuvwxzCOSUVWXZ")
        let oLetters = Array(original.filter(\.isLetter)), aLetters = Array(answer.filter(\.isLetter))
        if oLetters.count == aLetters.count {
            for (x, y) in zip(oLetters, aLetters) where x != y && x.lowercased() == y.lowercased() && !caseConfusable.contains(x) {
                return nil
            }
        }
        // Never split a word with a hyphen ("Setdements" → "Set-dements").
        if answer.range(of: #"\p{L}-\p{L}"#, options: .regularExpression) != nil,
           original.range(of: #"\p{L}-\p{L}"#, options: .regularExpression) == nil { return nil }
        let letters = { (s: String) in s.filter(\.isLetter) }
        if letters(original) == letters(answer) {
            // Punctuation-only repairs: insert an apostrophe, hyphen → dash, swap a quote's
            // style, rejoin a split word. Never delete marks or change their meaning.
            return Self.isPunctuationRepair(original, answer) ? answer : nil
        }
        // The change must be something OCR does (tl→d, c→e), not a respelling: "ancle" →
        // "ankle" modernizes Austen, "Peroz" → "Perez" invents a name.
        guard Self.isOCRConfusion(original, answer) else { return nil }
        // Capitalized words are mostly names; only fix them into a common word ("Tbe" → "The").
        if original.first?.isUppercase == true, let lexicon = suspects?.lexicon {
            guard !lexicon.isWord(original.lowercased()), lexicon.isWord(answer.lowercased()) else { return nil }
        }

        guard let lexicon = suspects?.lexicon else { return nil }
        let words = { (s: String) in s.split(whereSeparator: { !$0.isLetter && $0 != "’" && $0 != "'" }).map(String.init) }
        let originalIsWords = words(original).allSatisfy { lexicon.isWord($0) }
        let answerIsWords = words(answer).allSatisfy { lexicon.isWord($0) }
        return !originalIsWords && answerIsWords ? answer : nil
    }

    /// True if `a` and `b` differ only by the confusions OCR engines actually make:
    /// c/e, i/l/1, 0/o, h/b, and the ligature-like rn→m, cl→d, tl→d ("Setdements" for
    /// "Settlements"), li→h, vv→w. Letters are never simply added or dropped.
    static func isOCRConfusion(_ a: String, _ b: String) -> Bool {
        func canonical(_ s: String) -> String {
            var t = s.lowercased()
            for (from, to) in [("rn", "m"), ("cl", "d"), ("tl", "d"), ("li", "h"), ("vv", "w")] {
                t = t.replacingOccurrences(of: from, with: to)
            }
            var out = ""
            for c in t {
                switch c {
                case "c", "e": out.append("e")
                case "i", "l", "1", "|", "!": out.append("l")
                case "o", "0": out.append("o")
                case "h", "b": out.append("h")
                case "'", "’", "‘", "\"", "“", "”", "-", "—", " ", ".", ",":
                    continue
                default: out.append(c)
                }
            }
            return out
        }
        return canonical(a) == canonical(b)
    }

    static func isPunctuationRepair(_ a: String, _ b: String) -> Bool {
        let quotes = Set("\"'“”‘’")
        func family(_ c: Character) -> Character {
            if quotes.contains(c) { return "\"" }
            if "-—–".contains(c) { return "-" }
            return c
        }
        for (op, c) in diffOps(Array(a), Array(b)) {
            switch op {
            case .insert where c == "’" || c == "'": continue
            case .delete where c == " ": continue           // "return d" → "return’d"
            case .substitute(let from) where family(from) == family(c): continue
            case .substitute(let from) where from == " " && (c == "’" || c == "'"): continue
            default: return false
            }
        }
        return true
    }

    enum DiffOp { case insert, delete, substitute(Character) }

    /// Character edits turning `a` into `b` (keeps are omitted).
    static func diffOps(_ a: [Character], _ b: [Character]) -> [(DiffOp, Character)] {
        var out: [(DiffOp, Character)] = []
        let ops = TextPatch.align(a, b)
        var i = 0
        for op in ops {
            switch op {
            case .keep: i += 1
            case .substitute(let n): out.append((.substitute(a[i]), n)); i += 1
            case .delete: out.append((.delete, a[i])); i += 1
            case .insert(let n): out.append((.insert, n))
            }
        }
        return out
    }

    /// Characters carrying a diacritic or ligature (é, ü, æ, œ).
    static func markedCount(_ s: String) -> Int {
        s.filter { c in String(c).decomposedStringWithCanonicalMapping.unicodeScalars.count > 1
            || "æÆœŒøØ".contains(c) }.count
    }

}
