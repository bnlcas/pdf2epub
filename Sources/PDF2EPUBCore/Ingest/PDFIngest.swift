import Foundation
import PDFKit

public enum OCRMode: String, Sendable, CaseIterable {
    case auto, always, never
}

/// Document-level reading: metadata and outline.
public enum PDFIngest {
    public static func metadata(_ doc: PDFDocument, fileURL: URL) -> Metadata {
        let attrs = doc.documentAttributes ?? [:]
        var title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).flatMap(cleanTitle)
        var author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if author?.isEmpty == true { author = nil }
        // Missing metadata: the download's name often carries it ("Title -- Author.pdf").
        // (The pipeline may still improve on a bare file name from the title page.)
        let fromName = MetadataGuesser.fromFilename(fileURL)
        if title == nil { title = fromName.title }
        if author == nil { author = fromName.author }
        let subject = (attrs[PDFDocumentAttribute.subjectAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Metadata(title: title, author: author, language: nil, subject: subject?.isEmpty == true ? nil : subject)
    }

    /// Drops junk titles (file names, "Microsoft Word - …", Gutenberg prefixes).
    static func cleanTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^The Project Gutenberg e?Book,? #?\d*:?\s*(of\s+)?"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        if t.hasPrefix("Microsoft Word - ") { t.removeFirst("Microsoft Word - ".count) }
        let lower = t.lowercased()
        for ext in [".pdf", ".doc", ".docx", ".tex", ".dvi", ".indd", ".rtf", ".txt"] where lower.hasSuffix(ext) {
            t.removeLast(ext.count)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "untitled" || t.range(of: #"^[\w-]+$"#, options: .regularExpression) != nil && t.contains("_") {
            return nil
        }
        return t
    }

    public static func outline(_ doc: PDFDocument) -> [OutlineEntry] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [OutlineEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                   let page = dest.page {
                    let index = doc.index(for: page)
                    var y: Double? = nil
                    let p = dest.point
                    if p.y != kPDFDestinationUnspecifiedValue && p.y < 1e6 {
                        let geom = PageGeometry(page: page)
                        let n = geom.normalize(CGPoint(x: geom.box.minX, y: p.y))
                        if n.y >= 0 && n.y <= 1 { y = Double(n.y) }
                    }
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(OutlineEntry(title: title, level: level, page: index, y: y))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return out
    }
}
