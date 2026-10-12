import Foundation

/// OCR reads typographic quotes as straight ASCII ones; printed books almost always used
/// curly quotes, so put them back.
public enum SmartQuotes {
    public static func apply(_ s: String) -> String {
        guard s.contains("\"") || s.contains("'") else { return fixOCRSlips(s) }
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(s.count)
        for (i, c) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let opensAfter = prev == nil || prev!.isWhitespace || "([{—–-“‘".contains(prev!)
            switch c {
            case "\"":
                out.append(opensAfter && next.map { !$0.isWhitespace } ?? false ? "“" : "”")
            case "'":
                if let p = prev, p.isLetter || p.isNumber || ".,!?;:".contains(p) {
                    out.append("’") // apostrophe or closing quote
                } else if opensAfter, let n = next, n.isLetter || n.isNumber {
                    // ’Tis, ’em, ’90s are elisions; otherwise an opening quote.
                    let word = String(chars[(i + 1)...].prefix { $0.isLetter }).lowercased()
                    out.append(["tis", "twas", "em", "twere", "twill", "neath", "gainst"].contains(word) ? "’" : "‘")
                } else {
                    out.append("’")
                }
            default:
                out.append(c)
            }
        }
        return fixOCRSlips(out)
    }

    /// Common OCR slips around quotes and dashes, repaired deterministically.
    static func fixOCRSlips(_ s: String) -> String {
        var t = s
        // “Tis → ’Tis: the apostrophe of an elision read as a double quote.
        t = t.replacingOccurrences(of: #"[“"](?=(Tis|tis|Twas|twas|Twere|twere|Twill|twill|em)\b)"#, with: "’", options: .regularExpression)
        // "pray’d:-the" → "pray’d:—the": a dash after a colon or semicolon read as a hyphen.
        t = t.replacingOccurrences(of: #"(?<=[:;])-(?=[\p{L}“‘])"#, with: "—", options: .regularExpression)
        return t
    }
}
