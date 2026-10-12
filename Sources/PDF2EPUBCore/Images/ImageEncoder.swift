import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoder {
    /// Scales `image` to fit within `maxWidth` (never upscaling), optionally converting to grayscale.
    public static func resize(_ image: CGImage, maxWidth: Int, maxHeight: Int = .max, grayscale: Bool) -> CGImage? {
        let scale = min(1, Double(maxWidth) / Double(image.width), Double(maxHeight) / Double(image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        return draw(image, in: CGRect(x: 0, y: 0, width: w, height: h), canvas: CGSize(width: w, height: h), grayscale: grayscale)
    }

    /// Fits `image` inside an exact canvas, centered on white (for covers).
    public static func letterbox(_ image: CGImage, width: Int, height: Int, grayscale: Bool) -> CGImage? {
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        let rect = CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
        return draw(image, in: rect, canvas: CGSize(width: width, height: height), grayscale: grayscale)
    }

    static func draw(_ image: CGImage, in rect: CGRect, canvas: CGSize, grayscale: Bool) -> CGImage? {
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Baseline (non-progressive) JPEG.
    public static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Encodes as JPEG, lowering quality until the file fits `maxBytes` (best effort).
    public static func jpeg(_ image: CGImage, quality: Double, maxBytes: Int) -> Data? {
        var q = quality
        var best = jpeg(image, quality: q)
        while let d = best, d.count > maxBytes, q > 0.35 {
            q -= 0.1
            best = jpeg(image, quality: q)
        }
        return best
    }
}
