import Foundation
import Vision
import CoreGraphics

public struct OCRPage: Sendable {
    public var lines: [Line]
    /// Normalized (top-left origin) regions Vision recognised as tables; rendered as images.
    public var tables: [CGRect]
    public var usedFallback: Bool
}

/// Text recognition with the macOS 26 document-structure request, falling back to plain
/// line recognition if that fails.
public enum VisionOCR {
    /// Ratio of a recognised line's box height to its font size, used to estimate point sizes
    /// for scanned pages so they compare with text-layer pages.
    static let lineHeightPerPoint = 1.0

    public static func recognize(_ image: CGImage, pageSize: CGSize, languages: [String] = []) async -> OCRPage {
        do {
            return try await recognizeDocument(image, pageSize: pageSize, languages: languages)
        } catch {
            let lines = (try? await recognizeLines(image, pageSize: pageSize, languages: languages)) ?? []
            return OCRPage(lines: lines, tables: [], usedFallback: true)
        }
    }

    static func recognizeDocument(_ image: CGImage, pageSize: CGSize, languages: [String]) async throws -> OCRPage {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        let langs = ocrLanguages(languages)
        if !langs.isEmpty {
            // Auto-detection reads old-style numerals as Cyrillic (6→б, 3→з) and puts
            // fullwidth CJK punctuation into English text; pin the book's languages instead.
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = langs.map { Locale.Language(identifier: $0) }
        }
        let observations = try await request.perform(on: image)
        var lines: [Line] = []
        var tables: [CGRect] = []
        var group = 0
        for doc in observations {
            let titleLines = Set((doc.document.title?.lines ?? []).map(\.uuid))
            var containers: [DocumentObservation.Container.Text] = doc.document.paragraphs
            for list in doc.document.lists {
                for item in list.items { containers.append(item.content.text) }
            }
            for paragraph in containers {
                for obs in paragraph.lines {
                    guard let line = makeLine(obs, pageSize: pageSize, group: group,
                                              isTitle: obs.isTitle || titleLines.contains(obs.uuid)) else { continue }
                    if lines.contains(where: { overlap($0.bbox, line.bbox) > 0.5 }) { continue }
                    lines.append(line)
                }
                group += 1
            }
            for table in doc.document.tables {
                tables.append(topLeft(table.boundingRegion.boundingBox.cgRect))
            }
        }
        // Drop lines that sit inside a table; the table becomes an image.
        lines.removeAll { line in tables.contains { $0.insetBy(dx: -0.005, dy: -0.005).contains(line.bbox) } }
        return OCRPage(lines: smoothSizes(lines), tables: tables, usedFallback: false)
    }

    static func recognizeLines(_ image: CGImage, pageSize: CGSize, languages: [String]) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let langs = ocrLanguages(languages)
        if !langs.isEmpty {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = langs.map { Locale.Language(identifier: $0) }
        }
        let observations = try await request.perform(on: image)
        return smoothSizes(observations.compactMap { makeLine($0, pageSize: pageSize, group: nil, isTitle: false) })
    }

    /// `PDF2EPUB_OCR_LANGS=en-US,zh-Hant` overrides the languages, for experiments.
    static func ocrLanguages(_ languages: [String]) -> [String] {
        if let env = ProcessInfo.processInfo.environment["PDF2EPUB_OCR_LANGS"] {
            return env.split(separator: ",").map(String.init)
        }
        return languages
    }

    static func makeLine(_ obs: RecognizedTextObservation, pageSize: CGSize, group: Int?, isTitle: Bool) -> Line? {
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let text = markSuperscripts(candidate, line: obs).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let box = topLeft(obs.boundingBox.cgRect)
        // The quad's side edges measure the line height even when the box is skewed.
        let left = hypot(Double(obs.topLeft.x - obs.bottomLeft.x) * pageSize.width, Double(obs.topLeft.y - obs.bottomLeft.y) * pageSize.height)
        let right = hypot(Double(obs.topRight.x - obs.bottomRight.x) * pageSize.width, Double(obs.topRight.y - obs.bottomRight.y) * pageSize.height)
        let edge = min(left, right)
        let size = (edge > 0 ? edge : Double(box.height * pageSize.height)) / lineHeightPerPoint
        return Line(text: text, bbox: box, fontSize: size, confidence: Double(candidate.confidence),
                    group: group, isTitle: isTitle)
    }

    /// Note references ("care.¹⁴⁷") come out of OCR glued to the word: "care.147". Vision
    /// can locate any substring, so check whether those digits sit raised above the line.
    static func markSuperscripts(_ candidate: RecognizedText, line obs: RecognizedTextObservation) -> String {
        let s = candidate.string
        guard s.contains(where: \.isNumber) else { return s }
        let lineBox = obs.boundingBox.cgRect
        let h = lineBox.height
        guard h > 0, let regex = try? NSRegularExpression(pattern: #"(?<=[\p{L}.,;:!?’”"')\]])\d{1,3}(?=[\s.,;:)]|$)"#) else { return s }
        var out = s
        let ns = s as NSString
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let r = Range(m.range, in: s), let digits = candidate.boundingBox(for: r)?.boundingBox.cgRect else { continue }
            let raise = (digits.minY - lineBox.minY) / h
            if ProcessInfo.processInfo.environment["PDF2EPUB_DEBUG_SUP"] != nil {
                FileHandle.standardError.write(Data(String(format: "sup? %@ raise=%.2f height=%.2f\n", String(s[r]), raise, digits.height / h).utf8))
            }
            if raise > 0.3 && digits.height / h < 0.75, let ro = Range(m.range, in: out) {
                out.replaceSubrange(ro, with: "\(InlineStyle.supOn)\(out[ro])\(InlineStyle.supOff)")
            }
        }
        return out
    }

    static func smoothSizes(_ lines: [Line]) -> [Line] {
        lines.map { l in
            var l = l
            l.text = SmartQuotes.apply(l.text)
            return l
        }
    }

    /// Box heights swing ±25% with ascenders, descenders and quotes. Snap ordinary lines near
    /// the book's typical height to it, so only real size changes stand out. Short all-caps
    /// lines (likely headings, with no descenders) keep their measured size.
    public static func snapSizes(_ pages: inout [PageLines], body: Double) {
        for p in pages.indices where pages[p].source == .ocr {
            for i in pages[p].lines.indices {
                let l = pages[p].lines[i]
                let plain = l.plainText
                let letters = plain.filter(\.isLetter)
                let caps = !letters.isEmpty && letters.allSatisfy(\.isUppercase) && plain.count <= 40
                if !caps && l.fontSize > body * 0.65 && l.fontSize < body * 1.35 {
                    pages[p].lines[i].fontSize = body
                }
            }
        }
    }

    /// Vision's normalized rects have a bottom-left origin.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? Double(i.width * i.height / smaller) : 0
    }
}
