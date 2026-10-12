import Foundation
import PDFKit
import CryptoKit

public struct ConversionOptions: Sendable {
    public var profile: Profile = Profile.all[0]
    public var ocr: OCRMode = .auto
    public var useLLM = true
    public var title: String?
    public var author: String?
    public var keepIntermediate: URL?
    public var forceVerse = false
    /// Text layers scoring below this fraction of dictionary words are re-read with OCR.
    /// Born-digital pages with many names, abbreviations or foreign words score around 0.8;
    /// scanner junk scores far lower.
    public var textQualityThreshold = 0.65
    public var ocrDPI = 300.0
    /// Pages to convert (0-based), for debugging. Nil means all.
    public var pageRange: ClosedRange<Int>?

    public init() {}
}

public struct ConversionReport: Sendable {
    public var output: URL
    public var pages: Int
    public var ocrPages: Int
    public var chapters: Int
    public var warnings: [String]
    public var stats: EPUBStats
}

public enum ConversionError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    case locked(URL)
    case noContent

    public var description: String {
        switch self {
        case .cannotOpen(let u): return "Could not open \(u.lastPathComponent) as a PDF."
        case .locked(let u): return "\(u.lastPathComponent) is password-protected."
        case .noContent: return "Found no text or pages to convert."
        }
    }
}

public final class Pipeline {
    let options: ConversionOptions
    let log: Log
    let lexicon = Lexicon()
    /// The cleanup pass; nil runs heuristics only.
    public var cleaner: (any BlockCleaner)?

    public init(options: ConversionOptions, log: Log) {
        self.options = options
        self.log = log
    }

    public func convert(input: URL, output: URL) async throws -> ConversionReport {
        let (book, pages, ocrPages) = try await makeBook(input: input)
        let stats = try EPUBWriter.write(book, profile: options.profile, to: output)
        return ConversionReport(output: output, pages: pages, ocrPages: ocrPages, chapters: book.chapters.count,
                                warnings: log.warnings, stats: stats)
    }

    /// Runs every stage except writing the file.
    public func makeBook(input: URL) async throws -> (book: Book, pages: Int, ocrPages: Int) {
        var clock = Date()
        func lap(_ stage: String) {
            log.debug(String(format: "[%@ %.2fs]", stage, Date().timeIntervalSince(clock)))
            clock = Date()
        }
        guard let doc = PDFDocument(url: input) else { throw ConversionError.cannotOpen(input) }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw ConversionError.locked(input) }
        guard doc.pageCount > 0 else { throw ConversionError.noContent }

        var metadata = PDFIngest.metadata(doc, fileURL: input)
        if let t = options.title { metadata.title = t }
        if let a = options.author { metadata.author = a }
        let outline = PDFIngest.outline(doc)

        // Language first: it drives the dictionary used to judge text layers.
        lexicon.detectLanguage(from: sampleText(doc))
        metadata.language = lexicon.languageCode ?? "en"

        // 1. Ingest: text layer or OCR, page by page.
        var (pages, infos) = try await ingest(doc)
        let ocrPages = infos.filter { $0.source == .ocr }.count

