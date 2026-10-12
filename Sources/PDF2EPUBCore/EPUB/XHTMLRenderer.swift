import Foundation

/// One spine document produced from (part of) a chapter.
public struct RenderedFile: Sendable {
    public var name: String
    public var title: String
    public var body: String
}

/// Renders chapters to the restricted XHTML subset in the profile rules: block elements
/// p/h1–h4/div/blockquote/ul/li/figure, inline i/b/sup/a/br. Nothing else.
public enum XHTMLRenderer {
    public static func render(_ chapter: Chapter, number: Int, profile: Profile, language: String) -> [RenderedFile] {
        let blocks = chapter.blocks
        let base = String(format: "ch%03d", number)

        var files: [RenderedFile] = []
        var current = ""
        var currentNotes: [String] = []
        var afterBreak = true
        let cap = profile.maxChapterBytes ?? Int.max

        func flush() {
            guard !current.isEmpty || !currentNotes.isEmpty else { return }
            var body = current
            if !currentNotes.isEmpty {
                body += "<div class=\"notes\">\n<hr/>\n" + currentNotes.joined(separator: "\n") + "\n</div>\n"
            }
            let suffix = files.isEmpty ? "" : String(UnicodeScalar(UInt8(97 + min(files.count, 25))))
            files.append(RenderedFile(name: "\(base)\(suffix).xhtml", title: chapter.title, body: body))
            current = ""
            currentNotes = []
            afterBreak = true
        }

        var i = 0
        while i < blocks.count {
            let b = blocks[i]
            var html = ""
            var consumed = 1
            switch b.kind {
            case .footnote:
                currentNotes.append(noteHTML(b))
                i += 1
                continue
            case .runningHeader, .runningFooter, .pageNumber:
                i += 1
                continue
            case .heading(let level):
                let lv = min(max(level, 1), 4)
                var text = b.text
                // Headings are bold already.
                if InlineStyle.isEntirely(text, on: InlineStyle.boldOn, off: InlineStyle.boldOff) {
                    text.removeAll { $0 == InlineStyle.boldOn || $0 == InlineStyle.boldOff }
                }
                html = "<h\(lv)>\(inline(text, refs: b.noteRefs ?? [:]))</h\(lv)>\n"
                afterBreak = true
            case .paragraph, .unknown:
                let cls = afterBreak ? " class=\"first\""
                    : b.flags.contains(.tocEntry) ? " class=\"noindent\""
                    : (b.isCentered && b.plainText.count < 100 ? " class=\"center\"" : "")
                html = "<p\(cls)>\(inline(b.text, refs: b.noteRefs ?? [:]))</p>\n"
                afterBreak = false
            case .blockquote:
                html = "<blockquote><p>\(inline(b.text, refs: b.noteRefs ?? [:]))</p></blockquote>\n"
                afterBreak = false
            case .verse:
                html = "<div class=\"stanza\">\(inline(b.text, refs: b.noteRefs ?? [:]))</div>\n"
                afterBreak = true
            case .listItem:
                var items: [String] = []
                var j = i
                while j < blocks.count, blocks[j].kind == .listItem {
                    items.append("<li>\(inline(blocks[j].text, refs: blocks[j].noteRefs ?? [:]))</li>")
                    j += 1
                }
                html = "<ul>\n" + items.joined(separator: "\n") + "\n</ul>\n"
                consumed = j - i
                afterBreak = true
            case .figure:
                guard let ref = b.imageRef else { i += 1; continue }
                var caption: String? = nil
                if i + 1 < blocks.count, blocks[i + 1].kind == .caption {
                    caption = blocks[i + 1].text
                    consumed = 2
                }
                let alt = escape(InlineStyle.strip(caption ?? "Figure").replacingOccurrences(of: "\n", with: " "))
                html = "<figure><img src=\"../\(ref)\" alt=\"\(alt)\"/>"
                if let caption { html += "<figcaption>\(inline(caption, refs: blocks[i + 1].noteRefs ?? [:]))</figcaption>" }
                html += "</figure>\n"
                afterBreak = true
            case .caption:
                html = "<p class=\"caption\">\(inline(b.text, refs: b.noteRefs ?? [:]))</p>\n"
                afterBreak = true
            }
            // Keep a block together with the notes that follow it.
            var j = i + consumed
            var trailing = 0
            while j < blocks.count, blocks[j].kind == .footnote { trailing += noteHTML(blocks[j]).utf8.count; j += 1 }
            let added = html.utf8.count + trailing
            let pending = current.utf8.count + currentNotes.reduce(0) { $0 + $1.utf8.count }
            if pending + added > cap - 1024, !current.isEmpty, !b.kind.isHeading {
                flush()
                if case .paragraph = b.kind {
                    html = html.replacingOccurrences(of: "<p>", with: "<p class=\"first\">", options: .anchored)
                }
            }
            current += html
            i += consumed
        }
        flush()
        if files.isEmpty {
            files.append(RenderedFile(name: "\(base).xhtml", title: chapter.title, body: "<h1>\(escape(chapter.title))</h1>\n"))
        }
        return files
    }

