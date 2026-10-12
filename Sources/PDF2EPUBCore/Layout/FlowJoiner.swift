import Foundation

/// Decides which paragraphs continue across page and column breaks, then merges them.
public enum FlowJoiner {
    /// Sets `continuesFromPrevious` on blocks that pick up a paragraph from before a break,
    /// flagging the uncertain ones for review.
    public static func markContinuations(_ blocks: inout [Block]) {
        let paragraphs = blocks.filter { $0.kind == .paragraph && $0.lines.count >= 2 && !$0.flags.contains(.startsSegment) }
        let indented = paragraphs.filter { $0.firstLineIndented == true }.count
        let usesIndent = paragraphs.count >= 5 && Double(indented) / Double(paragraphs.count) >= 0.5

        // Stanzas broken by a page turn: rejoin unless the first part ended a sentence.
        for j in blocks.indices where blocks[j].kind == .verse {
            guard j > 0, blocks[j].flags.contains(.startsSegment), let k = previousFlowing(blocks, before: j, allowVerse: true),
                  blocks[k].kind == .verse, blocks[k].page < blocks[j].page else { continue }
            let lastLine = blocks[k].text.components(separatedBy: "\n").last ?? ""
            if !TextMetrics.endsSentence(lastLine) {
                blocks[j].continuesFromPrevious = true
            } else {
                blocks[j].flags.insert(.ambiguousJoin)
            }
        }
        for j in blocks.indices where blocks[j].kind.isFlowing {
            guard let k = previousFlowing(blocks, before: j), blocks[k].kind == blocks[j].kind else { continue }
            // Only across a break: a new column/page, possibly after a figure or caption.
            guard blocks[(k + 1)...j].contains(where: { $0.flags.contains(.startsSegment) }) else { continue }
            let a = blocks[k].text, b = blocks[j].text
            let prevEnds = TextMetrics.endsSentence(a)
            let nextLower = TextMetrics.startsLowercase(b)
            let plainA = InlineStyle.strip(a).trimmingCharacters(in: .whitespaces)
            let hyphenEnd = plainA.hasSuffix("-") || plainA.hasSuffix("\u{2010}")
            let dashEnd = plainA.hasSuffix("—")

            if (hyphenEnd || dashEnd || !prevEnds) && nextLower {
                blocks[j].continuesFromPrevious = true
            } else if usesIndent, blocks[j].firstLineIndented == false {
                // A missing indent is better evidence than anything the sentence says.
                blocks[j].continuesFromPrevious = true
            } else if usesIndent, blocks[j].firstLineIndented == true {
                continue
            } else if !prevEnds {
                blocks[j].continuesFromPrevious = true
                blocks[j].flags.insert(.ambiguousJoin)
            } else if !usesIndent {
                blocks[j].flags.insert(.ambiguousJoin)
            }
        }
    }

    /// The closest earlier block that body text could flow from, skipping notes and figures.
    /// Returns nil if a heading or verse intervenes.
    static func previousFlowing(_ blocks: [Block], before j: Int, allowVerse: Bool = false) -> Int? {
        var k = j - 1
        while k >= 0 {
            switch blocks[k].kind {
            case .footnote, .figure, .caption, .runningHeader, .runningFooter, .pageNumber:
                k -= 1
            case .paragraph, .blockquote, .listItem, .unknown:
                return k
            case .verse where allowVerse:
                return k
            default:
                return nil
            }
        }
        return nil
    }

    /// Merges every block marked `continuesFromPrevious` into the block it continues.
    public static func mergeContinuations(_ blocks: inout [Block], context: LayoutContext) {
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        for b in blocks {
            if b.continuesFromPrevious {
                let target: Int?
                if b.kind == .footnote {
                    target = out.lastIndex { $0.kind == .footnote }
                } else {
                    target = out.indices.last.flatMap { last in
                        var k = last
                        while k >= 0 {
                            switch out[k].kind {
                            case .footnote, .figure, .caption: k -= 1; continue
                            default: return out[k].kind == b.kind ? k : nil
                            }
                        }
                        return nil
                    }
                }
                if let t = target, b.kind == .verse {
                    out[t].text += "\n" + b.text
                    out[t].lines += b.lines
                    out[t].endPage = max(out[t].pageRange.upperBound, b.pageRange.upperBound)
                    continue
                }
                if let t = target {
                    let joined = TextJoiner.join(out[t].text, b.text, context: context)
                    out[t].text = joined.text
                    out[t].lines += b.lines
                    out[t].endPage = max(out[t].pageRange.upperBound, b.pageRange.upperBound)
                    if joined.ambiguous { out[t].flags.insert(.ambiguousHyphen) }
                    continue
                }
            }
            var copy = b
            copy.continuesFromPrevious = false
            out.append(copy)
        }
        blocks = out
    }
}
