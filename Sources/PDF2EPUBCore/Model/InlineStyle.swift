import Foundation

/// Inline styling carried inside plain strings as private-use marker characters.
///
/// Keeping styles in-band means every text operation (joining lines, dehyphenation,
/// normalization) carries italics along for free. Markers are stripped before any
/// comparison or language-model call and turned into tags by the XHTML writer.
public enum InlineStyle {
    public static let italicOn: Character = "\u{E000}"
    public static let italicOff: Character = "\u{E001}"
    public static let boldOn: Character = "\u{E002}"
    public static let boldOff: Character = "\u{E003}"
    public static let supOn: Character = "\u{E004}"
    public static let supOff: Character = "\u{E005}"

    static let all: Set<Character> = [italicOn, italicOff, boldOn, boldOff, supOn, supOff]

    public static func isMarker(_ c: Character) -> Bool { all.contains(c) }

    public static func strip(_ s: String) -> String {
        guard s.contains(where: { all.contains($0) }) else { return s }
        return String(s.filter { !all.contains($0) })
    }

    /// Wraps `s` in markers.
    public static func wrap(_ s: String, italic: Bool = false, bold: Bool = false, sup: Bool = false) -> String {
        var out = s
        if sup { out = "\(supOn)\(out)\(supOff)" }
        if italic { out = "\(italicOn)\(out)\(italicOff)" }
        if bold { out = "\(boldOn)\(out)\(boldOff)" }
        return out
    }

    /// Removes empty spans and merges adjacent spans of the same style ("…</i> <i>…" → "… …").
    public static func tidy(_ s: String) -> String {
        guard s.contains(where: { all.contains($0) }) else { return s }
        var t = s
        let pairs: [(Character, Character)] = [(italicOn, italicOff), (boldOn, boldOff), (supOn, supOff)]
        var changed = true
        while changed {
            changed = false
            for (on, off) in pairs {
                for (a, b) in [("\(on)\(off)", ""), ("\(off)\(on)", ""), ("\(off) \(on)", " ")] where t.contains(a) {
                    t = t.replacingOccurrences(of: a, with: b)
                    changed = true
                }
            }
        }
        return t
    }

    /// Ensures every opened span is closed and stray closers are dropped.
    public static func balance(_ s: String) -> String {
        guard s.contains(where: { all.contains($0) }) else { return s }
        var out = ""
        var open: [Character] = []
        let closerFor: [Character: Character] = [italicOn: italicOff, boldOn: boldOff, supOn: supOff]
        for c in s {
            if closerFor[c] != nil {
                if open.contains(c) { continue }
                open.append(c)
                out.append(c)
            } else if let opener = closerFor.first(where: { $0.value == c })?.key {
                guard let idx = open.lastIndex(of: opener) else { continue }
                // Close any spans opened after this one, then reopen them.
                let inner = open[(idx + 1)...]
                for o in inner.reversed() { out.append(closerFor[o]!) }
                out.append(c)
                open.remove(at: idx)
                for o in inner { out.append(o) }
            } else {
                out.append(c)
            }
        }
        for o in open.reversed() { out.append(closerFor[o]!) }
        return tidy(out)
    }

    /// Whether the visible text is entirely inside an italic span.
    public static func isEntirely(_ s: String, on: Character, off: Character) -> Bool {
        var depth = 0
        var sawVisibleOutside = false
        var sawVisible = false
        for c in s {
            if c == on { depth += 1 } else if c == off { depth = max(0, depth - 1) } else if !c.isWhitespace && !all.contains(c) {
                sawVisible = true
                if depth == 0 { sawVisibleOutside = true }
            }
        }
        return sawVisible && !sawVisibleOutside
    }
}
