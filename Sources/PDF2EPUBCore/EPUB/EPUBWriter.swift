import Foundation

public struct BookImage: Sendable {
    /// Path inside OEBPS, e.g. "images/fig003.jpg".
    public var path: String
    public var data: Data
    public var mediaType: String

    public init(path: String, data: Data, mediaType: String = "image/jpeg") {
        self.path = path
        self.data = data
        self.mediaType = mediaType
    }
}

public struct Book: Sendable {
    public var metadata: Metadata
    /// Stable identifier, e.g. "urn:uuid:…".
    public var identifier: String
    public var chapters: [Chapter]
    public var images: [BookImage]
    public var cover: BookImage?
    public var modified: Date

    public init(metadata: Metadata, identifier: String, chapters: [Chapter], images: [BookImage] = [],
                cover: BookImage? = nil, modified: Date = Date()) {
        self.metadata = metadata
        self.identifier = identifier
        self.chapters = chapters
        self.images = images
        self.cover = cover
        self.modified = modified
    }
}

public struct EPUBStats: Sendable {
    public var files: Int
    public var largestFileBytes: Int
    public var totalBytes: Int
}

/// Packages a book as EPUB 3 with an EPUB 2 NCX for older readers.
public enum EPUBWriter {
    public static func write(_ book: Book, profile: Profile, to url: URL) throws -> EPUBStats {
        let (data, stats) = package(book, profile: profile)
        try data.write(to: url, options: .atomic)
        return stats
    }

    public static func package(_ book: Book, profile: Profile) -> (Data, EPUBStats) {
        let lang = book.metadata.language ?? "en"
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>

            """)
        zip.add("OEBPS/style.css", profile.css)

        // Render chapters to spine files.
        struct NavPoint { var title: String; var href: String; var level: Int }
        var spine: [(id: String, href: String)] = []
        var nav: [NavPoint] = []
        var largest = 0
        var rendered: [RenderedFile] = []
        for (n, chapter) in book.chapters.enumerated() {
            let files = XHTMLRenderer.render(chapter, number: n + 1, profile: profile, language: lang)
            if let first = files.first { nav.append(NavPoint(title: chapter.title, href: "text/\(first.name)", level: chapter.navLevel)) }
            rendered += files
        }
        // Endnote links cross files: resolve "#@id" now that we know where each id landed.
        let located = Self.locateAnchors(rendered)
        for f in rendered {
            let body = Self.unlinkMissingNotes(Self.resolveCrossLinks(f.body, file: f.name, anchors: located))
            let doc = XHTMLRenderer.document(title: f.title, body: body, language: lang)
            largest = max(largest, doc.utf8.count)
            let href = "text/\(f.name)"
            zip.add("OEBPS/\(href)", doc)
            spine.append((id: "c" + f.name.replacingOccurrences(of: ".xhtml", with: ""), href: href))
        }

        var manifest: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"<item id="css" href="style.css" media-type="text/css"/>"#,
        ]
        var spineRefs: [String] = []
        if let cover = book.cover {
            zip.add("OEBPS/\(cover.path)", cover.data, compress: false)
            manifest.append(#"<item id="cover-image" href="\#(cover.path)" media-type="\#(cover.mediaType)" properties="cover-image"/>"#)
            let coverDoc = XHTMLRenderer.document(
                title: "Cover",
                body: "<div class=\"cover\"><img src=\"\(cover.path)\" alt=\"Cover\"/></div>\n",
                language: lang, cssPath: "style.css")
            zip.add("OEBPS/cover.xhtml", coverDoc)
            manifest.append(#"<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>"#)
            spineRefs.append(#"<itemref idref="cover" linear="yes"/>"#)
        }
        for (i, img) in book.images.enumerated() {
            zip.add("OEBPS/\(img.path)", img.data, compress: false)
            manifest.append(#"<item id="img\#(i + 1)" href="\#(img.path)" media-type="\#(img.mediaType)"/>"#)
        }
        for s in spine {
            manifest.append(#"<item id="\#(s.id)" href="\#(s.href)" media-type="application/xhtml+xml"/>"#)
            spineRefs.append(#"<itemref idref="\#(s.id)"/>"#)
        }

        let title = XHTMLRenderer.escape(book.metadata.title ?? "Untitled")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var meta = [
            #"<dc:identifier id="bookid">\#(XHTMLRenderer.escape(book.identifier))</dc:identifier>"#,
            "<dc:title>\(title)</dc:title>",
            "<dc:language>\(lang)</dc:language>",
            #"<meta property="dcterms:modified">\#(iso.string(from: book.modified))</meta>"#,
        ]
        if let author = book.metadata.author, !author.isEmpty {
            meta.append("<dc:creator>\(XHTMLRenderer.escape(author))</dc:creator>")
        }
        if let subject = book.metadata.subject, !subject.isEmpty {
            meta.append("<dc:subject>\(XHTMLRenderer.escape(subject))</dc:subject>")
        }
        if book.cover != nil { meta.append(#"<meta name="cover" content="cover-image"/>"#) }

        let guide = book.cover != nil
            ? "<guide>\n<reference type=\"cover\" title=\"Cover\" href=\"cover.xhtml\"/>\n</guide>\n" : ""
        zip.add("OEBPS/content.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(lang)">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(meta.joined(separator: "\n"))
            </metadata>
            <manifest>
            \(manifest.joined(separator: "\n"))
            </manifest>
            <spine toc="ncx">
            \(spineRefs.joined(separator: "\n"))
            </spine>
            \(guide)</package>

            """)

