import Foundation
import FoundationModels

/// Second opinions from the on-device model on the calls heuristics can't make confidently.
///
/// Findings that shaped this (macOS 26, ~3B on-device model):
/// - Guided generation (`@Generable`) still enforces the default guardrails, which refuse
///   plenty of the classical canon (Homer's battle scenes, Ovid). Only plain String output
///   honours `.permissiveContentTransformations`, so every answer is a short string we parse.
/// - The model does not reliably follow a multi-block reply format, and echoing whole pages is
///   slow. So each request is one narrow question with a one-word or one-fragment answer:
///     1. OCR fixes: "is this word misread? reply with the corrected word"
///     2. joins across a page break: YES / NO
///     3. ambiguous short lines: HEADING / TEXT / JUNK
/// - Answers are validated (edit distance, allowed vocab) and anything odd is ignored. Any
///   failure keeps the heuristic result. One bad page never fails a book.
public final class LLMCleaner: BlockCleaner {
    let model: SystemLanguageModel
    var transcript: [String] = []
    public var transcriptURL: URL?
    var fixCache: [String: String?] = [:]
    var refusals = Set<Int>()
    public var suspects: OCRSuspects?

    init(model: SystemLanguageModel, suspects: OCRSuspects?) {
        self.model = model
        self.suspects = suspects
    }

