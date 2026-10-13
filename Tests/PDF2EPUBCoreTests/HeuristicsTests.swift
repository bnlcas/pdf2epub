import Testing
import Foundation
import CoreGraphics
@testable import PDF2EPUBCore

let I = InlineStyle.self

func context(_ hyphenated: Set<String> = [], words: Set<String> = []) -> LayoutContext {
    LayoutContext(bodySize: [.textLayer: 11], lexicon: Lexicon(), hyphenatedWords: hyphenated, knownWords: words)
}

@Suite struct InlineStyleTests {
    @Test func tidyMergesAdjacentSpans() {
        let s = "\(I.italicOn)a\(I.italicOff) \(I.italicOn)b\(I.italicOff)"
        #expect(InlineStyle.tidy(s) == "\(I.italicOn)a b\(I.italicOff)")
    }

    @Test func balanceClosesAndDropsStrays() {
        #expect(InlineStyle.balance("\(I.italicOn)open") == "\(I.italicOn)open\(I.italicOff)")
        #expect(InlineStyle.balance("stray\(I.italicOff) close") == "stray close")
    }
}

@Suite struct NormalizerTests {
    @Test func ligaturesAndAccents() {
        #expect(Normalizer.normalize("e\u{FB03}cient \u{FB01}sh") == "efficient fish")
        #expect(Normalizer.normalize("Poincar\u{00B4}e") == "Poincaré")
        #expect(Normalizer.normalize("soft\u{00AD}hyphen") == "softhyphen")
        #expect(Normalizer.normalize("a  b\u{00A0}c") == "a b c")
    }
}

@Suite struct HyphenationTests {
    let ctx = context()

    @Test func joinsSplitWords() {
        #expect(TextJoiner.join("of the mathemati-", "cal attainments", context: ctx).text == "of the mathematical attainments")
    }

    @Test func keepsRealCompounds() {
        #expect(TextJoiner.join("the land-", "surveying of", context: ctx).text == "the land-surveying of")
    }

    @Test func keepsHyphenBeforeCapital() {
        #expect(TextJoiner.join("the Anglo-", "Saxon kings", context: ctx).text == "the Anglo-Saxon kings")
    }

    @Test func digitHyphen() {
        #expect(TextJoiner.join("our 152-", "layer net", context: ctx).text == "our 152-layer net")
    }

    @Test func typewriterDash() {
        #expect(TextJoiner.join("he wished--", "that of", context: ctx).text == "he wished--that of")
    }

    @Test func followsTheBooksOwnSpelling() {
        let ctx = context(["to-day"])
        #expect(TextJoiner.join("It is to-", "day we go", context: ctx).text == "It is to-day we go")
        let modern = context(words: ["today"])
        #expect(TextJoiner.join("It is to-", "day we go", context: modern).text == "It is today we go")
    }

    @Test func italicsSurviveJoins() {
        let a = "a \(I.italicOn)Short History of Greek Math-\(I.italicOff)"
        let b = "\(I.italicOn)ematics\(I.italicOff), by J. Gow"
        #expect(TextJoiner.join(a, b, context: ctx).text == "a \(I.italicOn)Short History of Greek Mathematics\(I.italicOff), by J. Gow")
    }
}

@Suite struct MarginFilterTests {
    func page(_ index: Int, _ lines: [(String, Double)]) -> PageLines {
        PageLines(index: index, size: CGSize(width: 400, height: 600), source: .textLayer,
                  lines: lines.map { Line(text: $0.0, bbox: CGRect(x: 0.15, y: $0.1, width: 0.7, height: 0.02), fontSize: 10) })
    }

    @Test func removesHeadersAndFolios() {
        var pages = (0..<6).map { i in
            page(i, [(i % 2 == 0 ? "PRIDE AND PREJUDICE" : "CHAPTER III.", 0.05),
                     ("Body text line one on page \(i).", 0.2), ("More body text here.", 0.5),
                     ("\(i + 10)", 0.95)])
        }
        MarginFilter.apply(&pages)
        for p in pages {
            #expect(p.lines.map(\.text) == ["Body text line one on page \(p.index).", "More body text here."])
        }
    }

    @Test func keepsLargeChapterHeadingMatchingRunningHead() {
        var pages = (0..<6).map { i in page(i, [("CHAPTER I.", 0.05), ("Body \(i)", 0.3)]) }
        pages[0].lines[0] = Line(text: "CHAPTER I.", bbox: CGRect(x: 0.4, y: 0.11, width: 0.2, height: 0.03), fontSize: 16)
        MarginFilter.apply(&pages, bodySize: [.textLayer: 10])
        #expect(pages[0].lines.first?.text == "CHAPTER I.")
        #expect(pages[1].lines.first?.text == "Body 1")
    }

