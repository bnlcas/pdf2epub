#!/usr/bin/env swift
// Typesets the public-domain excerpts in Tests/PDF2EPUBCoreTests/Fixtures/sources into book-like PDFs, plus
// "scanned" variants, and writes the expected text for golden tests.
//
//   swift Scripts/make-fixtures.swift
//
// Source format: "# Title:" / "# Author:" header lines, "## Chapter" headings,
// "### subtitle" lines, blank-line-separated paragraphs with _italics_, and verse lines
// prefixed "| " (blank line between stanzas).

import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("Tests/PDF2EPUBCoreTests/Fixtures/sources")
let outDir = root.appendingPathComponent("Tests/PDF2EPUBCoreTests/Fixtures")

enum Item { case para(String), stanza([String]) }
struct Chapter { var title: String; var subtitle: String?; var items: [Item] = [] }
struct Source { var title = ""; var author = ""; var chapters: [Chapter] = [] }

func parse(_ text: String) -> Source {
    var src = Source()
    var stanza: [String] = []
    func flushStanza() {
        if !stanza.isEmpty { src.chapters[src.chapters.count - 1].items.append(.stanza(stanza)); stanza = [] }
    }
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("# Title:") { src.title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
        if line.hasPrefix("# Author:") { src.author = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces); continue }
        if line.hasPrefix("### ") { src.chapters[src.chapters.count - 1].subtitle = String(line.dropFirst(4)); continue }
        if line.hasPrefix("## ") { flushStanza(); src.chapters.append(Chapter(title: String(line.dropFirst(3)))); continue }
        if line.hasPrefix("| ") { stanza.append(String(line.dropFirst(2))); continue }
        if line.isEmpty { flushStanza(); continue }
        flushStanza()
        src.chapters[src.chapters.count - 1].items.append(.para(line))
    }
    flushStanza()
    return src
}

// MARK: - Typesetting

let pageSize = CGSize(width: 396, height: 612) // 5.5 × 8.5 in
let margins = (top: 62.0, bottom: 66.0, inner: 54.0, outer: 46.0)
let body = NSFont(name: "Palatino-Roman", size: 11)!
let italic = NSFont(name: "Palatino-Italic", size: 11)!

func styled(_ text: String, font: NSFont, italicFont: NSFont, para: NSParagraphStyle) -> NSAttributedString {
    let out = NSMutableAttributedString()
    var inItalic = false
    for (i, part) in text.components(separatedBy: "_").enumerated() {
        if i > 0 { inItalic.toggle() }
        out.append(NSAttributedString(string: part, attributes: [.font: inItalic ? italicFont : font, .paragraphStyle: para]))
    }
    return out
}

func chapterText(_ ch: Chapter) -> NSAttributedString {
    let s = NSMutableAttributedString()
    let heading = NSMutableParagraphStyle()
    heading.alignment = .center
    heading.paragraphSpacingBefore = 70
    heading.paragraphSpacing = ch.subtitle == nil ? 26 : 8
    s.append(NSAttributedString(string: ch.title.uppercased() + "\n", attributes: [.font: NSFont(name: "Palatino-Roman", size: 16)!, .paragraphStyle: heading]))
    if let sub = ch.subtitle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacing = 22
        s.append(NSAttributedString(string: sub + "\n", attributes: [.font: NSFont(name: "Palatino-Italic", size: 12)!, .paragraphStyle: p]))
    }
    var first = true
    for item in ch.items {
        switch item {
        case .para(let text):
            let p = NSMutableParagraphStyle()
            p.alignment = .justified
            p.firstLineHeadIndent = first ? 0 : 16
            p.lineSpacing = 1.5
            p.hyphenationFactor = 0.95
            s.append(styled(text + "\n", font: body, italicFont: italic, para: p))
            first = false
        case .stanza(let lines):
            // One paragraph per verse line, so a long line's turnover gets the deeper indent.
            for (k, line) in lines.enumerated() {
                let p = NSMutableParagraphStyle()
                p.alignment = .left
                p.firstLineHeadIndent = 24
                p.headIndent = 48
                p.paragraphSpacingBefore = k == 0 ? 7 : 0
                p.paragraphSpacing = k == lines.count - 1 ? 7 : 0
                p.lineSpacing = 1.5
                s.append(styled(line + "\n", font: body, italicFont: italic, para: p))
            }
            first = true
        }
    }
    return s
}

func drawCentered(_ text: String, font: NSFont, y: CGFloat) {
    let a = NSAttributedString(string: text, attributes: [.font: font])
    let w = a.size().width
    a.draw(at: CGPoint(x: (pageSize.width - w) / 2, y: y))
}

