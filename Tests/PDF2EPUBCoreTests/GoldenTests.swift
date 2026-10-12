import Testing
import Foundation
@testable import PDF2EPUBCore

/// End-to-end checks on the generated fixtures (see Scripts/make-fixtures.swift): the
/// book's text must come out paragraph for paragraph, with no page furniture.
@Suite(.serialized) struct GoldenTests {
    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    struct Expected: Decodable {
        struct Chapter: Decodable {
            var title: String
            var blocks: [ExpectedBlock]
        }
        struct ExpectedBlock: Decodable { var kind: String; var text: String }
        var title: String
        var author: String
        var chapters: [Chapter]
    }

    func expected(_ name: String) throws -> Expected {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).expected.json"))
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    func convert(_ file: String) async throws -> Book {
        var options = ConversionOptions()
        options.profile = .xteink
        let pipeline = Pipeline(options: options, log: Log(verbose: false))
        return try await pipeline.makeBook(input: Self.fixtures.appendingPathComponent(file)).book
    }

    /// Body text blocks as "<i>…</i>" strings, verse lines joined by newlines.
    func bodyTexts(_ book: Book, italics: Bool = true) -> [String] {
        book.chapters.flatMap(\.blocks)
            .filter { [.paragraph, .verse, .blockquote, .listItem].contains($0.kind) }
            .map { b in
                var t = b.text.replacingOccurrences(of: "\u{2003}", with: "")
                t = InlineStyle.balance(t)
                t = t.replacingOccurrences(of: String(InlineStyle.italicOn), with: italics ? "<i>" : "")
                    .replacingOccurrences(of: String(InlineStyle.italicOff), with: italics ? "</i>" : "")
                return InlineStyle.strip(t).trimmingCharacters(in: .whitespaces)
            }
    }

    func expectedTexts(_ e: Expected, italics: Bool = true) -> [String] {
        e.chapters.flatMap(\.blocks).map { italics ? $0.text : $0.text.replacingOccurrences(of: "<i>", with: "").replacingOccurrences(of: "</i>", with: "") }
    }

    /// Fraction of expected blocks reproduced exactly, in order (longest common subsequence).
    func matchRatio(_ want: [String], _ got: [String]) -> Double {
        var d = [[Int]](repeating: [Int](repeating: 0, count: got.count + 1), count: want.count + 1)
        for i in 0..<want.count {
            for j in 0..<got.count {
                d[i + 1][j + 1] = want[i] == got[j] ? d[i][j] + 1 : max(d[i][j + 1], d[i + 1][j])
            }
        }
        return Double(d[want.count][got.count]) / Double(max(want.count, 1))
    }

    func chapterTitles(_ book: Book) -> [String] { book.chapters.map(\.title) }

    @Test func novelBornDigitalIsExact() async throws {
        let book = try await convert("pride.pdf")
        let e = try expected("pride")
        #expect(bodyTexts(book) == expectedTexts(e))
        #expect(book.metadata.title == "Pride and Prejudice")
        #expect(book.metadata.author == "Jane Austen")
        #expect(chapterTitles(book).suffix(3) == ["CHAPTER I", "CHAPTER II", "CHAPTER III"])
    }

    @Test func verseBornDigitalIsExact() async throws {
        let book = try await convert("iliad.pdf")
        #expect(bodyTexts(book) == expectedTexts(try expected("iliad")))
        let verse = book.chapters.flatMap(\.blocks).filter { $0.kind == .verse }
        #expect(verse.count == 14)
    }

    @Test(arguments: [("pride-scan.pdf", "pride", 0.88), ("pride-junk.pdf", "pride", 0.82), ("iliad-scan.pdf", "iliad", 0.5)])
    func scannedBooks(file: String, name: String, minRatio: Double) async throws {
        let book = try await convert(file)
        let got = bodyTexts(book, italics: false)
        let ratio = matchRatio(expectedTexts(try expected(name), italics: false), got)
        #expect(ratio >= minRatio, "only \(Int(ratio * 100))% of blocks matched")
        // No running heads or folios leaked into the text.
        #expect(!got.contains { $0.allSatisfy(\.isNumber) })
        #expect(!got.contains { $0 == "PRIDE AND PREJUDICE" && $0 != got.first })
    }

    @Test func xhtmlUsesOnlyTheAllowedSubset() async throws {
        let book = try await convert("pride.pdf")
        let (data, _) = EPUBWriter.package(book, profile: .xteink)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let epub = dir.appendingPathComponent("book.epub")
        try data.write(to: epub)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", epub.path, "-d", dir.appendingPathComponent("x").path]
        try unzip.run()
        unzip.waitUntilExit()

        let allowed: Set<String> = ["html", "head", "body", "title", "meta", "link", "section", "div", "p", "span",
                                    "h1", "h2", "h3", "h4", "h5", "h6", "b", "strong", "i", "em", "u", "s", "sub", "sup",
                                    "small", "br", "hr", "blockquote", "ul", "ol", "li", "a", "img", "figure", "figcaption",
                                    "table", "tr", "td", "th", "nav"]
        let text = dir.appendingPathComponent("x/OEBPS/text")
        let files = try FileManager.default.contentsOfDirectory(at: text, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for f in files {
            let collector = ElementCollector()
            let parser = XMLParser(contentsOf: f)!
            parser.delegate = collector
            #expect(parser.parse(), "\(f.lastPathComponent) is not well-formed: \(parser.parserError.map { "\($0)" } ?? "")")
            #expect(collector.elements.isSubset(of: allowed), "\(f.lastPathComponent) uses \(collector.elements.subtracting(allowed))")
            let size = try Data(contentsOf: f).count
            #expect(size <= 64 * 1024)
        }
        let css = try String(contentsOf: dir.appendingPathComponent("x/OEBPS/style.css"), encoding: .utf8)
        #expect(css.utf8.count < 2048)
    }
}

final class ElementCollector: NSObject, XMLParserDelegate {
    var elements = Set<String>()
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        elements.insert(name)
    }
}
