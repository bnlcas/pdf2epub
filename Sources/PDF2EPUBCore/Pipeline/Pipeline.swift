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
    var hiddenLayerIsStyled = false
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
        var outline = PDFIngest.outline(doc)

        // Language first: it drives the dictionary used to judge text layers.
        lexicon.detectLanguage(from: sampleText(doc))
        metadata.language = lexicon.languageCode ?? "en"

        hiddenLayerIsStyled = Self.hiddenLayerIsStyled(doc)
        log.debug("hidden OCR layer: \(hiddenLayerIsStyled ? "styled (trusted if it reads well)" : "plain or absent")")

        // 1. Ingest: text layer or OCR, page by page.
        var (pages, infos) = try await ingest(doc)
        let ocrPages = infos.filter { $0.source == .ocr }.count

        lap("ingest")
        // 2. Normalize and gather document statistics.
        for p in pages.indices {
            for l in pages[p].lines.indices { pages[p].lines[l].text = Normalizer.normalize(pages[p].lines[l].text) }
            pages[p].lines.removeAll { $0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        // Undo consistent glyph mis-mappings in OCR'd text (an italic "k" read as "\").
        let ocrText = pages.filter { $0.source == .ocr || $0.hiddenLayer }.flatMap(\.lines)
        let glyphMap = GlyphSubstitution.infer(ocrText, lexicon: lexicon)
        if !glyphMap.isEmpty {
            log.debug("glyph substitutions: \(glyphMap.map { "\($0.key)→\($0.value)" }.joined(separator: ", "))")
            for p in pages.indices where pages[p].source == .ocr || pages[p].hiddenLayer {
                for l in pages[p].lines.indices {
                    pages[p].lines[l].text = GlyphSubstitution.apply(glyphMap, to: pages[p].lines[l].text)
                }
            }
        }
        // Small caps read as mixed case, Cyrillic look-alikes, fullwidth punctuation.
        let latinScript = !["ru", "uk", "bg", "el", "sr", "mk", "be"].contains(lexicon.languageCode ?? "en")
        for p in pages.indices where pages[p].source == .ocr || pages[p].hiddenLayer {
            for l in pages[p].lines.indices {
                pages[p].lines[l].text = OCRTextRepair.repair(pages[p].lines[l].text, lexicon: lexicon, latinScript: latinScript)
            }
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

        if outline.isEmpty {
            var extra: [Int: [Line]] = [:]
            if let range = PrintedContents.candidatePages(pages, pageCount: doc.pageCount) {
                extra = await contentsPageNumbers(doc, pages: Array(pages[range]))
            }
            outline = PrintedContents.entries(pages: pages, folios: FolioMap(pages: pages), pageCount: doc.pageCount,
                                              extraNumbers: extra)
            if !outline.isEmpty { log.debug("chapters from the printed contents: \(outline.map(\.title).joined(separator: " | "))") }
        }
        var figures: [FigureRegion] = []
        if options.profile.maxImageWidth > 0 {
            figures = FigureDetector.detect(pages: &pages, doc: doc, context: context)
        }
        lap("margins+figures")
        // OCR'd text (by Vision, or a scanner's hidden layer) gets checked for misreadings.
        let ocrLike = { (p: PageLines) in p.source == .ocr || p.hiddenLayer }
        let suspicious = OCRSuspects(lexicon: lexicon, lines: pages.filter(ocrLike).flatMap(\.lines))
        let ocrLikePages = Set(pages.filter(ocrLike).map(\.index))
        var blocks: [Block] = []
        for page in pages {
            var pageBlocks = BlockBuilder.build(page: page, context: context)
            for i in pageBlocks.indices where ocrLikePages.contains(pageBlocks[i].page) {
                let split = suspicious.splitRunTogetherWords(pageBlocks[i].plainText)
                if split != pageBlocks[i].plainText, let patched = TextPatch.apply(to: pageBlocks[i].text, newPlain: split) {
                    pageBlocks[i].text = patched
                }
                if pageBlocks[i].confidence < 0.45 || suspicious.hasSuspectWords(InlineStyle.stripSuperscripts(pageBlocks[i].text)) {
                    pageBlocks[i].flags.insert(.lowConfidence)
                }
            }
            FigureDetector.insert(figures.filter { $0.page == page.index }, into: &pageBlocks, page: page)
            blocks += pageBlocks
        }
        lap("blocks")
        BlockClassifier.classify(&blocks, context: context)
        // OCR'd "headings" full of non-words are often stamps, inscriptions or noise: ask.
        for i in blocks.indices where ocrLikePages.contains(blocks[i].page) && blocks[i].kind.isHeading
            && suspicious.hasSuspectWords(blocks[i].plainText) {
            blocks[i].flags.insert(.ambiguousKind)
        }
        lap("classify")
        FlowJoiner.markContinuations(&blocks)
        try dump("blocks-heuristic", blocks)

        lap("joins")
        // Title page fallback for whatever the PDF and its file name didn't say.
        if metadata.title == nil || metadata.author == nil {
            let guess = MetadataGuesser.fromTitlePage(blocks, bodySize: bodySize[.textLayer] ?? bodySize[.ocr] ?? 10, lexicon: lexicon)
            if metadata.title == nil, options.title == nil { metadata.title = guess.title }
            if metadata.author == nil, options.author == nil { metadata.author = guess.author }
        }
        if metadata.title == nil {
            metadata.title = input.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        }

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
        log.progress("writing", 0, 1)
        let images = FigureDetector.extract(&document.blocks, doc: doc, profile: options.profile, log: log)
        lap("images")
        var finalChapters = ChapterBuilder.build(document)
        let endnotes = EndnoteLinker.link(&finalChapters, folios: FolioMap(pages: pages))
        if endnotes > 0 { log.debug("linked \(endnotes) endnote reference(s)") }
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
                    p.hiddenLayer = extracted.invisibleFraction > 0.5
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

    /// OCR the contents pages that came from a text layer and keep just the bare numbers in
    /// the right-hand half: the page-number column a text layer sometimes drops.
    func contentsPageNumbers(_ doc: PDFDocument, pages: [PageLines]) async -> [Int: [Line]] {
        var out: [Int: [Line]] = [:]
        for p in pages where p.source == .textLayer {
            guard let page = doc.page(at: p.index), let image = PageRenderer.render(page, dpi: 300) else { continue }
            let ocr = await VisionOCR.recognize(image, pageSize: p.size, languages: ["en-US"])
            let numbers = ocr.lines.filter { l in
                l.bbox.minX > 0.55 && (MarginFilter.ocrFolio(l.plainText).allSatisfy(\.isNumber) || ["I", "l"].contains(l.plainText))
                    && !p.lines.contains { $0.bbox.intersects(l.bbox) }
            }
            if !numbers.isEmpty { out[p.index] = numbers }
        }
        return out
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
        let q = lexicon.quality(of: text)
        // A scanner's hidden OCR layer can be excellent (superscript note numbers, italics,
        // small caps; better than re-OCR) or junk. Keep it if it reads like real text, but
        // hold it to a higher bar than a born-digital layer.
        let hidden = page.invisibleFraction > 0.5
        if hidden && !hiddenLayerIsStyled {
            return OCRDecision(ocr: true, quality: nil, reason: "plain hidden OCR layer")
        }
        // (Indexes and bibliographies, full of names and numbers, score low on a dictionary
        // check; a styled professional layer is still the best source for them.)
        let threshold = hidden ? min(options.textQualityThreshold, 0.45) : options.textQualityThreshold
        if q.tokens >= 8 && q.score < threshold {
            let what = hidden ? "hidden OCR layer" : "text layer"
            return OCRDecision(ocr: true, quality: q.score, reason: String(format: "%@ scores %.2f", what, q.score))
        }
        return OCRDecision(ocr: false, quality: q.tokens >= 8 ? q.score : nil, reason: "text layer ok")
    }

    /// Whether the document's invisible OCR layer, if any, carries real typography: several
    /// fonts, with italics or bold. Professional OCR exports do (and mark superscripts and
    /// small caps); Internet Archive-style layers set everything in one plain font, losing
    /// sizes and styles, so Vision rebuilds the structure better.
    static func hiddenLayerIsStyled(_ doc: PDFDocument) -> Bool {
        var fonts = Set<String>()
        var styled = false
        let n = doc.pageCount
        for i in stride(from: 0, to: n, by: max(1, n / 20)) {
            guard let page = doc.page(at: i)?.pageRef else { continue }
            let scan = GlyphScanner.scan(page)
            for g in scan.glyphs where g.invisible {
                let f = scan.fonts[g.font]
                fonts.insert(f.name)
                if f.isItalic || f.isBold { styled = true }
            }
        }
        return fonts.count >= 3 || (styled && fonts.count >= 2)
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