func makeBook(_ src: Source, to url: URL) {
    var box = CGRect(origin: .zero, size: pageSize)
    let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: src.title, kCGPDFContextAuthor: src.author] as CFDictionary)!
    var pageNumber = 0
    func page(_ draw: () -> Void) {
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw()
        NSGraphicsContext.current = nil
        ctx.restoreGState()
        ctx.endPDFPage()
        pageNumber += 1
    }
    // Title page.
    page {
        drawCentered(src.title.uppercased(), font: NSFont(name: "Palatino-Roman", size: 22)!, y: 200)
        drawCentered(src.author, font: NSFont(name: "Palatino-Italic", size: 13)!, y: 250)
    }
    // Blank verso.
    page {}
    for ch in src.chapters {
        let storage = NSTextStorage(attributedString: chapterText(ch))
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        var containers: [NSTextContainer] = []
        let bodySize = CGSize(width: pageSize.width - margins.inner - margins.outer, height: pageSize.height - margins.top - margins.bottom)
        while true {
            let tc = NSTextContainer(size: bodySize)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            containers.append(tc)
            let r = lm.glyphRange(for: tc)
            if NSMaxRange(r) >= lm.numberOfGlyphs || r.length == 0 { break }
        }
        for (k, tc) in containers.enumerated() {
            let recto = (pageNumber + 1) % 2 == 1
            let left = recto ? margins.inner : margins.outer
            page {
                if k > 0 {
                    let header = recto ? ch.title.uppercased() : src.title.uppercased()
                    drawCentered(header, font: NSFont(name: "Palatino-Italic", size: 8.5)!, y: 34)
                }
                drawCentered(String(pageNumber + 1), font: NSFont(name: "Palatino-Roman", size: 9.5)!, y: pageSize.height - 44)
                lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: tc), at: CGPoint(x: left, y: margins.top))
            }
        }
    }
    ctx.closePDF()
}

// MARK: - Scanned variants

struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

func scanned(from url: URL, to out: URL, junkLayer: Bool) {
    let doc = CGPDFDocument(url as CFURL)!
    var box = CGRect(origin: .zero, size: pageSize)
    let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
    var rng = LCG(s: 42)
    let junkWords = ["tbe", "aud", "wbich", "rn", "0f", "tlie", "Mr.", "'", "iu", "witb", "bave", "sbe", "~", "j", "aud", "Bcnnet", "tbat"]
    for i in 1...doc.numberOfPages {
        guard let page = doc.page(at: i) else { continue }
        let dpi = 150.0, scale = dpi / 72
        let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
        let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // Off-white paper.
        g.setFillColor(gray: 0.94, alpha: 1)
        g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        g.scaleBy(x: scale, y: scale)
        // A slight skew, like a real scan.
        g.translateBy(x: pageSize.width / 2, y: pageSize.height / 2)
        g.rotate(by: (Double(i % 3) - 1) * 0.004)
        g.translateBy(x: -pageSize.width / 2, y: -pageSize.height / 2)
        g.drawPDFPage(page)
        // Grain and specks.
        let data = g.data!.assumingMemoryBound(to: UInt8.self)
        for p in 0..<(w * h) {
            let n = Int(rng.next() % 13) - 6
            data[p] = UInt8(max(0, min(255, Int(data[p]) + n)))
            if rng.next() % 6000 == 0 { data[p] = 60 }
        }
        // Embed as JPEG, as scanners do (and to keep fixtures small).
        let raw = g.makeImage()!
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, raw, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg, nil)!, 0, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        if junkLayer {
            // A scanner's hidden OCR layer, mostly wrong.
            ctx.setTextDrawingMode(.invisible)
            let font = CTFontCreateWithName("Times-Roman" as CFString, 10, nil)
            var y = pageSize.height - 70
            while y > 70 {
                let words = (0..<9).map { _ in junkWords[Int(rng.next() % UInt64(junkWords.count))] }.joined(separator: " ")
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [.font: font]))
                ctx.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(line, ctx)
                y -= 14
            }
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// MARK: - Expected output

func expected(_ src: Source) -> [String: Any] {
    func clean(_ s: String) -> String {
        var out = "", inItalic = false
        for (i, part) in s.components(separatedBy: "_").enumerated() {
            if i > 0 { out += inItalic ? "</i>" : "<i>"; inItalic.toggle() }
            out += part
        }
        return out
    }
    return [
        "title": src.title,
        "author": src.author,
        "chapters": src.chapters.map { ch -> [String: Any] in
            var blocks: [[String: String]] = []
            for item in ch.items {
                switch item {
                case .para(let t): blocks.append(["kind": "paragraph", "text": clean(t)])
                case .stanza(let lines): blocks.append(["kind": "verse", "text": lines.map(clean).joined(separator: "\n")])
                }
            }
            return ["title": ch.title, "subtitle": ch.subtitle ?? "", "blocks": blocks]
        },
    ]
}

let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }
for file in files.sorted(by: { $0.path < $1.path }) {
    let name = file.deletingPathExtension().lastPathComponent
    let src = parse(try String(contentsOf: file, encoding: .utf8))
    let pdf = outDir.appendingPathComponent("\(name).pdf")
    makeBook(src, to: pdf)
    scanned(from: pdf, to: outDir.appendingPathComponent("\(name)-scan.pdf"), junkLayer: false)
    scanned(from: pdf, to: outDir.appendingPathComponent("\(name)-junk.pdf"), junkLayer: true)
    let json = try JSONSerialization.data(withJSONObject: expected(src), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try json.write(to: outDir.appendingPathComponent("\(name).expected.json"))
    print("wrote \(name).pdf, \(name)-scan.pdf, \(name)-junk.pdf, \(name).expected.json")
}
