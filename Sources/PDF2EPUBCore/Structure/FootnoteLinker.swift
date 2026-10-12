import Foundation

/// Pairs footnotes with the superscript markers that cite them, numbers them book-wide,
/// and moves each note right after the block that cites it so it lands in the same file.
public enum FootnoteLinker {
    public static func link(_ blocks: inout [Block]) {
        let noteIndices = blocks.indices.filter { blocks[$0].kind == .footnote }
        guard !noteIndices.isEmpty else { return }
        let bodyIndices = blocks.indices.filter { blocks[$0].kind != .footnote }

        // OCR text has no superscripts ("papyrus,1 forming"): mark digits that match a note on the page.
        for n in noteIndices {
            guard let marker = blocks[n].footnoteMarker, blocks[n].source == .ocr, marker.allSatisfy(\.isNumber) else { continue }
            let page = blocks[n].page
            let pattern = "(?<=[\\p{L}.,;:!?”’\"')])\(marker)(?=[\\s.,;:)]|$)"
            for b in bodyIndices where blocks[b].pageRange.contains(page) && blocks[b].kind.isFlowing {
                if let r = blocks[b].text.range(of: pattern, options: .regularExpression) {
                    blocks[b].text.replaceSubrange(r, with: "\(InlineStyle.supOn)\(marker)\(InlineStyle.supOff)")
                    break
                }
            }
        }

        var anchor: [Int: Int] = [:]   // note index → body block index
        var counter = 0
        for b in bodyIndices {
            for marker in supMarkers(blocks[b].text) {
                let pages = blocks[b].pageRange
                let free = noteIndices.filter { anchor[$0] == nil && blocks[$0].footnoteMarker == marker }
                guard let n = free.first(where: { pages.contains(blocks[$0].page) }) else { continue }
                counter += 1
                anchor[n] = b
                blocks[n].noteID = counter
                blocks[b].noteRefs = (blocks[b].noteRefs ?? [:]).merging([marker: counter]) { a, _ in a }
            }
        }
        // Unreferenced notes follow the last body block from their page.
        for n in noteIndices where anchor[n] == nil {
            anchor[n] = bodyIndices.last { blocks[$0].page <= blocks[n].page }
        }

        var after: [Int: [Int]] = [:]
        for n in noteIndices { if let a = anchor[n] { after[a, default: []].append(n) } }
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        for i in blocks.indices {
            if blocks[i].kind == .footnote {
                if anchor[i] == nil { out.append(blocks[i]) }
                continue
            }
            out.append(blocks[i])
            for n in after[i] ?? [] { out.append(blocks[n]) }
        }
        blocks = out
    }

    static func supMarkers(_ text: String) -> [String] {
        var out: [String] = []
        var inSup = false
        var cur = ""
        for c in text {
            if c == InlineStyle.supOn {
                inSup = true
                cur = ""
            } else if c == InlineStyle.supOff {
                if inSup { out.append(InlineStyle.strip(cur).trimmingCharacters(in: .whitespaces)) }
                inSup = false
            } else if inSup {
                cur.append(c)
            }
        }
        return out
    }
}