    @Test func pageNumberShapes() {
        #expect(MarginFilter.isPageNumber("12"))
        #expect(MarginFilter.isPageNumber("— 7 —"))
        #expect(MarginFilter.isPageNumber("xiv"))
        #expect(!MarginFilter.isPageNumber("CHAPTER"))
    }
}

@Suite struct PatternTests {
    @Test func chapterHeadings() {
        #expect(BlockClassifier.isChapterHeading("CHAPTER I."))
        #expect(BlockClassifier.isChapterHeading("Chapter 12: The Return"))
        #expect(BlockClassifier.isChapterHeading("BOOK THE FIRST"))
        #expect(BlockClassifier.isChapterHeading("Canto XXIV"))
        #expect(!BlockClassifier.isChapterHeading("Chapter and verse were quoted at length by the vicar."))
    }

    @Test func captions() {
        #expect(BlockClassifier.isCaption("Figure 2. Residual learning: a building block."))
        #expect(BlockClassifier.isCaption("Fig. 3: The apparatus"))
        #expect(!BlockClassifier.isCaption("Figures of speech abound."))
    }

    @Test func footnoteMarkers() {
        #expect(BlockBuilder.footnoteMarker("\(I.supOn)1\(I.supOff)See Cantor, chap. i") == "1")
        #expect(BlockBuilder.footnoteMarker("* Written in 1820.") == "*")
        #expect(BlockBuilder.footnoteMarker("12. Ibid.") == "12")
        #expect(BlockBuilder.footnoteMarker("1914 was a year") == nil)
    }

    @Test func tocLeaders() {
        #expect(TOCEntry.hasLeader("Greek indebtedness to Egyptians . . . . . 17"))
        #expect(TOCEntry.strip("Greek indebtedness to Egyptians . . . . . 17") == "Greek indebtedness to Egyptians")
        #expect(!TOCEntry.hasLeader("He paused... and went on."))
    }

    @Test func sentenceEnds() {
        #expect(TextMetrics.endsSentence("the end.”"))
        #expect(TextMetrics.endsSentence("a papyrus.12"))
        #expect(!TextMetrics.endsSentence("and the"))
    }
}

@Suite struct SmartQuoteTests {
    @Test func curlsQuotes() {
        #expect(SmartQuotes.apply("\"Yes,\" she said, \"it's mine.\"") == "“Yes,” she said, “it’s mine.”")
        #expect(SmartQuotes.apply("'Tis time") == "’Tis time")
        #expect(SmartQuotes.apply("spare, “Tis time") == "spare, ’Tis time")
        #expect(SmartQuotes.apply("pray’d:-the power") == "pray’d:—the power")
    }
}

@Suite struct TextPatchTests {
    @Test func keepsStyleMarkers() {
        let marked = "He \(I.italicOn)tumed\(I.italicOff) away"
        #expect(TextPatch.apply(to: marked, newPlain: "He turned away") == "He \(I.italicOn)turned\(I.italicOff) away")
    }

    @Test func insertionsAndDeletions() {
        #expect(TextPatch.apply(to: "return d, and", newPlain: "return’d, and") == "return’d, and")
    }
}

@Suite struct FootnoteLinkTests {
    @Test func linksAndMovesNotes() {
        var blocks = [
            Block(page: 3, bbox: .zero, kind: .paragraph, text: "A papyrus,\(I.supOn)1\(I.supOff) forming part."),
            Block(page: 3, bbox: .zero, kind: .paragraph, text: "Next paragraph."),
            Block(page: 3, bbox: .zero, kind: .footnote, text: "See Eisenlohr.", footnoteMarker: "1"),
        ]
        FootnoteLinker.link(&blocks)
        #expect(blocks.map(\.kind) == [.paragraph, .footnote, .paragraph])
        #expect(blocks[0].noteRefs == ["1": 1])
        #expect(blocks[1].noteID == 1)
    }

    @Test func ocrDigitsBecomeReferences() {
        var blocks = [
            Block(page: 0, bbox: .zero, kind: .paragraph, text: "a hieratic papyrus,1 forming part", source: .ocr),
            Block(page: 0, bbox: .zero, kind: .footnote, text: "See Eisenlohr.", footnoteMarker: "1", source: .ocr),
        ]
        FootnoteLinker.link(&blocks)
        #expect(blocks[0].text.contains("\(I.supOn)1\(I.supOff)"))
        #expect(blocks[1].noteID == 1)
    }
}

