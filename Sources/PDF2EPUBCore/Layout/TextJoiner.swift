import Foundation

/// Joins lines into running text, undoing end-of-line hyphenation.
public enum TextJoiner {
    static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AC}"]
    static let dashes: Set<Character> = ["—", "–"]

    public static func joinLines(_ lines: [String], context: LayoutContext) -> (text: String, ambiguousHyphen: Bool) {
        var out = ""
        var ambiguous = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if out.isEmpty { out = line; continue }
            let r = join(out, line, context: context)
            out = r.text
            ambiguous = ambiguous || r.ambiguous
        }
        return (InlineStyle.tidy(out), ambiguous)
    }

    /// Joins `b` onto `a`, where `b` starts a new visual line (or page).
    public static func join(_ a: String, _ b: String, context: LayoutContext) -> (text: String, ambiguous: Bool) {
        guard let endIdx = lastVisibleIndex(a) else { return (a + b, false) }
        let end = a[endIdx]
        let firstVisible = b.first(where: { !InlineStyle.isMarker($0) })

        if hyphens.contains(end), endIdx > a.startIndex, a[a.index(before: endIdx)].isLetter,
           let first = firstVisible, first.isLetter {
            let left = trailingWord(a, before: endIdx)
            let right = leadingWord(b)
            let decision = decideHyphen(left: left, right: right, nextIsLower: first.isLowercase, context: context)
            var head = a
            if !decision.keepHyphen { head.remove(at: endIdx) }
            return (InlineStyle.tidy(head + b), decision.ambiguous)
        }
        // "152-" + "layer": a hyphen after a digit is real; join without a space.
        if hyphens.contains(end), endIdx > a.startIndex, a[a.index(before: endIdx)].isNumber,
           let first = firstVisible, first.isLetter || first.isNumber {
            return (InlineStyle.tidy(a + b), false)
        }
        // "--" is a typewriter em dash.
        if end == "-", endIdx > a.startIndex, a[a.index(before: endIdx)] == "-" {
            return (InlineStyle.tidy(a + b), false)
        }
        if dashes.contains(end) && end == "—" {
            return (InlineStyle.tidy(a + b), false)
        }
        if let first = firstVisible, first == "—" {
            return (InlineStyle.tidy(a + b), false)
        }
        return (InlineStyle.tidy(a + " " + b), false)
    }

    struct HyphenDecision { var keepHyphen: Bool; var ambiguous: Bool }

    static func decideHyphen(left: String, right: String, nextIsLower: Bool, context: LayoutContext) -> HyphenDecision {
        // "Anglo-\nSaxon": a capital after the break means a real hyphen.
        guard nextIsLower else { return HyphenDecision(keepHyphen: true, ambiguous: false) }
        guard !left.isEmpty, !right.isEmpty else { return HyphenDecision(keepHyphen: false, ambiguous: false) }
        let joined = left + right
        let hyphenated = left + "-" + right
        let lowerJoined = joined.lowercased(), lowerHyph = hyphenated.lowercased()
        // The book's own usage elsewhere is the best evidence.
        let seenHyph = context.hyphenatedWords.contains(lowerHyph)
        let seenJoined = context.knownWords.contains(lowerJoined)
        if seenHyph && !seenJoined { return HyphenDecision(keepHyphen: true, ambiguous: false) }
        if seenJoined && !seenHyph { return HyphenDecision(keepHyphen: false, ambiguous: false) }
        let lex = context.lexicon
        let joinedOK = lex.isWord(joined)
        let partsOK = left.count >= 2 && right.count >= 2 && lex.isWord(left) && lex.isWord(right)
        if joinedOK && !partsOK { return HyphenDecision(keepHyphen: false, ambiguous: false) }
        if joinedOK && partsOK {
            // "to-day"/"today", "some-thing"/"something": join, but let the model look.
            return HyphenDecision(keepHyphen: false, ambiguous: seenHyph || left.count >= 3 && right.count >= 3)
        }
        if partsOK { return HyphenDecision(keepHyphen: true, ambiguous: false) }
        // Neither form is in the dictionary (names, rare words): a line-end hyphen is usually a break.
        return HyphenDecision(keepHyphen: false, ambiguous: false)
    }

    static func lastVisibleIndex(_ s: String) -> String.Index? {
        var i = s.endIndex
        while i > s.startIndex {
            i = s.index(before: i)
            if !InlineStyle.isMarker(s[i]) && !s[i].isWhitespace { return i }
        }
        return nil
    }

    static func trailingWord(_ s: String, before idx: String.Index) -> String {
        var chars: [Character] = []
        var i = idx
        while i > s.startIndex {
            i = s.index(before: i)
            let c = s[i]
            if InlineStyle.isMarker(c) { continue }
            if c.isLetter || c == "'" || c == "’" { chars.append(c) } else { break }
        }
        return String(chars.reversed())
    }

    static func leadingWord(_ s: String) -> String {
        var out = ""
        for c in s {
            if InlineStyle.isMarker(c) { continue }
            if c.isLetter || c == "'" || c == "’" { out.append(c) } else { break }
        }
        return out
    }

    /// Collects words and hyphenated compounds that appear inside lines (not at line ends),
    /// so dehyphenation can follow the book's own spelling.
    public static func vocabulary(from lines: [String]) -> (words: Set<String>, hyphenated: Set<String>) {
        var words = Set<String>(), hyphenated = Set<String>()
        for line in lines {
            let tokens = InlineStyle.strip(line).split(whereSeparator: { $0.isWhitespace })
            for (i, raw) in tokens.enumerated() where i > 0 && i < tokens.count - 1 {
                let t = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))).lowercased()
                guard t.count >= 3, t.first?.isLetter == true, t.last?.isLetter == true else { continue }
                if t.contains("-") { hyphenated.insert(t) } else if t.allSatisfy(\.isLetter) { words.insert(t) }
            }
        }
        return (words, hyphenated)
    }
}