        // nav.xhtml (EPUB 3) with nested lists by level.
        var navBody = "<nav epub:type=\"toc\" id=\"toc\">\n<h1>Contents</h1>\n"
        navBody += nestedList(nav.map { ($0.title, $0.href, $0.level) }, ordered: true) { title, href in
            "<a href=\"\(href)\">\(XHTMLRenderer.escape(title))</a>"
        }
        navBody += "</nav>\n"
        zip.add("OEBPS/nav.xhtml", XHTMLRenderer.document(title: "Contents", body: navBody, language: lang, cssPath: "style.css"))

        // toc.ncx (EPUB 2).
        var ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="\(lang)">
            <head>
            <meta name="dtb:uid" content="\(XHTMLRenderer.escape(book.identifier))"/>
            <meta name="dtb:depth" content="\((nav.map(\.level).max() ?? 0) + 1)"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
            </head>
            <docTitle><text>\(title)</text></docTitle>
            <navMap>

            """
        var stack: [Int] = []
        for (i, p) in nav.enumerated() {
            while let top = stack.last, top >= p.level {
                ncx += "</navPoint>\n"
                stack.removeLast()
            }
            ncx += "<navPoint id=\"np\(i + 1)\" playOrder=\"\(i + 1)\"><navLabel><text>\(XHTMLRenderer.escape(p.title))</text></navLabel><content src=\"\(p.href)\"/>\n"
            stack.append(p.level)
        }
        ncx += String(repeating: "</navPoint>\n", count: stack.count)
        ncx += "</navMap>\n</ncx>\n"
        zip.add("OEBPS/toc.ncx", ncx)

        let data = zip.finish()
        return (data, EPUBStats(files: spine.count, largestFileBytes: largest, totalBytes: data.count))
    }

    static let anchorPattern = try! NSRegularExpression(pattern: #"id="([nr]\d+-\d+|toc-\d+)""#)
    static let crossLinkPattern = try! NSRegularExpression(pattern: ##"<a href="#@([nr]\d+-\d+|toc-\d+)"( id="[^"]*")?>(.*?)</a>"##)

    static func locateAnchors(_ files: [RenderedFile]) -> [String: String] {
        var out: [String: String] = [:]
        for f in files {
            let ns = f.body as NSString
            for m in anchorPattern.matches(in: f.body, range: NSRange(location: 0, length: ns.length)) {
                out[ns.substring(with: m.range(at: 1))] = f.name
            }
        }
        return out
    }

    /// "#@n3-147" → "ch021.xhtml#n3-147" (or "#n3-147" in the same file); unknown targets
    /// lose the link but keep their text.
    static func resolveCrossLinks(_ body: String, file: String, anchors: [String: String]) -> String {
        guard body.contains("href=\"#@") else { return body }
        let ns = body as NSString
        var out = body
        for m in crossLinkPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: m.range(at: 1))
            let idAttr = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            let inner = ns.substring(with: m.range(at: 3))
            let replacement: String
            if let target = anchors[id] {
                let href = target == file ? "#\(id)" : "\(target)#\(id)"
                replacement = "<a href=\"\(href)\"\(idAttr)>\(inner)</a>"
            } else {
                replacement = inner
            }
            out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return out
    }

    /// A note reference whose note didn't land in the same file becomes a plain superscript.
    static func unlinkMissingNotes(_ body: String) -> String {
        guard body.contains("href=\"#fn") else { return body }
        var body = body
        // A note's back-link to a reference that isn't in this file: keep the label only.
        let back = try! NSRegularExpression(pattern: ##"<a href="#fnref(\d+)">(.*?)</a>"##)
        let bns = body as NSString
        for m in back.matches(in: body, range: NSRange(location: 0, length: bns.length)).reversed() {
            let id = bns.substring(with: m.range(at: 1))
            if !body.contains("id=\"fnref\(id)\"") {
                body = (body as NSString).replacingCharacters(in: m.range, with: bns.substring(with: m.range(at: 2)))
            }
        }
        let pattern = try! NSRegularExpression(pattern: ##"<a href="#fn(\d+)" id="fnref\d+">(<sup>.*?</sup>)</a>"##)
        let ns = body as NSString
        var out = body
        for m in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: m.range(at: 1))
            if !body.contains("<p id=\"fn\(id)\">") {
                out = (out as NSString).replacingCharacters(in: m.range, with: ns.substring(with: m.range(at: 2)))
            }
        }
        return out
    }

    /// Nested <ol>/<li> from a flat (title, href, level) list.
    static func nestedList(_ items: [(String, String, Int)], ordered: Bool,
                           link: (String, String) -> String) -> String {
        let tag = ordered ? "ol" : "ul"
        var out = ""
        var depth = -1
        var open: [Bool] = [] // whether an <li> is open at each depth
        for (title, href, level) in items {
            let target = max(0, level)
            if target > depth {
                while depth < target {
                    out += "<\(tag)>\n"
                    depth += 1
                    open.append(false)
                }
            } else {
                while depth > target {
                    if open.last == true { out += "</li>\n" }
                    out += "</\(tag)>\n"
                    open.removeLast()
                    depth -= 1
                }
                if open.last == true { out += "</li>\n" }
            }
            out += "<li>" + link(title, href)
            open[open.count - 1] = true
        }
        while depth >= 0 {
            if open.last == true { out += "</li>\n" }
            out += "</\(tag)>\n"
            open.removeLast()
            depth -= 1
        }
        return out
    }
}