@Suite struct ZipTests {
    @Test func epubZipIsValid() throws {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("OEBPS/a.txt", String(repeating: "hello world ", count: 200))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.zip")
        try zip.finish().write(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // mimetype first, stored, at offset 30 as readers expect.
        let data = try Data(contentsOf: url)
        #expect(String(data: data[30..<38], encoding: .ascii) == "mimetype")
        #expect(String(data: data[38..<58], encoding: .ascii) == "application/epub+zip")
    }
}

@Suite struct OCRRepairTests {
    let suspects = OCRSuspects(lexicon: Lexicon(), lines: [])

    @Test func splitsRunTogetherWords() {
        #expect(suspects.splitRunTogetherWords("went ofany kind") == "went of any kind")
        // "hislay" could be "his lay" or "hi slay": ambiguous, left for the model.
        #expect(suspects.splitRunTogetherWords("hislay") == "hislay")
        #expect(suspects.splitRunTogetherWords("Netherfield Chryseis wept") == "Netherfield Chryseis wept")
    }

    @Test func flagsMisreads() {
        #expect(suspects.suspects(in: "The trembling priest along the shore return d,") == ["return d,"])
        #expect(suspects.suspects(in: "Of woes unnumber’d, heavenly goddess, sing!").isEmpty)
    }

    @Test func rejectsModernization() {
        let cleaner = OCRFixer(suspects: suspects)
        #expect(cleaner.validFix(original: "unnumber’d", answer: "unnumbered") == nil)
        #expect(cleaner.validFix(original: "favouring", answer: "favoring") == nil)
        #expect(cleaner.validFix(original: "Clytæmnestra’s", answer: "Clytemnestra’s") == nil)
        #expect(cleaner.validFix(original: "return d,", answer: "return'd,") == "return’d,")
        #expect(cleaner.validFix(original: "tumed", answer: "turned") == "turned")
        #expect(cleaner.validFix(original: "ancle", answer: "ankle") == nil)
        #expect(cleaner.validFix(original: "assem bly", answer: "as-assembly") == nil)
        #expect(cleaner.validFix(original: "assem bly", answer: "assembly") == "assembly")
        #expect(cleaner.validFix(original: "Setdements", answer: "Settlements") == "Settlements")
        #expect(cleaner.validFix(original: "Setdements", answer: "Set-dements") == nil)
        #expect(cleaner.validFix(original: "Peroz", answer: "Perez") == nil)
        #expect(cleaner.validFix(original: "Caius", answer: "Cains") == nil)
        #expect(cleaner.validFix(original: "Yüan", answer: "Yuan") == nil)
        #expect(cleaner.validFix(original: "covcred", answer: "covered") == "covered")
        #expect(cleaner.validFix(original: "care.147", answer: "care.") == nil)
        #expect(cleaner.validFix(original: "it.21", answer: "It.21") == nil)
    }
}

@Suite struct GlyphSubstitutionTests {
    @Test func learnsAMisMappedGlyph() {
        let texts = ["purple, sil\\ and scarlet", "all \\inds of scented wood", "a ban\\ of the river", "the \\ing and his court", "Bhallata\\a"]
        let lines = texts.map { Line(text: $0, bbox: .zero, fontSize: 10) }
        let map = GlyphSubstitution.infer(lines, lexicon: Lexicon())
        #expect(map["\\"] == "k")
        #expect(GlyphSubstitution.apply(map, to: "sil\\ and all \\inds") == "silk and all kinds")
    }
}

@Suite struct OCRTextRepairTests {
    let lex = Lexicon()

    @Test func smallCapsMixedCase() {
        #expect(OCRTextRepair.fixSmallCaps("FOREIGN SeTTLeMENTS IN T’ANG", lexicon: lex) == "FOREIGN SETTLEMENTS IN T’ANG")
        #expect(OCRTextRepair.fixSmallCaps("PARroTs and DEERsKIns", lexicon: lex) == "PARROTS and DEERSKINS")
        #expect(OCRTextRepair.fixSmallCaps("quoted in ChTS, han 9", lexicon: lex) == "quoted in ChTS, han 9")
        #expect(OCRTextRepair.fixSmallCaps("Settlements of McDonald", lexicon: lex) == "Settlements of McDonald")
    }

    @Test func cyrillicLookalikes() {
        #expect(OCRTextRepair.fixScripts("Mu AD. 1596 (193б); and") == "Mu AD. 1596 (1936); and")
        #expect(OCRTextRepair.fixScripts("cost 10з.") == "cost 103.")
        #expect(OCRTextRepair.fixScripts("Москва") == "Москва")
    }

