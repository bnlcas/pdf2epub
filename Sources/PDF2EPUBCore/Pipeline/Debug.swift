import Foundation
import PDFKit

/// Developer diagnostics.
public enum Debug {
    public static func dumpPage(_ url: URL, page index: Int, ocr: Bool) async throws {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { throw ConversionError.cannotOpen(url) }
        let ex = TextLayerExtractor.extract(page: page)
        print("size \(ex.size) invisible \(String(format: "%.2f", ex.invisibleFraction)) images \(ex.imageRects.count)")
        var lines = ex.lines
        if ocr, let image = PageRenderer.render(page, dpi: 300) {
            let result = await VisionOCR.recognize(image, pageSize: ex.size)
            print("ocr fallback \(result.usedFallback) tables \(result.tables.count)")
            lines = result.lines
        }
        for l in lines {
            print(String(format: "%.3f %.3f %.3f %.3f %5.1f %.2f g%2d %@%@%@ ", l.bbox.minX, l.bbox.minY, l.bbox.width, l.bbox.height,
                         l.fontSize, l.confidence, l.group ?? -1, l.isItalic ? "I" : "-", l.isBold ? "B" : "-", l.isTitle ? "T" : "-")
                  + visible(l.text))
        }
    }

    /// Shows style markers as tags.
    public static func visible(_ s: String) -> String {
        s.replacingOccurrences(of: String(InlineStyle.italicOn), with: "<i>")
            .replacingOccurrences(of: String(InlineStyle.italicOff), with: "</i>")
            .replacingOccurrences(of: String(InlineStyle.boldOn), with: "<b>")
            .replacingOccurrences(of: String(InlineStyle.boldOff), with: "</b>")
            .replacingOccurrences(of: String(InlineStyle.supOn), with: "<sup>")
            .replacingOccurrences(of: String(InlineStyle.supOff), with: "</sup>")
    }
}
