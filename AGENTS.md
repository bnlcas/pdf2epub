# AGENTS.md: orientation for contributors and coding agents

pdf2epub turns PDF books (born-digital or scanned) into clean, reflowable EPUBs for e-ink
readers. It is a single native macOS binary that uses only Apple frameworks (PDFKit,
CoreGraphics, Vision, Foundation Models). It ships with a Finder Quick Action so that
people who never open Terminal can use it.

**Who it's for:** readers, not programmers. Every behavior should work from a right-click
in Finder with no setup. The bar is "reads like a publisher made it": real paragraphs,
no running heads or page numbers, no broken words, correct chapters, linked notes, and
the text exactly as printed. Nothing is invented and nothing is modernized.

The original design brief is `pdf2epub-spec.md`. `README.md` is the user-facing doc.

## Build, test, run

```bash
swift build -c release          # .build/release/pdf2epub
swift test                      # unit + golden tests (~10 s)
.build/release/pdf2epub book.pdf -o book.epub -v --keep-intermediate /tmp/dbg
```

- Requires macOS 26 SDK (Xcode 26). If `xcode-select` points at older Command Line Tools,
  prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The
  scripts in `Scripts/` already do this.
- Swift 6.2 tools, **Swift 5 language mode** (deliberate: PDFKit/AppKit types aren't
  Sendable).
- Validate output with **epubcheck** (Java, development only; never a user dependency).
  Every test book should pass with 0 errors and 0 warnings.

## Layout of the repo

```
Sources/pdf2epub/            CLI (ArgumentParser): PDF2EPUB.swift, ProgressWindow.swift
Sources/PDF2EPUBCore/
  Model/       Document.swift (Block/Line/BlockKind/BlockFlag), InlineStyle (markers),
               Lexicon (NSSpellChecker wrapper), TextMetrics
  Ingest/      PDFIngest (metadata, outline), GlyphScanner (CGPDFScanner: real fonts,
               sizes, positions), TextLayerExtractor (PDFKit chars + glyphs → Lines),
               PageRenderer, MetadataGuesser
  OCR/         VisionOCR (RecognizeDocumentsRequest; RecognizeTextRequest fallback)
  Layout/      MarginFilter (running heads, folios), ReadingOrder (columns),
               BlockBuilder (paragraphs, verse, footnotes), BlockClassifier (headings,
               captions, lists), TextJoiner (dehyphenation), FlowJoiner (page-break
               joins), LineMerger, Normalizer, SmartQuotes
  Cleanup/     OCRSuspects, OCRFixer (dictionary-certain fixes + validation of ANY
               text change), OCRTextRepair (small caps, homoglyphs, fullwidth),
               GlyphSubstitution, TextPatch, LLMCleaner (Foundation Models)
  Structure/   ChapterBuilder, PrintedContents (+ FolioMap), FootnoteLinker,
               EndnoteLinker
  Images/      FigureDetector, ImageEncoder
  EPUB/        Profile (device profiles), XHTMLRenderer, EPUBWriter, ZipWriter
  Pipeline/    Pipeline (orchestration), Log (progress), Debug (--dump-page)
Tests/PDF2EPUBCoreTests/     HeuristicsTests, GoldenTests, Fixtures/ (+ sources/)
Scripts/                     install, uninstall, package, release, make-quick-action,
                             make-fixtures, excerpt-pdf
TestCorpus/                  local test books: git-ignored (often copyrighted)
```

## The pipeline (Pipeline.makeBook)

1. **Ingest** each page. Use the text layer unless it is missing, junk (dictionary score
   too low), or a *plain* hidden OCR layer. A *styled* hidden layer (several fonts,
   italics) is professional OCR: keep it, because it marks superscript note numbers and
   is better than re-OCR. Otherwise render at 300 DPI and run Vision (pinned to the book's
   language; auto-detect turns old-style numerals into Cyrillic).
