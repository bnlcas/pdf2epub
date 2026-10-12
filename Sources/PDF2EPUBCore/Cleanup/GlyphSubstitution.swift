import Foundation

/// Some OCR layers map one glyph of a font to the wrong character, consistently: this
/// book's italic "k" comes out as "\" ("sil\", "\inds"). Learn such substitutions from the
/// book itself (which letter turns the most odd words into dictionary words) and undo them.
public enum GlyphSubstitution {
    static let suspects: Set<Character> = ["\\", "^", "{", "}", "|", "~", "`", "§", "¬", "®", "©", "°", "«", "»"]

    public static func infer(_ lines: [Line], lexicon: Lexicon) -> [Character: Character] {
        // For each odd glyph: how many affected words become dictionary words with each letter.
        var covered: [Character: [Character: Int]] = [:]
        var solvable: [Character: Int] = [:]
        var tried = Set<String>()
        for line in lines {
            for token in InlineStyle.strip(line.text).split(whereSeparator: \.isWhitespace) {
                let word = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "\\^{}|~`§¬®©°«»")))
                guard word.count >= 3, tried.insert(word).inserted else { continue }
                let odd = word.filter { suspects.contains($0) }
                guard odd.count == 1, let g = odd.first, word.filter(\.isLetter).count == word.count - 1 else { continue }
                let fits = "abcdefghijklmnopqrstuvwxyz".filter { lexicon.isWord(word.replacingOccurrences(of: String(g), with: String($0))) }
                guard !fits.isEmpty else { continue }
                solvable[g, default: 0] += 1
                for letter in fits { covered[g, default: [:]][letter, default: 0] += 1 }
            }
        }
        if ProcessInfo.processInfo.environment["PDF2EPUB_DEBUG_GLYPHS"] != nil {
            FileHandle.standardError.write(Data("glyph coverage: \(covered) solvable: \(solvable)\n".utf8))
        }
        // The real letter fits nearly every affected word; alternatives come and go.
        var out: [Character: Character] = [:]
        for (g, tally) in covered {
            let n = solvable[g] ?? 0
            let ranked = tally.sorted { $0.value > $1.value }
            guard n >= 3, let best = ranked.first else { continue }
            let second = ranked.dropFirst().first?.value ?? 0
            // Few samples: nearly all must agree. Many (names and foreign words dilute the
            // count): a clear majority well ahead of the runner-up.
            let small = Double(best.value) >= 0.8 * Double(n) && Double(best.value - second) >= 0.25 * Double(n)
            let large = n >= 10 && Double(best.value) >= 0.5 * Double(n) && Double(best.value) >= 1.6 * Double(second)
            if small || large {
                out[g] = best.key
            }
        }
        return out
    }

    /// Replaces mapped glyphs that sit inside words (between or touching letters).
    public static func apply(_ map: [Character: Character], to text: String) -> String {
        guard !map.isEmpty, text.contains(where: { map[$0] != nil }) else { return text }
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            if let letter = map[c] {
                let prev = chars[..<i].last(where: { !InlineStyle.isMarker($0) })
                let next = chars[(i + 1)...].first(where: { !InlineStyle.isMarker($0) })
                if prev?.isLetter == true || next?.isLetter == true {
                    // Keep case: uppercase at a word start only if the next letter is uppercase too.
                    let upper = next?.isUppercase == true && (prev == nil || prev?.isLetter == false) && chars.count > i + 2
                        && chars[i + 2].isUppercase
                    out.append(upper ? Character(letter.uppercased()) : letter)
                    continue
                }
            }
            out.append(c)
        }
        return out
    }
}
