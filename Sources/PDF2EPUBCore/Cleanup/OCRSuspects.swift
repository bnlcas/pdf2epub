import Foundation

/// Spots OCR output worth a second look: words that aren't words.
public struct OCRSuspects {
    let lexicon: Lexicon
    /// How often each word appears in the OCR'd text; real names recur, misreads mostly don't.
    let counts: [String: Int]

    public init(lexicon: Lexicon, lines: [Line]) {
        self.lexicon = lexicon
        var c: [String: Int] = [:]
        for l in lines {
            for w in l.plainText.split(whereSeparator: \.isWhitespace) {
                c[Self.core(String(w)).lowercased(), default: 0] += 1
            }
        }
        counts = c
    }

    static func core(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    public func hasSuspectWords(_ text: String) -> Bool { !suspects(in: text).isEmpty }

    /// Restores a space OCR dropped ("ofany" → "of any", "hislay" → "his lay") when exactly
    /// one split gives two dictionary words.
    public func splitRunTogetherWords(_ text: String) -> String {
        var out = text
        for token in text.split(whereSeparator: \.isWhitespace) {
            let w = Self.core(String(token))
            // Lowercase only: capitalized run-ons are usually names ("Netherfield").
            guard w.count >= 5, w.allSatisfy(\.isLetter), w.allSatisfy(\.isLowercase), !lexicon.isWord(w) else { continue }
            let chars = Array(w)
            var splits: [String] = []
            for k in 2...(chars.count - 2) {
                let a = String(chars[..<k]), b = String(chars[k...])
                if lexicon.isWord(a) && lexicon.isWord(b) { splits.append(a + " " + b) }
            }
            guard splits.count == 1, let r = out.range(of: w) else { continue }
            out.replaceSubrange(r, with: splits[0])
        }
        return out
    }

    /// Fragments of `text` that look misread, exactly as they appear in it.
    public func suspects(in text: String) -> [String] {
        var out: [String] = []
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, token) in tokens.enumerated() {
            let w = Self.core(token)
            let letters = w.filter(\.isLetter).count
            // Debris: "-._.", a dash read as hyphen next to a colon ("pray’d:-the").
            if token.range(of: #"[-._]{3,}|[:;,]-\p{L}"#, options: .regularExpression) != nil { out.append(token); continue }
            if letters == 0 { continue }
            // A lone letter is usually half a contraction: "return d" for "return’d".
            if letters == 1, w.count == 1, !"aAIO".contains(w), i > 0 {
                out.append(tokens[i - 1] + " " + token)
                continue
            }
            // A quote mark standing alone or dangling: "cross’ d".
            if token.hasSuffix("’") || token.hasSuffix("'"), i + 1 < tokens.count, tokens[i + 1].count <= 2 {
                out.append(token + " " + tokens[i + 1])
                continue
            }
            // “Tis / “twas: an opening double quote on an elision.
            if token.range(of: #"^[“"](Tis|twas|Twas|tis|em)\b"#, options: .regularExpression) != nil { out.append(token); continue }
            if w.contains(where: \.isNumber) { out.append(token); continue }
            if letters < 3 { continue }
            // Archaic elisions are intentional: "unnumber’d", "pray’d", "o’er".
            if let r = w.range(of: #"^(\p{L}+)[’'](d|st|n|er|t)$"#, options: .regularExpression), r.lowerBound == w.startIndex {
                let stem = String(w.prefix { $0 != "’" && $0 != "'" })
                if lexicon.isWord(stem + "ed") || lexicon.isWord(stem + "d") || lexicon.isWord(stem) || lexicon.isWord(stem + "e") { continue }
            }
            let parts = w.split(whereSeparator: { $0 == "-" || $0 == "’" || $0 == "'" }).map(String.init).filter { $0.count >= 2 }
            if parts.allSatisfy({ lexicon.isWord($0) }) { continue }
            if w.first?.isUppercase == true, (counts[w.lowercased()] ?? 0) >= 3 { continue } // a recurring name
            out.append(w)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