    public static func makeIfAvailable(log: Log, suspects: OCRSuspects? = nil) -> LLMCleaner? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return LLMCleaner(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), suspects: suspects)
        case .unavailable(let reason):
            let why: String
            switch reason {
            case .appleIntelligenceNotEnabled: why = "Apple Intelligence is turned off"
            case .deviceNotEligible: why = "this Mac doesn't support Apple Intelligence"
            case .modelNotReady: why = "the Apple Intelligence model is still downloading"
            @unknown default: why = "the on-device model is unavailable"
            }
            log.info("note: \(why); converting without the cleanup pass.")
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Driving

    enum Task {
        case fix(block: Int, fragment: String)
        case join(block: Int, previous: Int)
        case kind(block: Int)

        var block: Int {
            switch self {
            case .fix(let b, _), .join(let b, _), .kind(let b): return b
            }
        }
    }

    public func clean(_ blocks: inout [Block], log: Log) async {
        let tasks = makeTasks(blocks)
        guard !tasks.isEmpty else { return }
        var changed = 0
        for (n, task) in tasks.enumerated() {
            if await run(task, blocks: &blocks, log: log) { changed += 1 }
            log.progress("cleanup", n + 1, tasks.count)
        }
        log.debug("cleanup: \(tasks.count) question(s), \(changed) change(s)")
        if !refusals.isEmpty {
            let pages = refusals.sorted().prefix(12).map { String($0 + 1) }.joined(separator: ", ")
            log.warn("the model declined to review \(refusals.count) page(s) (\(pages)); kept the unreviewed text there")
        }
        if let url = transcriptURL {
            try? transcript.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func makeTasks(_ blocks: [Block]) -> [Task] {
        var tasks: [Task] = []
        for (i, b) in blocks.enumerated() where !b.kind.isFurniture && b.kind != .figure {
            if b.flags.contains(.ambiguousKind) { tasks.append(.kind(block: i)) }
            if b.flags.contains(.ambiguousJoin), let p = FlowJoiner.previousFlowing(blocks, before: i, allowVerse: true) {
                tasks.append(.join(block: i, previous: p))
            }
            if b.source == .ocr, b.flags.contains(.lowConfidence), let suspects {
                for fragment in suspects.suspects(in: b.plainText).prefix(8) {
                    tasks.append(.fix(block: i, fragment: fragment))
                }
            }
        }
        return tasks
    }

    func ask(_ instructions: String, _ prompt: String, page: Int, log: Log) async -> String? {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let r = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 60))
            transcript.append("### page \(page + 1)\n\(prompt)\n→ \(r.content)")
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                refusals.insert(page)
            default:
                log.debug("page \(page + 1): model error \(error.localizedDescription)")
            }
            transcript.append("### page \(page + 1)\n\(prompt)\n→ ERROR \(error)")
        } catch {
            log.debug("page \(page + 1): model error \(error.localizedDescription)")
        }
        return nil
    }

    func run(_ task: Task, blocks: inout [Block], log: Log) async -> Bool {
        let b = blocks[task.block]
        switch task {
        case .fix(let i, let fragment):
            let fixed: String?
            if let cached = fixCache[fragment] {
                fixed = cached
            } else {
                let sentence = Self.sentence(around: fragment, in: b.plainText)
                let answer = await ask(Self.fixInstructions, "Sentence: \(sentence)\nFragment: \(fragment)", page: b.page, log: log)
                fixed = answer.flatMap { validFix(original: fragment, answer: $0) }
                fixCache[fragment] = fixed
            }
            guard let fixed, fixed != fragment else { return false }
            let plain = blocks[i].plainText
            guard let r = plain.range(of: fragment) else { return false }
            let newPlain = plain.replacingCharacters(in: r, with: fixed)
            guard let patched = TextPatch.apply(to: blocks[i].text, newPlain: newPlain) else { return false }
            blocks[i].text = patched
            return true

        case .join(let i, let p):
            let a = String(blocks[p].plainText.suffix(220))
            let c = String(b.plainText.prefix(220))
            guard let answer = await ask(Self.joinInstructions, "A: …\(a)\nB: \(c)…", page: b.page, log: log) else { return false }
            let yes = answer.uppercased().hasPrefix("YES")
            let no = answer.uppercased().hasPrefix("NO")
            guard yes || no, blocks[i].continuesFromPrevious != yes else { return false }
            blocks[i].continuesFromPrevious = yes
            return true

        case .kind(let i):
            let before = i > 0 ? String(blocks[i - 1].plainText.suffix(150)) : ""
            let after = i + 1 < blocks.count ? String(blocks[i + 1].plainText.prefix(150)) : ""
            let prompt = "Before: …\(before)\nLine: \(b.plainText)\nAfter: \(after)…"
            guard let answer = await ask(Self.kindInstructions, prompt, page: b.page, log: log)?.uppercased() else { return false }
            if answer.hasPrefix("HEADING"), !b.kind.isHeading, b.plainText.count <= 120 {
                blocks[i].kind = .heading(2)
                return true
            }
            // Junk only near the page edges or in noisy text: a title page's author line is not junk.
            let nearEdge = b.bbox.minY < 0.12 || b.bbox.maxY > 0.88
            let noisy = suspects?.hasSuspectWords(b.plainText) ?? false
            if answer.hasPrefix("JUNK"), b.plainText.count <= 60, nearEdge || noisy {
                blocks[i].kind = .runningHeader
                return true
            }
            if answer.hasPrefix("TEXT"), b.kind.isHeading {
                blocks[i].kind = .paragraph
                return true
            }
            return false
        }
    }

    // MARK: - Prompts

    static let fixInstructions = """
        You correct OCR misreadings in scanned old books. You get a sentence and a fragment of it \
        that the OCR may have misread. Reply with the corrected fragment and nothing else. Fix only \
        clear misreadings: wrong letters (rn/m, cl/d, l/1/I, 0/O, h/b), a lost apostrophe, a dash \
        read as a hyphen, a double quote that should be an apostrophe. If the fragment is a real \
        word, a name, or an old spelling, reply with it unchanged. Never modernize spelling.

        Sentence: He tumed slowly to the window.
        Fragment: tumed
        turned

        Sentence: The plague destroying whom the sword would spare, “Tis time to save the few remains.
        Fragment: “Tis
        ’Tis

        Sentence: The trembling priest along the shore return d,
        Fragment: return d,
        return’d,

        Sentence: So spake the son of Atreus to the host.
        Fragment: Atreus
        Atreus
        """

    static let joinInstructions = """
        A paragraph in a book may be split by a page break. You get the end of the text before the \
        break (A) and the start of the text after it (B). Reply YES if B continues the same paragraph \
        as A, or NO if B starts a new paragraph. Reply with one word.
        """

    static let kindInstructions = """
        You classify one short line from a book page, given the text around it. Reply HEADING if it \
        is the title of a chapter, part or section; TEXT if it belongs to the book's prose or verse; \
        JUNK if it is a running header, a page number or scanning noise. Reply with one word.
        """

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

        // Never drop an elision mark or a ligature/diaeresis the book printed.
        for mark in ["’", "'", "æ", "Æ", "œ", "Œ", "ë", "ï", "é"] {
            if original.components(separatedBy: mark).count > answer.components(separatedBy: mark).count { return nil }
        }
        let letters = { (s: String) in s.filter(\.isLetter) }
        if letters(original) == letters(answer) { return answer }   // punctuation-only repair
        // The change must be something OCR does (rn→m, c→e, a dropped i), not a respelling:
        // "ancle" → "ankle" is Austen's spelling modernized, not a misread.
        guard Self.isOCRConfusion(original, answer) else { return nil }

        guard let lexicon = suspects?.lexicon else { return nil }
        let words = { (s: String) in s.split(whereSeparator: { !$0.isLetter && $0 != "’" && $0 != "'" }).map(String.init) }
        let originalIsWords = words(original).allSatisfy { lexicon.isWord($0) }
        let answerIsWords = words(answer).allSatisfy { lexicon.isWord($0) }
        return !originalIsWords && answerIsWords ? answer : nil
    }

    /// True if `a` and `b` differ only by typical OCR confusions.
    static func isOCRConfusion(_ a: String, _ b: String) -> Bool {
        func canonical(_ s: String) -> String {
            var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            for (from, to) in [("rn", "m"), ("cl", "d"), ("vv", "w"), ("li", "h"), ("ri", "n"), ("ii", "u")] {
                t = t.replacingOccurrences(of: from, with: to)
            }
            var out = ""
            for c in t {
                switch c {
                case "c", "e", "o", "a", "0": out.append("o")
                case "h", "b": out.append("b")
                case "n", "u": out.append("n")
                case "f", "t": out.append("t")
                case "s", "5": out.append("s")
                case "g", "q", "9": out.append("g")
                case "v", "y": out.append("v")
                case "i", "l", "1", "|", "!", "j", "'", "’", "‘", "\"", "“", "”", ".", ",", "-", "—", " ":
                    continue // thin glyphs and punctuation come and go
                default: out.append(c)
                }
            }
            return out
        }
        return canonical(a) == canonical(b)
    }

    /// The sentence containing `fragment`, trimmed to a reasonable length.
    static func sentence(around fragment: String, in text: String) -> String {
        guard let r = text.range(of: fragment) else { return String(text.prefix(200)) }
        let before = text[..<r.lowerBound]
        let after = text[r.upperBound...]
        let start = before.lastIndex(where: { ".!?;".contains($0) }).map { text.index(after: $0) } ?? text.startIndex
        let end = after.firstIndex(where: { ".!?;".contains($0) }).map { text.index(after: $0) } ?? text.endIndex
        var s = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if s.count > 260 {
            let lo = text.index(r.lowerBound, offsetBy: -min(120, text.distance(from: text.startIndex, to: r.lowerBound)))
            let hi = text.index(r.upperBound, offsetBy: min(120, text.distance(from: r.upperBound, to: text.endIndex)))
            s = String(text[lo..<hi])
        }
        return s
    }
}
