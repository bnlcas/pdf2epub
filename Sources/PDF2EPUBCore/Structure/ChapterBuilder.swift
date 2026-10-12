import Foundation

public struct Chapter: Codable, Sendable {
    public var title: String
    /// Nesting depth in the table of contents (0 = top level).
    public var navLevel: Int
    public var blocks: [Block]
}

/// Splits the block stream into chapters, preferring the PDF outline.
public enum ChapterBuilder {
    public static func build(_ doc: Document) -> [Chapter] {
        let blocks = doc.blocks.filter { !$0.kind.isFurniture }
        guard !blocks.isEmpty else { return [] }
        var splits = outlineSplits(doc.outline, blocks: blocks, pageCount: doc.pages.count)
        let fromOutline = splits.count >= 2
        if !fromOutline {
            splits = headingSplits(blocks)
        }
        var chapters: [Chapter] = []
        let sorted = splits.sorted { $0.index < $1.index }
        if let first = sorted.first, first.index > 0 {
            let front = Array(blocks[0..<first.index])
            if front.contains(where: { !$0.plainText.trimmingCharacters(in: .whitespaces).isEmpty || $0.kind == .figure }) {
                chapters.append(Chapter(title: frontTitle(front, doc: doc), navLevel: 0, blocks: front))
            }
        }
        for (n, s) in sorted.enumerated() {
            let end = n + 1 < sorted.count ? sorted[n + 1].index : blocks.count
            guard end > s.index else { continue }
            var chapterBlocks = Array(blocks[s.index..<end])
            // Chapter titles set as display art aren't in any text layer; the printed contents
            // supplies the words, so give the chapter a real heading.
            if s.synthesizeHeading, let first = chapterBlocks.first,
               !chapterBlocks.prefix(4).contains(where: { $0.kind.isHeading && matches($0.plainText, s.title) }) {
                chapterBlocks.insert(Block(page: first.page, bbox: .zero, kind: .heading(1), text: s.title, source: first.source), at: 0)
            }
            normalizeHeadings(&chapterBlocks, title: s.title)
            chapters.append(Chapter(title: s.title, navLevel: s.level, blocks: chapterBlocks))
        }
        if chapters.isEmpty {
            var all = blocks
            normalizeHeadings(&all, title: nil)
            chapters.append(Chapter(title: doc.metadata.title ?? "Text", navLevel: 0, blocks: all))
        }
        // Detected headings over-split title pages and author lines: fold chapters with
        // almost no text into the next one. (Outline chapters are the author's choice; keep them.)
        if !fromOutline {
            var i = 0
            while i + 1 < chapters.count {
                let text = chapters[i].blocks.filter { !$0.kind.isHeading }.reduce(0) { $0 + $1.plainText.count }
                let hasFigure = chapters[i].blocks.contains { $0.kind == .figure }
                // A title page stays separate from "Chapter I".
                let nextIsChapter = BlockClassifier.isChapterHeading(chapters[i + 1].title)
                if text < 400 && !hasFigure && !nextIsChapter {
                    let title = chapters[i].title
                    chapters[i + 1].blocks = chapters[i].blocks + chapters[i + 1].blocks
                    if i == 0 { chapters[i + 1].title = title }
                    chapters.remove(at: i)
                    normalizeHeadings(&chapters[i].blocks, title: chapters[i].title)
                } else {
                    i += 1
                }
            }
        }
        // Nav levels must not jump by more than one step.
        var prev = -1
        for i in chapters.indices {
            chapters[i].navLevel = min(chapters[i].navLevel, prev + 1)
            prev = chapters[i].navLevel
        }
        return chapters
    }

    struct Split { var index: Int; var title: String; var level: Int; var synthesizeHeading = false }

    // MARK: - Outline

