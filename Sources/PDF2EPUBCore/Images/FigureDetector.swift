import Foundation
import PDFKit
import CoreGraphics

/// Finds pictures on pages, slots them into the reading order, and crops them out.
///
/// Sources: placed raster images from the content stream, tables found by OCR, and
/// "ink" left on a low-resolution render after masking out every text line, which
/// catches vector drawings and illustrations on scanned pages.
public enum FigureDetector {
    static let inkDPI = 50.0

    public static func detect(pages: inout [PageLines], doc: PDFDocument, context: LayoutContext) -> [FigureRegion] {
        var out: [FigureRegion] = []
        for p in pages.indices {
            guard let page = doc.page(at: pages[p].index) else { continue }
            var rects = pages[p].figureRects.filter { r in
                let area = Double(r.width * r.height)
                return area >= 0.015 && area < 0.92 && r.width >= 0.08 && r.height >= 0.03
            }
            rects += inkRegions(page: page, lines: pages[p].lines, body: context.body(pages[p].source))
            rects = mergeOverlapping(rects)
            // Grow each region to take in labels hugging its edges ("A", "B", "Fig. 3" stays out).
            let body = context.body(pages[p].source)
            let labels = pages[p].lines.filter {
                let n = $0.plainText.trimmingCharacters(in: .whitespaces).count
                return n <= 4 || ($0.fontSize < body * 0.8 && n <= 20)
            }
            for k in rects.indices {
                for _ in 0..<2 {
                    for l in labels where l.bbox.intersects(rects[k].insetBy(dx: -0.025, dy: -0.02)) {
                        rects[k] = rects[k].union(l.bbox)
                    }
                }
            }

            var accepted: [CGRect] = []
            for r in rects {
                let inside = pages[p].lines.filter { r.insetBy(dx: -0.005, dy: -0.005).contains($0.bbox.center) }
                // A region full of long text lines is text, not a picture.
                let longLines = inside.filter { $0.plainText.count > 60 }.count
                if longLines >= 2 { continue }
                if pages[p].source == .ocr && inside.count > 12 { continue }
                accepted.append(r)
            }
            // Labels inside a figure belong to the picture.
            if !accepted.isEmpty {
                pages[p].lines.removeAll { line in
                    if BlockClassifier.isCaption(line.plainText) { return false }
                    return accepted.contains { r in
                        let grown = r.insetBy(dx: -0.005, dy: -0.005)
                        return line.plainText.count > 20 ? grown.contains(line.bbox) : grown.contains(line.bbox.center)
                    }
                }
            }
            // A page that is one big picture with no text keeps the whole page.
            if accepted.isEmpty, pages[p].lines.isEmpty,
               pages[p].figureRects.contains(where: { Double($0.width * $0.height) >= 0.5 }) {
                accepted.append(CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96))
            }
            out += accepted.map { FigureRegion(page: pages[p].index, bbox: $0) }
        }
        return out
    }

    /// Ink not covered by text: connected regions on a coarse grid of a low-res render.
    static func inkRegions(page: PDFPage, lines: [Line], body: Double) -> [CGRect] {
        guard let image = PageRenderer.render(page, dpi: inkDPI),
              let ctxData = grayPixels(image) else { return [] }
        let w = image.width, h = image.height
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where ctxData[i] < 170 { ink[i] = true }
        // Mask text lines (only body-size and larger: small labels stay as ink).
        for l in lines where l.fontSize >= body * 0.7 || l.plainText.count > 25 {
            let x0 = max(0, Int(Double(l.bbox.minX) * Double(w)) - 1), x1 = min(w - 1, Int(Double(l.bbox.maxX) * Double(w)) + 1)
            let y0 = max(0, Int(Double(l.bbox.minY) * Double(h)) - 1), y1 = min(h - 1, Int(Double(l.bbox.maxY) * Double(h)) + 1)
            guard x1 >= x0, y1 >= y0 else { continue }
            for y in y0...y1 { for x in x0...x1 { ink[y * w + x] = false } }
        }
        // Coarse grid.
        let cell = 4
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var grid = [Int](repeating: 0, count: gw * gh)
        for y in 0..<h { for x in 0..<w where ink[y * w + x] { grid[(y / cell) * gw + x / cell] += 1 } }
        var occupied = grid.map { $0 >= 2 }
        // Dilate one cell to join strokes of the same drawing.
        var dilated = occupied
        for gy in 0..<gh { for gx in 0..<gw where occupied[gy * gw + gx] {
            for dy in -1...1 { for dx in -1...1 {
                let nx = gx + dx, ny = gy + dy
                if nx >= 0, ny >= 0, nx < gw, ny < gh { dilated[ny * gw + nx] = true }
            } }
        } }
        occupied = dilated

        var seen = [Bool](repeating: false, count: gw * gh)
        var regions: [CGRect] = []
        for start in 0..<(gw * gh) where occupied[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = gw, maxX = 0, minY = gh, maxY = 0, count = 0, inkCount = 0
            while let c = stack.popLast() {
                let cx = c % gw, cy = c / gw
                count += 1
                inkCount += grid[c]
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let n = ny * gw + nx
                    if occupied[n] && !seen[n] { seen[n] = true; stack.append(n) }
                } }
            }
            let r = CGRect(x: Double(minX) / Double(gw), y: Double(minY) / Double(gh),
                           width: Double(maxX - minX + 1) / Double(gw), height: Double(maxY - minY + 1) / Double(gh))
            // Scanner borders and gutters hug the page edge.
            let touchesEdge = r.minX < 0.015 || r.minY < 0.015 || r.maxX > 0.985 || r.maxY > 0.985
            guard !touchesEdge, r.width >= 0.08, r.height >= 0.04, Double(r.width * r.height) >= 0.012 else { continue }
            // Thin rules (footnote separators, table borders alone) aren't figures.
            guard inkCount >= 40 else { continue }
            regions.append(r)
        }
        return regions
    }

    static func grayPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 255, count: w * h)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        // CGContext's origin is bottom-left; rows come out top-first in memory, matching our top-left coordinates.
        return ok ? buf : nil
    }

    static func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var out = rects
        var merged = true
        while merged {
            merged = false
            outer: for i in out.indices {
                for j in out.indices where j > i {
                    if out[i].insetBy(dx: -0.01, dy: -0.01).intersects(out[j]) {
                        out[i] = out[i].union(out[j])
                        out.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return out
    }

    /// Places figure blocks into a page's reading order and pulls their captions next to them.
    public static func insert(_ figures: [FigureRegion], into blocks: inout [Block], page: PageLines) {
        for f in figures.sorted(by: { $0.bbox.minY < $1.bbox.minY }) {
            var block = Block(page: page.index, bbox: f.bbox, kind: .figure, text: "", source: page.source)
            block.flags.insert(.startsSegment)
            let at = blocks.firstIndex { b in
                b.kind != .footnote && Double(b.bbox.minY) >= Double(f.bbox.midY)
                    && min(b.bbox.maxX, f.bbox.maxX) - max(b.bbox.minX, f.bbox.minX) > 0
            } ?? (blocks.firstIndex { $0.kind == .footnote } ?? blocks.count)
            blocks.insert(block, at: at)
            // The block after a figure starts fresh.
            if at + 1 < blocks.count { blocks[at + 1].flags.insert(.startsSegment) }
        }
    }

    /// Renders every figure block to a JPEG and sets its `imageRef`.
    public static func extract(_ blocks: inout [Block], doc: PDFDocument, profile: Profile, log: Log) -> [BookImage] {
        var images: [BookImage] = []
        for i in blocks.indices where blocks[i].kind == .figure {
            guard let page = doc.page(at: blocks[i].page) else { continue }
            let size = PageGeometry(page: page).displaySize
            let r = blocks[i].bbox
            let widthPts = Double(r.width) * Double(size.width)
            let dpi = min(300, max(110, Double(profile.maxImageWidth) / max(widthPts / 72, 0.1)))
            guard let rendered = PageRenderer.render(page, dpi: dpi) else { continue }
            let pad = 0.004
            let crop = CGRect(x: (Double(r.minX) - pad) * Double(rendered.width),
                              y: (Double(r.minY) - pad) * Double(rendered.height),
                              width: (Double(r.width) + 2 * pad) * Double(rendered.width),
                              height: (Double(r.height) + 2 * pad) * Double(rendered.height))
                .intersection(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)).integral
            guard let cropped = rendered.cropping(to: crop),
                  let scaled = ImageEncoder.resize(cropped, maxWidth: profile.maxImageWidth, maxHeight: profile.maxImageWidth * 5 / 3,
                                                   grayscale: profile.grayscaleImages),
                  let data = ImageEncoder.jpeg(scaled, quality: profile.jpegQuality,
                                               maxBytes: profile.maxImageBytes) else {
                log.warn("could not render figure on page \(blocks[i].page + 1)")
                continue
            }
            let path = String(format: "images/fig%03d.jpg", images.count + 1)
            images.append(BookImage(path: path, data: data))
            blocks[i].imageRef = path
        }
        // Figures that failed to render are dropped.
        blocks.removeAll { $0.kind == .figure && $0.imageRef == nil }
        return images
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