    public static func document(title: String, body: String, language: String, cssPath: String = "../style.css") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head>
        <title>\(escape(title))</title>
        <link rel="stylesheet" type="text/css" href="\(cssPath)"/>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    // MARK: - Footnotes

    static func noteHTML(_ b: Block) -> String {
        let label = b.footnoteMarker.map { XHTMLRenderer.escape($0) + "." } ?? ""
        if let id = b.noteID {
            return "<p id=\"fn\(id)\"><a href=\"#fnref\(id)\">\(label)</a> \(inline(b.text, refs: [:]))</p>"
        }
        return "<p>\(label.isEmpty ? "" : label + " ")\(inline(b.text, refs: [:]))</p>"
    }

    // MARK: - Inline

    /// Escapes text and turns style markers into tags. Superscripts naming a linked
    /// footnote in `refs` (marker → note id) become links.
    static func inline(_ text: String, refs: [String: Int]) -> String {
        let t = InlineStyle.balance(text)
        var out = ""
        var supBuffer: String? = nil
        var usedRefs = Set<String>()
        for c in t {
            if supBuffer != nil {
                if c == InlineStyle.supOff {
                    let content = supBuffer!
                    let key = InlineStyle.strip(content).trimmingCharacters(in: .whitespaces)
                    if let id = refs[key], !usedRefs.contains(key) {
                        usedRefs.insert(key)
                        out += "<a href=\"#fn\(id)\" id=\"fnref\(id)\"><sup>\(escapeInline(content))</sup></a>"
                    } else {
                        out += "<sup>\(escapeInline(content))</sup>"
                    }
                    supBuffer = nil
                } else {
                    supBuffer!.append(c)
                }
                continue
            }
            switch c {
            case InlineStyle.supOn: supBuffer = ""
            case InlineStyle.italicOn: out += "<i>"
            case InlineStyle.italicOff: out += "</i>"
            case InlineStyle.boldOn: out += "<b>"
            case InlineStyle.boldOff: out += "</b>"
            case "\n": out += "<br/>"
            default: out += escapeChar(c)
            }
        }
        if let rest = supBuffer { out += "<sup>\(escapeInline(rest))</sup>" }
        return out
    }

    /// Escapes text that may contain italic/bold markers (inside a superscript).
    static func escapeInline(_ s: String) -> String {
        var out = ""
        var openI = false, openB = false
        for c in s {
            switch c {
            case InlineStyle.italicOn: out += "<i>"; openI = true
            case InlineStyle.italicOff: if openI { out += "</i>"; openI = false }
            case InlineStyle.boldOn: out += "<b>"; openB = true
            case InlineStyle.boldOff: if openB { out += "</b>"; openB = false }
            case InlineStyle.supOn, InlineStyle.supOff: break
            default: out += escapeChar(c)
            }
        }
        if openI { out += "</i>" }
        if openB { out += "</b>" }
        return out
    }

    static func escapeChar(_ c: Character) -> String {
        switch c {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case "\"": return "&quot;"
        default:
            // Drop characters XML 1.0 forbids.
            if let s = c.unicodeScalars.first, c.unicodeScalars.count == 1,
               s.value < 0x20 && s.value != 0x09 && s.value != 0x0A && s.value != 0x0D { return "" }
            if c.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) }) { return "" }
            return String(c)
        }
    }

    public static func escape(_ s: String) -> String {
        s.map(escapeChar).joined()
    }
}
