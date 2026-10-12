import Foundation

/// Links note references in the text ("care.¹⁴⁷") to a book's endnotes ("Notes" chapter,
/// numbered per chapter under headers like "CHAPTER I (Pages 7–39)"), with links both ways.
public enum EndnoteLinker {
    public static func link(_ chapters: inout [Chapter], folios: FolioMap) -> Int {
        guard let notesIndex = chapters.firstIndex(where: { isNotesTitle($0.title) }) else { return 0 }
        let sections = parseSections(&chapters[notesIndex].blocks)
        guard !sections.isEmpty else { return 0 }

        // Which body chapter each section belongs to: by its printed page range, else in order.
        let bodyChapters = chapters.indices.filter { $0 < notesIndex && chapters[$0].blocks.contains(where: hasNoteRefs) }
        var target: [Int: Int] = [:]   // section → chapter index
        // Chapters by the page they start on; a section's first printed page falls in one.
        let starts = chapters.indices.map { c in chapters[c].blocks.map(\.page).min() ?? Int.max }
        for (k, section) in sections.enumerated() {
            if let first = section.firstPage, let idx = folios.index(ofPrinted: first),
               let ch = (0..<notesIndex).last(where: { starts[$0] <= idx }) {
                target[k] = ch
            }
        }
        if target.count < sections.count / 2 {
            target = [:]
            for (k, ch) in zip(sections.indices, bodyChapters) { target[k] = ch }
        }

        if ProcessInfo.processInfo.environment["PDF2EPUB_DEBUG_NOTES"] != nil {
            for (k, sec) in sections.enumerated() {
                let ch = target[k].map { chapters[$0].title } ?? "-"
                FileHandle.standardError.write(Data("section \(k + 1): pages from \(sec.firstPage ?? -1) → \(ch); \(sec.notes.count) notes, max \(sec.notes.keys.max() ?? 0)\n".utf8))
            }
        }
        var linked = 0
        var usedIDs = Set<String>()
        for (k, section) in sections.enumerated() {
            guard let ch = target[k] else { continue }
            for b in chapters[ch].blocks.indices where chapters[ch].blocks[b].kind != .footnote {
                var refs = chapters[ch].blocks[b].endnoteRefs ?? [:]
                for marker in FootnoteLinker.supMarkers(chapters[ch].blocks[b].text) {
                    let digits = marker.filter(\.isNumber)
                    guard let n = Int(digits), let noteBlock = section.notes[n], refs[marker] == nil else { continue }
                    let id = "\(k + 1)-\(n)"
                    guard usedIDs.insert(id).inserted else { continue }
                    refs[marker] = id
                    chapters[notesIndex].blocks[noteBlock].endnoteAnchor = id
                    chapters[notesIndex].blocks[noteBlock].footnoteMarker = String(n)
                    linked += 1
                }
                if !refs.isEmpty { chapters[ch].blocks[b].endnoteRefs = refs }
            }
        }
        return linked
    }

    static func hasNoteRefs(_ b: Block) -> Bool {
        b.text.contains(InlineStyle.supOn)
    }

    static func isNotesTitle(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        return ["notes", "endnotes", "notes and references", "references and notes", "notes to the text"].contains(t)
    }

    struct Section {
        var firstPage: Int?
        /// Note number → block index in the notes chapter.
        var notes: [Int: Int] = [:]
    }

    static let headerPattern = #"^(introduction|preface|foreword|prologue|epilogue|conclusion|appendix|chapter\s+[ivxlc\d]+|part\s+[ivxlc\d]+)\b"#

    /// Splits the notes chapter into per-chapter sections and numbers the notes, repairing
    /// OCR damage to note numbers from the sequence.
    static func parseSections(_ blocks: inout [Block]) -> [Section] {
        var sections: [Section] = []
        var expected = 1
        var pending: [(block: Int, number: Int?)] = []

        func flushPending() {
            guard !sections.isEmpty else { pending = []; return }
            // Assign numbers: trust a parsed number that fits the count; otherwise, if the
            // next note confirms the count, it was misread ("8" for "3", "«" for "6").
            for (k, entry) in pending.enumerated() {
                let next = k + 1 < pending.count ? pending[k + 1].number : nil
                let n: Int
                if entry.number == expected {
                    n = expected
                } else if next == expected + 1 || entry.number == nil || next == nil {
                    n = expected
                } else if let parsed = entry.number, parsed > expected, parsed < expected + 5 {
                    n = parsed   // a note genuinely missing from the layer
                } else {
                    n = expected
                }
                sections[sections.count - 1].notes[n] = entry.block
                expected = n + 1
            }
            pending = []
        }

        for i in blocks.indices {
            let plain = blocks[i].plainText.trimmingCharacters(in: .whitespaces)
            let compact = plain.replacingOccurrences(of: " ", with: "")
            // "CHAPTER I (Continued)" repeats at the top of each notes page: furniture.
            if compact.lowercased().contains("(continued)"), plain.count < 60 {
                blocks[i].kind = .runningHeader
                continue
            }
            // A section header names a chapter ("CHAPTER IV (Pages 79–91)", "Introduction")
            // and has no note number of its own.
            if plain.count < 60, leadingNumber(blocks[i].text) == nil,
               plain.range(of: headerPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                flushPending()
                var section = Section()
                if let r = compact.range(of: #"(?i)\(pages?(\d+)"#, options: .regularExpression) {
                    section.firstPage = Int(compact[r].filter(\.isNumber))
                }
                sections.append(section)
                expected = 1
                blocks[i].kind = .heading(2)
                continue
            }
            // In a notes chapter, small type at a page foot is just more notes.
            guard !sections.isEmpty, [.paragraph, .unknown, .footnote].contains(blocks[i].kind) || blocks[i].kind.isHeading else { continue }
            if blocks[i].kind != .paragraph {
                blocks[i].kind = .paragraph
                blocks[i].noteID = nil
            }
            pending.append((i, leadingNumber(blocks[i].text)))
        }
        flushPending()
        return sections.filter { !$0.notes.isEmpty }
    }

    /// The note number at the start of a note: a superscript, or "12." / "12 ".
    static func leadingNumber(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.first == InlineStyle.supOn, let end = t.firstIndex(of: InlineStyle.supOff) {
            return Int(t[t.index(after: t.startIndex)..<end].filter(\.isNumber))
        }
        let plain = InlineStyle.strip(t)
        let digits = plain.prefix { $0.isNumber || $0 == " " }.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        return Int(digits)
    }
}