    static func outlineSplits(_ outline: [OutlineEntry], blocks: [Block], pageCount: Int) -> [Split] {
        let entries = outline.filter { $0.page >= 0 && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard entries.count >= 2 else { return [] }
        let maxLevel = entries.map(\.level).max() ?? 0
        var chosen = 0
        for level in 0...maxLevel {
            chosen = level
            let count = entries.filter { $0.level <= level }.count
            if count >= 3 && Double(pageCount) / Double(count) <= 40 { break }
            if level >= 2 { break }
        }
        var splits: [Split] = []
        var used = Set<Int>()
        for e in entries where e.level <= chosen {
            guard let idx = blockIndex(for: e, in: blocks), !used.contains(idx) else { continue }
            used.insert(idx)
            splits.append(Split(index: idx, title: cleanTitle(e.title), level: e.level, synthesizeHeading: e.fromPrintedContents))
        }
        return splits
    }

    static func blockIndex(for e: OutlineEntry, in blocks: [Block]) -> Int? {
        // Footnotes sit after the text that cites them, possibly from the previous chapter.
        func body(_ b: Block) -> Bool { b.kind != .footnote }
        if let y = e.y {
            if let i = blocks.firstIndex(where: { body($0) && $0.page == e.page && Double($0.bbox.maxY) >= y - 0.01 }) { return i }
        }
        if let i = blocks.firstIndex(where: { body($0) && $0.page == e.page }) { return i }
        return blocks.firstIndex(where: { body($0) && $0.page > e.page })
    }

    // MARK: - Headings

    static func headingSplits(_ blocks: [Block]) -> [Split] {
        var level = 1
        let h1 = blocks.filter { $0.kind.headingLevel == 1 }.count
        let h2 = blocks.filter { $0.kind.headingLevel == 2 }.count
        if h1 < 2 && h2 >= 2 { level = 2 }
        // If top-level headings leave one chapter holding most of the book (stray h1s from a
        // title page or back-matter ads), split at the next level too.
        if level == 1 && h2 >= 3 {
            let total = blocks.reduce(0) { $0 + $1.plainText.count }
            var largest = 0, current = 0
            for b in blocks {
                if b.kind.headingLevel == 1 { largest = max(largest, current); current = 0 }
                current += b.plainText.count
            }
            largest = max(largest, current)
            if Double(largest) > 0.4 * Double(total) { level = 2 }
        }
        var splits: [Split] = []
        for (i, b) in blocks.enumerated() where b.kind.headingLevel.map({ $0 <= level }) == true {
            splits.append(Split(index: i, title: cleanTitle(b.plainText), level: 0))
        }
        return splits
    }

    // MARK: - Helpers

    /// The chapter's opening heading becomes h1; any other h1 inside is demoted so each
    /// file opens with exactly one top-level heading.
    static func normalizeHeadings(_ blocks: inout [Block], title: String?) {
        let opening = blocks.prefix(3).firstIndex { $0.kind.isHeading }
        for i in blocks.indices where blocks[i].kind.headingLevel == 1 && i != opening {
            blocks[i].kind = .heading(2)
        }
        if let opening {
            if opening <= 1 || title.map({ matches(blocks[opening].plainText, $0) }) == true {
                blocks[opening].kind = .heading(1)
            }
        } else if let title, let i = blocks.prefix(3).firstIndex(where: { matches($0.plainText, title) }),
                  blocks[i].kind == .paragraph, blocks[i].plainText.count <= 150 {
            // The outline title printed as plain text.
            blocks[i].kind = .heading(1)
        }
        // Close gaps in the hierarchy: sub-headings use h2, h3, … in order of their original level.
        let subLevels = Set(blocks.compactMap { $0.kind.headingLevel }.filter { $0 > 1 }).sorted()
        let remap = Dictionary(uniqueKeysWithValues: subLevels.enumerated().map { ($0.element, min(4, $0.offset + 2)) })
        for i in blocks.indices {
            if let level = blocks[i].kind.headingLevel, let to = remap[level] { blocks[i].kind = .heading(to) }
        }
    }

    static func matches(_ text: String, _ title: String) -> Bool {
        let a = MarginFilter.key(text), b = MarginFilter.key(title)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a) || TextMetrics.normalizedDistance(a, b) < 0.2
    }

    public static func cleanTitle(_ raw: String) -> String {
        var t = InlineStyle.strip(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
        if t.count > 120 { t = String(t.prefix(117)) + "…" }
        return t.isEmpty ? "Untitled" : t
    }

    static func frontTitle(_ blocks: [Block], doc: Document) -> String {
        if let h = blocks.first(where: { $0.kind.isHeading }) { return cleanTitle(h.plainText) }
        return doc.metadata.title.map { _ in "Title Page" } ?? "Front Matter"
    }
}