2. **Normalize:** ligatures, accents, split superscripts, glyph substitutions learned per
   book (`\`→`k`), OCR repairs.
3. **Layout:** furniture removal → figures (ink outside text) → reading order → blocks
   → classification → printed-contents rebuild → continuation marking.
4. **Cleanup:** deterministic dictionary fixes (always), then LLM questions (optional).
5. **Structure:** merge continuations → footnote links → chapters (PDF outline → printed
   Contents page → detected headings) → endnote links.
6. **EPUB:** render XHTML (size-capped files per profile), resolve cross-file links
   (`#@id` placeholders), NCX + nav, cover, zip.

`--keep-intermediate dir` dumps the block lists at each stage, the model transcript and
the dictionary fixes. Start any bug investigation there.

## Conventions you must know

- **Inline styles are private-use markers inside strings:** U+E000/E001 italic, E002/E003
  bold, E004/E005 superscript (`InlineStyle`). Every text operation must preserve them.
  Use `plainText`/`InlineStyle.strip` for comparisons, `TextPatch.apply` to apply a
  plain-text edit to marked text, `InlineStyle.stripSuperscripts` when superscripts
  (note numbers) must be ignored.
- **Coordinates** are normalized 0–1 with a **top-left** origin (`PageGeometry`; Vision
  boxes are converted from bottom-left).
- **Page indices** are 0-based PDF pages. Printed page numbers ("folios") are mapped via
  `FolioMap`, which tolerates unnumbered plates and rejects stray numbers.
- `Block.flags` carries layout hints (`startsSegment`, `tocEntry`) and review requests
  (`ambiguousJoin`, `ambiguousKind`, `ambiguousHyphen`, `lowConfidence`).

## Hard-won rules (don't regress these)

- **Never change what the author wrote.** Old spellings, dialect, punctuation and
  diacritics stay. Any text change (model or rule) must pass `OCRFixer.validFix`:
  - digits identical
  - no diacritic, ligature or elision lost
  - no hyphen inserted
  - case only changes for shape-identical letters
  - spelling changes only non-word → word via a real OCR confusion (rn↔m, tl↔d, cl↔d,
    c↔e, i/l/1, 0↔o, h↔b)
  - capitalized words (names) are fixed only via the multi-letter confusions

  The model *will* try "unnumber'd → unnumbered", "ancle → ankle", "Peroz → Perez", and
  deleting note numbers.
- **Foundation Models:** guided generation (`@Generable`) enforces default guardrails,
  which refuse Homer and Ovid. Only plain String output honors
  `.permissiveContentTransformations`. The ~3B model can't follow multi-item formats, so
  every request is one narrow question with a short answer. Questions are skipped when no
  acceptable answer exists, and there's a cap of 400 per book. Any model error keeps the
  heuristic result; a single page must never fail a book.
- **Prefer deterministic fixes over the model** wherever the evidence allows: the
  sequence of numerals, the book's own vocabulary, typography. Use the model only for
  genuinely contextual calls.
- **Vision's paragraph grouping is unreliable**, and its line heights jitter by about
  ±30%. OCR pages are segmented by geometry, and size only counts for big jumps.
- **PDFKit:** `characterBounds(at:)` indexes drift; use `selection(for: NSRange)`.
  Attributed strings report every font as Helvetica, which is why `GlyphScanner` exists.
  `PDFPage.draw` paints link annotations, so turn `displaysAnnotations` off when
  rendering.
- **Swift pitfalls hit here:**
  - In `case .a, .b where cond:` the `where` binds only `.b`.
  - Raw strings containing `"#` need `##"…"##`.
  - An executable target with more than one file can't use `@main` in `main.swift`.
- Keep the XHTML to the subset in `GoldenTests` (the xteink profile depends on it).
  Every id must be unique, and every fragment link must resolve; `EPUBWriter` unlinks
  rather than emit dangling links.

## Testing practice

- Unit tests sit next to each heuristic (`HeuristicsTests.swift`). Add one for every bug
  fixed.
- Golden tests: `pride.pdf` and `iliad.pdf` must reproduce the expected text **exactly**.
  The scanned variants have minimum match ratios. Regenerate fixtures with
  `swift Scripts/make-fixtures.swift` after changing the sources.
- Real books live in `TestCorpus/` (git-ignored). `Scripts/excerpt-pdf.swift` makes
  small excerpts for fast iteration. Note that an excerpt with gaps can't use
  printed-contents chapters, by design.
- After any change to heuristics, re-run a mixed corpus (born-digital book, two-column
  paper, scanned prose, scanned verse, and a styled-hidden-layer scan) and epubcheck it.
  Fixes for one book routinely break another.
- Debug switches: `--dump-page N [--ocr always]`, plus these environment variables:
  - `PDF2EPUB_DEBUG_VERSE`
  - `PDF2EPUB_DEBUG_SUP`
  - `PDF2EPUB_DEBUG_GLYPHS`
  - `PDF2EPUB_DEBUG_NOTES`
  - `PDF2EPUB_DEBUG_CONTENTS`
  - `PDF2EPUB_OCR_LANGS=en-US,zh-Hant`

## Releasing

1. Bump `version:` in `Sources/pdf2epub/PDF2EPUB.swift`.
2. Run `swift test`.
3. Run `Scripts/release.sh`, which builds, signs (Developer ID, hardened runtime),
   packages, notarizes (keychain profile `pdf2epub-notary`) and staples
   `dist/PDF-to-EPUB-<version>.pkg`.
4. Commit and tag `vX.Y.Z`. The maintainer pushes and attaches the `.pkg` to the GitHub
   release.

The package installs `/usr/local/bin/pdf2epub` and copies the Quick Action into the
installing user's `~/Library/Services`. The Quick Action picks a binary that supports
`--progress-window`. `Scripts/uninstall.sh` removes everything.

## Adding a device profile

Add a `static let` to `Profile.swift` (chapter byte cap, image width and size, grayscale,
cover size, CSS) and list it in `Profile.all`. The CLI picks it up automatically.

## Backlog / known limits

- Inline math and stacked fractions come out as approximate text (a non-goal).
- Contents titles keep the text layer's spelling ("The Glory of Tang", missing its
  apostrophe).
- Chapter-opening epigraph credits sometimes render as small headings.
- OCR junk from display lettering on title pages can survive in front matter.
- About 13% of endnote references in heavily-noted scans stay unlinked (OCR-garbled
  numbering).
- The model pass is the slowest stage (about 100 s for 400 questions); its value per
  question is modest.
- macOS 15 support would need: deployment target 15, model pass gated on 26, line OCR
  instead of `RecognizeDocumentsRequest`.
- Not yet tuned on the Xteink X4 hardware itself.