    @Test func fullwidthPunctuation() {
        #expect(OCRTextRepair.fixFullwidth("Lionel Giles （1932），825") == "Lionel Giles (1932), 825")
        #expect(OCRTextRepair.fixFullwidth("Tu Fu杜甫，Chiu") == "Tu Fu杜甫，Chiu")
    }
}

@Suite struct MetadataTests {
    @Test func downloadFileNames() {
        let m = MetadataGuesser.fromFilename(URL(fileURLWithPath: "/x/The Golden Peaches of Samarkand _ A Study of T'ang Exotics -- Schafer, Edward H_.pdf"))
        #expect(m.title == "The Golden Peaches of Samarkand: A Study of T'ang Exotics")
        #expect(m.author == "Edward H. Schafer")
        #expect(MetadataGuesser.fromFilename(URL(fileURLWithPath: "/x/golden-peaches.pdf")).title == nil)
    }

    @Test func titleCasing() {
        #expect(MetadataGuesser.titleCase("THE GOLDEN PEACHES OF SAMARKAND") == "The Golden Peaches of Samarkand")
        #expect(MetadataGuesser.titleCase("EDWARD H. SCHAFER") == "Edward H. Schafer")
        #expect(MetadataGuesser.titleCase("Pride and Prejudice") == "Pride and Prejudice")
    }
}

@Suite struct ContentsAndListsTests {
    @Test func romanNumeralsAsOCRReadsThem() {
        #expect(PrintedContents.romanValue("HI") == 3)
        #expect(PrintedContents.romanValue("vi") == 6)
        #expect(PrintedContents.romanValue("ix") == 9)
        #expect(PrintedContents.romanValue("Il") == 2)
        #expect(PrintedContents.romanValue("XL") == 40)
        #expect(PrintedContents.romanValue("Men") == nil)
        #expect(PrintedContents.roman(14) == "XIV")
        #expect(PrintedContents.splitNumeral("HI Domestic Animals").numeral == "HI")
        #expect(PrintedContents.splitNumeral("v i Furs and Feathers").title == "Furs and Feathers")
    }

    @Test func folioMapSkipsStrayNumbersAndRespectsGaps() {
        func page(_ i: Int, _ folio: String?) -> PageLines {
            var p = PageLines(index: i, size: .zero, source: .textLayer, lines: [])
            if let folio { p.furniture = [(Line(text: folio, bbox: .zero, fontSize: 9), .pageNumber)] }
            return p
        }
        // Pages 10–20 print 1–11, except a stray "1644" on page 5 and a plate at 15.
        var pages = (0..<25).map { page($0, nil) }
        pages[5] = page(5, "1644")
        for i in 10...20 where i != 15 { pages[i] = page(i, String(i < 15 ? i - 9 : i - 10)) }
        let map = FolioMap(pages: pages)
        #expect(!map.folios.contains { $0.number == 1644 })
        #expect(map.index(ofPrinted: 3) == 12)
        #expect(map.index(ofPrinted: 7) == 17)     // after the unnumbered plate
    }

    @Test func numberedParagraphsBecomeAnOrderedList() {
        var blocks = ["Some intro text that runs on.", "1. Gather the pages.", "2. Read the text layer.", "3. Write the book.", "After the list."]
            .map { Block(page: 0, bbox: .zero, kind: .paragraph, text: $0) }
        BlockClassifier.markNumberedLists(&blocks)
        #expect(blocks.map(\.kind) == [.paragraph, .listItem, .listItem, .listItem, .paragraph])
        #expect(blocks[2].listOrdinal == 2)
        #expect(blocks[2].text == "Read the text layer.")
    }

    @Test func runInHeading() {
        let line = Line(text: "Poetry", bbox: CGRect(x: 0.2, y: 0.1, width: 0.05, height: 0.02), fontSize: 10)
        let heading = Block(page: 0, bbox: line.bbox, kind: .paragraph, text: "Poetry", lines: [line])
        let body = Block(page: 0, bbox: .zero, kind: .paragraph, text: String(repeating: "In translations of poems I have preferred faithfulness. ", count: 3))
        #expect(BlockClassifier.isRunInHeading(heading, next: body))
        let signoff = Block(page: 0, bbox: line.bbox, kind: .paragraph, text: "Berkeley, California", lines: [line])
        #expect(!BlockClassifier.isRunInHeading(signoff, next: body))
    }
}
