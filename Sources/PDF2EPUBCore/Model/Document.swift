import Foundation
import CoreGraphics

/// What a block of text is, structurally.
public enum BlockKind: Codable, Hashable, Sendable {
    case paragraph
    case heading(Int)
    case listItem
    case blockquote
    case verse
    case footnote
    case caption
    case figure
    case runningHeader
    case runningFooter
    case pageNumber
    case unknown

    /// Blocks that are page furniture rather than book content.
    public var isFurniture: Bool {
        switch self {
        case .runningHeader, .runningFooter, .pageNumber: return true
        default: return false
        }
    }

    public var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    public var headingLevel: Int? {
        if case .heading(let level) = self { return level }
        return nil
    }

    /// Kinds whose text flows as prose and may continue across page or column breaks.
    public var isFlowing: Bool {
        switch self {
        case .paragraph, .blockquote, .listItem, .unknown: return true
        default: return false
        }
    }
}

public enum TextSource: String, Codable, Sendable {
    case textLayer
    case ocr
}

/// Layout hints and reasons a block could use a second opinion from the language model.
public enum BlockFlag: String, Codable, Hashable, Sendable {
    case ambiguousJoin
    case ambiguousKind
    case ambiguousHyphen
    case lowConfidence
    /// First block of a column or page (a flow break precedes it).
    case startsSegment
    /// The OCR engine marked this text as a title.
    case ocrTitle
    /// An entry from a printed table of contents (leaders and page number removed).
    case tocEntry

    public static let review: Set<BlockFlag> = [.ambiguousJoin, .ambiguousKind, .ambiguousHyphen, .lowConfidence]
}

/// One visual line of text on a page.
public struct Line: Codable, Sendable {
    /// Text with inline style markers (see `InlineStyle`).
    public var text: String
    /// Normalized page coordinates, origin top-left, y grows downward.
    public var bbox: CGRect
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    public var confidence: Double
    /// OCR paragraph this line belonged to, when the recognizer grouped lines itself.
    public var group: Int?
    /// The recognizer flagged this line as a title.
    public var isTitle: Bool

    public init(text: String, bbox: CGRect, fontSize: Double, isBold: Bool = false, isItalic: Bool = false,
                confidence: Double = 1, group: Int? = nil, isTitle: Bool = false) {
        self.text = text
        self.bbox = bbox
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.confidence = confidence
        self.group = group
        self.isTitle = isTitle
    }

    public var plainText: String { InlineStyle.strip(text) }
}

public struct Block: Codable, Sendable {
    public var page: Int
    /// Last page this block's text came from, when it was merged across a page break.
    public var endPage: Int?
    /// Normalized page coordinates, origin top-left.
    public var bbox: CGRect
    public var kind: BlockKind
    /// Text with inline style markers. Verse keeps line breaks as "\n"; prose is joined.
    public var text: String
    public var fontSize: Double?
    public var isBold: Bool
    public var isItalic: Bool
    public var confidence: Double
    /// Paragraph continues from the previous flowing block (split across a page or column).
    public var continuesFromPrevious: Bool
    /// Whether the first line was indented relative to the column (nil if unknown).
    public var firstLineIndented: Bool?
    public var isCentered: Bool
    public var flags: Set<BlockFlag>
    /// For footnotes: the marker that starts the note ("1", "*", …).
    public var footnoteMarker: String?
    /// For figures: path of the extracted image inside the EPUB (set by the image stage).
    public var imageRef: String?
    /// For footnotes: the book-wide note number assigned when linked to a reference.
    public var noteID: Int?
    /// For body text: superscript marker → note number of the footnotes it references.
    public var noteRefs: [String: Int]?
    /// For body text: superscript marker → id of the endnote it references (in a Notes chapter).
    public var endnoteRefs: [String: String]?
    /// For an endnote in a Notes chapter: its id, shared with the reference that cites it.
    public var endnoteAnchor: String?
    /// For an item of a numbered list: its number (the list renders as <ol>).
    public var listOrdinal: Int?
    /// The numbered list counts with letters (a, b, c).
    public var listLettered: Bool?
    /// An id other parts of the book link to (a chapter's opening heading).
    public var anchorID: String?
    /// A link target inside the book, resolved when the EPUB is written ("#@toc-3").
    public var linkTarget: String?
    public var source: TextSource
    /// Source lines, kept for heuristics. Not serialized into the EPUB.
    public var lines: [Line]

    public init(page: Int, bbox: CGRect, kind: BlockKind, text: String, fontSize: Double? = nil,
                isBold: Bool = false, isItalic: Bool = false, confidence: Double = 1,
                continuesFromPrevious: Bool = false, firstLineIndented: Bool? = nil,
                isCentered: Bool = false, flags: Set<BlockFlag> = [], footnoteMarker: String? = nil,
                imageRef: String? = nil, source: TextSource = .textLayer, lines: [Line] = []) {
        self.page = page
        self.bbox = bbox
        self.kind = kind
        self.text = text
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.confidence = confidence
        self.continuesFromPrevious = continuesFromPrevious
        self.firstLineIndented = firstLineIndented
        self.isCentered = isCentered
        self.flags = flags
        self.footnoteMarker = footnoteMarker
        self.imageRef = imageRef
        self.source = source
        self.lines = lines
    }

    public var plainText: String { InlineStyle.strip(text) }

    public var pageRange: ClosedRange<Int> { page...max(page, endPage ?? page) }
}

/// A picture region on a page that should become an image in the book.
public struct FigureRegion: Codable, Sendable {
    public var page: Int
    /// Normalized, origin top-left.
    public var bbox: CGRect
}

public struct PageInfo: Codable, Sendable {
    public var index: Int
    /// Size in PDF points (after rotation).
    public var size: CGSize
    public var source: TextSource
    /// Fraction of text-layer tokens that are dictionary words (nil if no text layer).
    public var textQuality: Double?
    public var lineCount: Int
    public var meanConfidence: Double
}

public struct OutlineEntry: Codable, Sendable {
    public var title: String
    public var level: Int
    public var page: Int
    /// Normalized y of the destination (top-left origin), if known.
    public var y: Double?
    /// Read from the book's printed contents page rather than the PDF's outline.
    public var fromPrintedContents: Bool

    public init(title: String, level: Int, page: Int, y: Double?, fromPrintedContents: Bool = false) {
        self.title = title
        self.level = level
        self.page = page
        self.y = y
        self.fromPrintedContents = fromPrintedContents
    }
}

public struct Metadata: Codable, Sendable {
    public var title: String?
    public var author: String?
    public var language: String?
    public var subject: String?

    public init(title: String? = nil, author: String? = nil, language: String? = nil, subject: String? = nil) {
        self.title = title
        self.author = author
        self.language = language
        self.subject = subject
    }
}

/// The intermediate representation passed between pipeline stages.
public struct Document: Codable, Sendable {
    public var metadata: Metadata
    public var outline: [OutlineEntry]
    public var pages: [PageInfo]
    /// All blocks in reading order.
    public var blocks: [Block]
    public var figures: [FigureRegion]
    /// Median font size of body text, in points.
    public var bodyFontSize: Double

    public init(metadata: Metadata = Metadata(), outline: [OutlineEntry] = [], pages: [PageInfo] = [],
                blocks: [Block] = [], figures: [FigureRegion] = [], bodyFontSize: Double = 10) {
        self.metadata = metadata
        self.outline = outline
        self.pages = pages
        self.blocks = blocks
        self.figures = figures
        self.bodyFontSize = bodyFontSize
    }
}
