import Foundation

public enum TextMetrics {
    /// Levenshtein distance over Unicode scalars.
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Distance divided by the longer length (0 = identical, 1 = nothing in common).
    public static func normalizedDistance(_ a: String, _ b: String) -> Double {
        let n = max(a.unicodeScalars.count, b.unicodeScalars.count)
        return n == 0 ? 0 : Double(distance(a, b)) / Double(n)
    }

    /// Text ends a sentence: terminal punctuation, optionally followed by closing quotes/brackets.
    public static func endsSentence(_ s: String) -> Bool {
        let t = InlineStyle.strip(s).trimmingCharacters(in: .whitespaces)
        var chars = Array(t)
        while let last = chars.last, "\"'”’»)]}*".contains(last) || last.isNumber && chars.count > 1 && isFootnoteDigit(chars) {
            chars.removeLast()
        }
        guard let last = chars.last else { return false }
        return ".!?:…".contains(last)
    }

    /// Trailing digits right after punctuation are footnote markers ("end.12").
    private static func isFootnoteDigit(_ chars: [Character]) -> Bool {
        var i = chars.count - 1
        while i >= 0 && chars[i].isNumber { i -= 1 }
        return i >= 0 && ".!?”’\"".contains(chars[i]) && chars.count - 1 - i <= 3
    }

    public static func firstLetter(_ s: String) -> Character? {
        InlineStyle.strip(s).first(where: { $0.isLetter })
    }

    /// First visible character, skipping markers and opening quotes.
    public static func startsLowercase(_ s: String) -> Bool {
        let t = InlineStyle.strip(s).drop(while: { $0.isWhitespace || "\"'“‘([—–-".contains($0) })
        return t.first?.isLowercase ?? false
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }
}
