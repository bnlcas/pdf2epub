import Foundation
import AppKit
import NaturalLanguage

/// Dictionary lookups backed by the system spell checker, with a cache.
///
/// Used to score text layers (is this real text or scanner junk?) and to decide
/// hyphen joins ("mathemati-" + "cal" → "mathematical").
public final class Lexicon: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private var language: String?

    /// Without a language the spell checker guesses per word and accepts nonsense like
    /// "tumed", so default to English until `detectLanguage` says otherwise.
    public init(language: String? = "en") {
        self.language = language
    }

    /// Picks the spell-checker language from a sample of the book's text.
    public func detectLanguage(from sample: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(20_000)))
        guard let lang = recognizer.dominantLanguage?.rawValue else { return }
        lock.lock(); defer { lock.unlock() }
        let available = NSSpellChecker.shared.availableLanguages
        if let match = available.first(where: { $0 == lang || $0.hasPrefix(lang + "_") || $0.hasPrefix(lang + "-") }) {
            language = match
            cache.removeAll()
        }
    }

    public var languageCode: String? {
        lock.lock(); defer { lock.unlock() }
        return language.map { String($0.prefix(2)) }
    }

    public func isWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        guard !w.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[w] { return hit }
        let checker = NSSpellChecker.shared
        var ok = checker.checkSpelling(of: w, startingAt: 0, language: language, wrap: false,
                                       inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        // English books come in British and American spelling ("honour", "neighbouring").
        if !ok, language?.hasPrefix("en") ?? true {
            for variant in ["en_GB", "en_US", "en"] where variant != language && checker.availableLanguages.contains(variant) {
                if checker.checkSpelling(of: w, startingAt: 0, language: variant, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound {
                    ok = true
                    break
                }
            }
        }
        // The checker accepts capitalized forms of lowercase words but not always the reverse.
        if !ok, w.first?.isUppercase == true {
            let lower = w.lowercased()
            ok = checker.checkSpelling(of: lower, startingAt: 0, language: language, wrap: false,
                                       inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        cache[w] = ok
        return ok
    }

    /// The spell checker's suggested corrections for a misspelled word.
    public func guesses(_ word: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let hit = guessCache[word] { return hit }
        let g = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                              in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        guessCache[word] = g
        return g
    }
    private var guessCache: [String: [String]] = [:]

    /// Fraction of word-like tokens that are dictionary words. Tokens mixing letters with
    /// digits or junk symbols count as failures; pure numbers and punctuation are ignored.
    public func quality(of text: String) -> (score: Double, tokens: Int) {
        var good = 0, total = 0
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            guard token.count >= 2 else { continue }
            let letters = token.filter(\.isLetter).count
            if letters == 0 { continue }
            total += 1
            let wordlike = token.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            guard wordlike else { continue }
            let parts = token.split(whereSeparator: { $0 == "-" }).map(String.init)
            if parts.allSatisfy({ $0.count < 2 || isWord($0) }) { good += 1 }
        }
        return (total == 0 ? 0 : Double(good) / Double(total), total)
    }
}