        lap("ingest")
        // 2. Normalize and gather document statistics.
        for p in pages.indices {
            for l in pages[p].lines.indices { pages[p].lines[l].text = Normalizer.normalize(pages[p].lines[l].text) }
            pages[p].lines.removeAll { $0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let allLines = pages.flatMap(\.lines)
        let vocab = TextJoiner.vocabulary(from: allLines.map(\.text))
        var bodySize: [TextSource: Double] = [:]
        for source in [TextSource.textLayer, .ocr] {
            if let size = weightedMedianSize(pages.filter { $0.source == source }.flatMap(\.lines)) { bodySize[source] = size }
        }
        if let ocrBody = bodySize[.ocr] { VisionOCR.snapSizes(&pages, body: ocrBody) }
        let context = LayoutContext(bodySize: bodySize.isEmpty ? [.textLayer: 10] : bodySize, lexicon: lexicon,
                                    forceVerse: options.forceVerse,
                                    hyphenatedWords: vocab.hyphenated, knownWords: vocab.words)
        log.debug("body size: \(bodySize.map { "\($0.key.rawValue)=\(String(format: "%.1f", $0.value))" }.joined(separator: ", "))")

        lap("normalize+stats")
        // 3. Layout.
        MarginFilter.apply(&pages, bodySize: bodySize)
        var figures: [FigureRegion] = []
        if options.profile.maxImageWidth > 0 {
            figures = FigureDetector.detect(pages: &pages, doc: doc, context: context)
        }
        lap("margins+figures")
        let suspicious = OCRSuspects(lexicon: lexicon, lines: pages.filter { $0.source == .ocr }.flatMap(\.lines))
        var blocks: [Block] = []
        for page in pages {
            var pageBlocks = BlockBuilder.build(page: page, context: context)
            for i in pageBlocks.indices where pageBlocks[i].source == .ocr {
                let split = suspicious.splitRunTogetherWords(pageBlocks[i].plainText)
                if split != pageBlocks[i].plainText, let patched = TextPatch.apply(to: pageBlocks[i].text, newPlain: split) {
                    pageBlocks[i].text = patched
                }
                if pageBlocks[i].confidence < 0.45 || suspicious.hasSuspectWords(pageBlocks[i].plainText) {
                    pageBlocks[i].flags.insert(.lowConfidence)
                }
            }
            FigureDetector.insert(figures.filter { $0.page == page.index }, into: &pageBlocks, page: page)
            blocks += pageBlocks
        }
        lap("blocks")
        BlockClassifier.classify(&blocks, context: context)
        // OCR'd "headings" full of non-words are often stamps, inscriptions or noise: ask.
        for i in blocks.indices where blocks[i].source == .ocr && blocks[i].kind.isHeading
            && suspicious.hasSuspectWords(blocks[i].plainText) {
            blocks[i].flags.insert(.ambiguousKind)
        }
        lap("classify")
        FlowJoiner.markContinuations(&blocks)
        try dump("blocks-heuristic", blocks)

        lap("joins")
        // 4. Language-model cleanup.
        if let cleaner {
            if let llm = cleaner as? LLMCleaner {
                llm.suspects = suspicious
                llm.transcriptURL = options.keepIntermediate?.appendingPathComponent("llm-transcript.txt")
            }
            await cleaner.clean(&blocks, log: log)
            try dump("blocks-cleaned", blocks)
        }
        FlowJoiner.mergeContinuations(&blocks, context: context)
        FootnoteLinker.link(&blocks)

        lap("llm+merge")
        var document = Document(metadata: metadata, outline: outline, pages: infos, blocks: blocks,
                                figures: figures, bodyFontSize: bodySize[.textLayer] ?? bodySize[.ocr] ?? 10)
        guard !document.blocks.isEmpty else { throw ConversionError.noContent }

        // 5. Images and structure.
        let images = FigureDetector.extract(&document.blocks, doc: doc, profile: options.profile, log: log)
        lap("images")
        let finalChapters = ChapterBuilder.build(document)
        try dump("chapters", finalChapters)

        lap("chapters")
        let book = Book(metadata: metadata, identifier: identifier(for: input), chapters: finalChapters,
                        images: images, cover: makeCover(doc), modified: Date())
        lap("cover")
        return (book, pages.count, ocrPages)
    }

    // MARK: - Ingest

    func ingest(_ doc: PDFDocument) async throws -> ([PageLines], [PageInfo]) {
        let range = options.pageRange.map { max(0, $0.lowerBound)...min(doc.pageCount - 1, $0.upperBound) }
            ?? 0...(doc.pageCount - 1)
        let indices = Array(range)
        var pages = [PageLines?](repeating: nil, count: indices.count)
        var infos = [PageInfo?](repeating: nil, count: indices.count)
        let languages = lexicon.languageCode.map { [$0] } ?? []
        let dpi = options.ocrDPI
        var done = 0

        try await withThrowingTaskGroup(of: (Int, OCRPage, CGSize).self) { group in
            var inFlight = 0
            func store(_ slot: Int, _ ocr: OCRPage, _ size: CGSize) {
                let conf = ocr.lines.isEmpty ? 0 : ocr.lines.map(\.confidence).reduce(0, +) / Double(ocr.lines.count)
                pages[slot] = PageLines(index: indices[slot], size: size, source: .ocr, lines: ocr.lines, figureRects: ocr.tables)
                infos[slot] = PageInfo(index: indices[slot], size: size, source: .ocr, textQuality: infos[slot]?.textQuality,
                                       lineCount: ocr.lines.count, meanConfidence: conf)
                if ocr.usedFallback { log.debug("page \(indices[slot] + 1): document OCR failed, used line OCR") }
                done += 1
                log.progress("page", done, indices.count)
            }
            for (slot, index) in indices.enumerated() {
                guard let page = doc.page(at: index) else { continue }
                let extracted = TextLayerExtractor.extract(page: page)
                let decision = ocrDecision(extracted)
                infos[slot] = PageInfo(index: index, size: extracted.size, source: .textLayer, textQuality: decision.quality,
                                       lineCount: extracted.lines.count, meanConfidence: 1)
                if decision.ocr, let image = PageRenderer.render(page, dpi: dpi) {
                    log.debug("page \(index + 1): OCR (\(decision.reason))")
                    let size = extracted.size
                    group.addTask { (slot, await VisionOCR.recognize(image, pageSize: size, languages: languages), size) }
                    inFlight += 1
                    if inFlight >= 3, let r = try await group.next() {
                        inFlight -= 1
                        store(r.0, r.1, r.2)
                    }
                } else {
                    var p = PageLines(index: index, size: extracted.size, source: .textLayer, lines: extracted.lines)
                    p.figureRects = extracted.imageRects
                    pages[slot] = p
                    done += 1
                    log.progress("page", done, indices.count)
                }
            }
            for try await r in group { store(r.0, r.1, r.2) }
        }
        let lowConfidence = infos.compactMap { $0 }.filter { $0.source == .ocr && $0.lineCount > 3 && $0.meanConfidence < 0.4 }
        if !lowConfidence.isEmpty {
            log.warn("low-confidence OCR on \(lowConfidence.count) page(s): \(lowConfidence.prefix(10).map { String($0.index + 1) }.joined(separator: ", "))")
        }
        return (pages.compactMap { $0 }, infos.compactMap { $0 })
    }

    struct OCRDecision { var ocr: Bool; var quality: Double?; var reason: String }

    func ocrDecision(_ page: ExtractedPage) -> OCRDecision {
        switch options.ocr {
        case .never: return OCRDecision(ocr: false, quality: nil, reason: "disabled")
        case .always: return OCRDecision(ocr: true, quality: nil, reason: "forced")
        case .auto: break
        }
        let text = page.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageArea = page.imageRects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        if text.count < 15 {
            return OCRDecision(ocr: imageArea > 0.25, quality: nil, reason: "no text layer")
        }
        if page.invisibleFraction > 0.5 {
            return OCRDecision(ocr: true, quality: nil, reason: "scanner's hidden OCR layer")
        }
        let q = lexicon.quality(of: text)
        if q.tokens >= 8 && q.score < options.textQualityThreshold {
            return OCRDecision(ocr: true, quality: q.score, reason: String(format: "text layer scores %.2f", q.score))
        }
        return OCRDecision(ocr: false, quality: q.tokens >= 8 ? q.score : nil, reason: "text layer ok")
    }

    func sampleText(_ doc: PDFDocument) -> String {
        let n = doc.pageCount
        let picks = Set(stride(from: 0, to: n, by: max(1, n / 15)).map { $0 })
        return picks.sorted().compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Helpers

    func weightedMedianSize(_ lines: [Line]) -> Double? {
        let pairs = lines.map { ($0.fontSize, Double($0.plainText.count)) }.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let total = pairs.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var acc = 0.0
        for (size, w) in pairs {
            acc += w
            if acc >= total / 2 { return size }
        }
        return pairs.last?.0
    }

    func makeCover(_ doc: PDFDocument) -> BookImage? {
        guard let page = doc.page(at: 0) else { return nil }
        let size = options.profile.coverSize
        let pageSize = PageGeometry(page: page).displaySize
        let dpi = 72 * Double(size.height) / Double(max(pageSize.height, 1)) * 1.5
        guard let rendered = PageRenderer.render(page, dpi: dpi),
              let fitted = ImageEncoder.letterbox(rendered, width: size.width, height: size.height,
                                                  grayscale: options.profile.grayscaleImages),
              let data = ImageEncoder.jpeg(fitted, quality: options.profile.jpegQuality, maxBytes: options.profile.maxImageBytes * 3 / 2) else { return nil }
        return BookImage(path: "images/cover.jpg", data: data)
    }

    func identifier(for url: URL) -> String {
        var hasher = SHA256()
        if let handle = try? FileHandle(forReadingFrom: url) {
            if let head = try? handle.read(upToCount: 4 << 20) { hasher.update(data: head) }
            try? handle.close()
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        hasher.update(data: Data(String(size).utf8))
        let b = Array(hasher.finalize())
        let hex = b.prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return "urn:uuid:" + parts.joined(separator: "-")
    }

    func dump<T: Encodable>(_ name: String, _ value: T) throws {
        guard let dir = options.keepIntermediate else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: dir.appendingPathComponent("\(name).json"))
    }
}
