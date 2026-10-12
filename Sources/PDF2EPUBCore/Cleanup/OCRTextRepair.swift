import Foundation

/// Deterministic repairs for OCR'd text: conventions an OCR engine breaks in predictable ways.
public enum OCRTextRepair {
    /// Cyrillic and Greek letters that look like Latin ones, and digits OCR reads as letters.
    static let homoglyphs: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "к": "k", "м": "m", "т": "t",
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y",
        "ο": "o", "α": "a", "ν": "v", "ι": "i", "Ο": "O", "Α": "A", "Β": "B", "Ε": "E", "Η": "H", "Ι": "I", "Κ": "K",
        "Μ": "M", "Ν": "N", "Ρ": "P", "Τ": "T", "Χ": "X", "Υ": "Y", "Ζ": "Z",
    ]
    /// Look-alikes of old-style numerals, used when the token is otherwise numeric.
    static let digitHomoglyphs: [Character: Character] = [
        "б": "6", "з": "3", "о": "0", "О": "0", "o": "0", "O": "0", "l": "1", "I": "1", "З": "3", "Б": "6",
    ]

    public static func repair(_ text: String, lexicon: Lexicon, latinScript: Bool) -> String {
        var t = text
        if latinScript { t = fixScripts(t) }
        t = fixFullwidth(t)
        t = fixSmallCaps(t, lexicon: lexicon)
        return t
    }

    /// "SeTTLeMENTS" → "SETTLEMENTS": small caps read partly as lowercase. Only when most of
    /// the word is already capitals and the all-caps form is a real word ("ChTS" stays).
    static func fixSmallCaps(_ text: String, lexicon: Lexicon) -> String {
        var out = text
        for token in text.split(whereSeparator: { !$0.isLetter && !InlineStyle.isMarker($0) }) {
            let word = InlineStyle.strip(String(token))
            let letters = word.filter(\.isLetter)
            guard letters.count >= 4, word.first?.isUppercase == true,
                  letters.contains(where: \.isLowercase) else { continue }
            let upper = letters.filter(\.isUppercase).count
            // Not ordinary capitalization ("Settlements") or camel case ("McDonald").
            guard Double(upper) >= 0.5 * Double(letters.count), upper >= 3,
                  lexicon.isWord(word.lowercased()) else { continue }
            out = out.replacingOccurrences(of: String(token), with: String(token).uppercased())
        }
        return out
    }

    /// Cyrillic/Greek look-alikes inside Latin words or numbers ("193б" → "1936", "ТАсАмАнАс"
    /// stays only if it really is Cyrillic, i.e. mostly letters with no Latin twin).
    static func fixScripts(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x0370...0x04FF).contains($0.value) }) else { return text }
        var out = ""
        for token in text.split(separator: " ", omittingEmptySubsequences: false) {
            let foreign = token.filter { c in c.unicodeScalars.allSatisfy { (0x0370...0x04FF).contains($0.value) } }
            guard !foreign.isEmpty else { out += token + " "; continue }
            let digits = token.filter(\.isNumber).count
            let latin = token.filter { $0.isASCII && $0.isLetter }.count
            var fixed = ""
            for c in token {
                if digits > 0 && digits >= latin, let d = digitHomoglyphs[c] {
                    fixed.append(d)
                } else if let l = homoglyphs[c], latin > 0 || digits > 0 || foreign.allSatisfy({ homoglyphs[$0] != nil }) {
                    fixed.append(l)
                } else {
                    fixed.append(c)
                }
            }
            out += fixed + " "
        }
        return String(out.dropLast())
    }

    /// Fullwidth CJK punctuation in Latin text ("Giles （1932），825") becomes ASCII; next
    /// to real CJK characters it stays.
    static func fixFullwidth(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xFF01...0xFF5E).contains($0.value) || $0.value == 0x3001 || $0.value == 0x3002 }) else { return text }
        let chars = Array(text)
        func isCJK(_ c: Character?) -> Bool {
            guard let s = c?.unicodeScalars.first?.value else { return false }
            return (0x3400...0x9FFF).contains(s) || (0xF900...0xFAFF).contains(s) || (0x3040...0x30FF).contains(s)
        }
        var out = ""
        for (i, c) in chars.enumerated() {
            let v = c.unicodeScalars.first!.value
            let prev = i > 0 ? chars[i - 1] : nil, next = i + 1 < chars.count ? chars[i + 1] : nil
            if (0xFF01...0xFF5E).contains(v) || v == 0x3001 || v == 0x3002, !isCJK(prev), !isCJK(next) {
                switch v {
                case 0x3001: out.append(",")
                case 0x3002: out.append(".")
                default: out.unicodeScalars.append(Unicode.Scalar(v - 0xFEE0)!)
                }
                // Fullwidth commas/parentheses carry their own spacing; Latin text needs a space.
                if ",;:".contains(out.last!), let n = next, !n.isWhitespace { out.append(" ") }
                if out.last == "(", let p = prev, !p.isWhitespace {
                    out.insert(" ", at: out.index(before: out.endIndex))
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}
