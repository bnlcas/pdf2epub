import Foundation
import PDFKit
import CoreGraphics

public enum PageRenderer {
    /// Renders a page to an 8-bit grayscale bitmap at the given resolution.
    public static func render(_ page: PDFPage, dpi: Double = 300, maxPixels: Int = 40_000_000) -> CGImage? {
        let size = PageGeometry(page: page).displaySize
        var scale = dpi / 72
        if Double(size.width) * scale * Double(size.height) * scale > Double(maxPixels) {
            scale = (Double(maxPixels) / Double(size.width * size.height)).squareRoot()
        }
        let w = max(1, Int((Double(size.width) * scale).rounded()))
        let h = max(1, Int((Double(size.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // Link borders and form widgets would show up as ink in figures and OCR.
        let showed = page.displaysAnnotations
        page.displaysAnnotations = false
        page.draw(with: .cropBox, to: ctx)
        page.displaysAnnotations = showed
        return ctx.makeImage()
    }
}
