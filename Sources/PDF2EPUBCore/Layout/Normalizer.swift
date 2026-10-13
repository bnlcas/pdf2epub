import Foundation

/// Character-level cleanup for text coming out of PDF text layers and OCR.
public enum Normalizer {
    static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
        "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st", "\u{A732}": "AA", "\u{A733}": "aa",
    ]

    /// Spacing accents that TeX-produced PDFs emit as separate characters before a letter.
    static let spacingAccents: [Character: Character] = [
        "\u{00B4}": "\u{0301}", "\u{02DD}": "\u{030B}", "\u{00A8}": "\u{0308}", "\u{02C6}": "\u{0302}",
        "\u{02DC}": "\u{0303}", "\u{00B8}": "\u{0327}", "\u{02C7}": "\u{030C}", "\u{02D8}": "\u{0306}",
        "\u{00AF}": "\u{0304}", "\u{02DA}": "\u{030A}", "\u{02D9}": "\u{0307}",
    ]

    public static func normalize(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let lig = ligatures[c] {
                out += lig
            } else if let combining = spacingAccents[c], i + 1 < chars.count, chars[i + 1].isLetter {
                // "´e" → "é"
                out.append(chars[i + 1])
                out.unicodeScalars.append(combining.unicodeScalars.first!)
                i += 1
            } else if c == "\u{019F}", isLowerLetter(chars, i - 1) || isLowerLetter(chars, i + 1) {
                out += "ti" // Calibri's "ti" ligature, mis-mapped by Word's PDF export
            } else if c == "\u{01A9}", isLowerLetter(chars, i - 1) || isLowerLetter(chars, i + 1) {
                out += "tt"
            } else if c == "\u{00AD}" || c == "\u{200B}" || c == "\u{FEFF}" || c == "\u{2060}" {
                // soft hyphen, zero-width space, BOM, word joiner
            } else if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
                      scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                out.append(" ")
            } else if c == "\u{00A0}" || c == "\u{2009}" || c == "\u{202F}" || c == "\u{2002}" || c == "\u{2003}" {
                out.append(" ")
            } else if c == "\u{FFFD}" {
                // replacement character: unknown glyph, drop it
            } else {
                out.append(c)
            }
            i += 1
        }
        out = out.precomposedStringWithCanonicalMapping
        out = joinSplitSuperscripts(out)
        // Collapse runs of spaces.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    /// "state.1⁴⁸" → "state.¹⁴⁸": some fonts' narrow "1" isn't measured as raised, so a
    /// note number loses its first digit to the line. Digits glued to a word or punctuation
    /// right before a superscript belong to it ("in 694²⁶", after a space, is left alone).
    static func joinSplitSuperscripts(_ s: String) -> String {
        guard s.contains(InlineStyle.supOn) else { return s }
        let on = String(InlineStyle.supOn), off = String(InlineStyle.supOff)
        let pattern = "(?<=[\\p{L}.,;:!?”’\"')\\]])(\\d{1,2})\(on)(\\d{1,2})\(off)"
        return s.replacingOccurrences(of: pattern, with: "\(on)$1$2\(off)", options: .regularExpression)
    }

    static func isLowerLetter(_ chars: [Character], _ i: Int) -> Bool {
        i >= 0 && i < chars.count && chars[i].isLowercase
    }
}
