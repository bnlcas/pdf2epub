import Foundation

/// Output constraints for a class of reading device.
///
/// To add a device: add a `static let` below and list it in `all`. That's it; the CLI's
/// `--profile` accepts its `name` automatically.
public struct Profile: Sendable {
    public var name: String
    /// One line for `--help`.
    public var summary: String
    /// Maximum XHTML bytes per spine file; chapters beyond this split at paragraph boundaries.
    public var maxChapterBytes: Int?
    public var maxImageWidth: Int
    public var grayscaleImages: Bool
    public var jpegQuality: Double
    /// Figures are re-encoded at lower quality until they fit (best effort).
    public var maxImageBytes: Int
    public var coverSize: (width: Int, height: Int)
    public var css: String

    /// Xteink X4 (ESP32-C3, ~380 KB RAM, 480×800 4-level grayscale) on CrossPoint-family firmware.
    public static let xteink = Profile(
        name: "xteink",
        summary: "Xteink X4 and other tiny-memory e-ink readers",
        maxChapterBytes: 64 * 1024,
        maxImageWidth: 480,
        grayscaleImages: true,
        jpegQuality: 0.75,
        maxImageBytes: 100_000,
        coverSize: (480, 800),
        css: """
        body{margin:0;padding:0}
        p{margin:0;text-indent:1.2em;text-align:justify}
        p.first,p.noindent{text-indent:0}
        p.center{text-align:center;text-indent:0}
        h1,h2,h3,h4{text-align:center;font-weight:bold;text-indent:0;margin:1em 0 0.8em}
        h1{font-size:1.4em;page-break-before:always}
        h2{font-size:1.2em}
        h3,h4{font-size:1em}
        div.stanza{margin:0.8em 0 0.8em 1.2em;text-align:left;text-indent:0}
        blockquote{margin:0.8em 1.2em}
        blockquote p{text-indent:0}
        figure{margin:1em 0;text-align:center}
        img{max-width:100%}
        figcaption,p.caption{font-size:0.9em;font-style:italic;text-align:center;text-indent:0;margin:0.3em 0 0.8em}
        ul,ol{margin:0.5em 0 0.5em 1.2em}
        ul.toc{list-style:none;margin-left:0}
        ul.toc li{margin-bottom:0.5em}
        li{text-indent:0}
        hr{margin:1em 25%}
        div.notes{margin-top:1.5em;font-size:0.85em}
        div.notes p{text-indent:0;margin:0 0 0.4em}
        div.cover{text-align:center}

        """)

    /// Kindle (Send to Kindle), Kobo, Apple Books, KOReader.
    public static let generic = Profile(
        name: "generic",
        summary: "Kindle, Kobo, Apple Books, KOReader",
        maxChapterBytes: nil,
        maxImageWidth: 1200,
        grayscaleImages: false,
        jpegQuality: 0.85,
        maxImageBytes: 400_000,
        coverSize: (1200, 1800),
        css: """
        body{margin:0 1%;padding:0}
        p{margin:0;text-indent:1.3em;text-align:justify;line-height:1.35}
        p.first,p.noindent{text-indent:0}
        p.center{text-align:center;text-indent:0}
        h1,h2,h3,h4{text-align:center;font-weight:bold;text-indent:0;margin:1.2em 0 0.9em;line-height:1.25}
        h1{font-size:1.5em;page-break-before:always}
        h2{font-size:1.25em}
        h3{font-size:1.1em}
        h4{font-size:1em}
        div.stanza{margin:1em 0 1em 1.5em;text-align:left;text-indent:0;line-height:1.35}
        blockquote{margin:1em 1.5em}
        blockquote p{text-indent:0}
        figure{margin:1.2em 0;text-align:center}
        img{max-width:100%}
        figcaption,p.caption{font-size:0.9em;font-style:italic;text-align:center;text-indent:0;margin:0.4em 0 1em}
        ul,ol{margin:0.6em 0 0.6em 1.5em}
        ul.toc{list-style:none;margin-left:0}
        ul.toc li{margin-bottom:0.6em}
        li{text-indent:0;margin-bottom:0.2em}
        hr{margin:1.2em 25%}
        div.notes{margin-top:2em;font-size:0.88em}
        div.notes p{text-indent:0;margin:0 0 0.5em}
        a{text-decoration:none}
        div.cover{text-align:center}

        """)

    /// Every profile `--profile` accepts. The first is the default.
    public static let all: [Profile] = [.generic, .xteink]

    public static func named(_ name: String) -> Profile? {
        let n = name.lowercased()
        if n == "x4" { return .xteink }
        return all.first { $0.name == n }
    }
}
