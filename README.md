# pdf2epub

Turns PDF books and articles, born-digital or scanned, into clean, reflowable EPUBs for small
e-ink readers. It's one native macOS binary with no Homebrew, Python, or model downloads, and
it runs in Finder as a right-click Quick Action.

It uses only Apple frameworks: PDFKit and CoreGraphics to read PDFs, Vision for OCR, and
Foundation Models for an optional on-device proofreading pass.

**Requirements:** macOS 26 or later on Apple Silicon. Apple Intelligence is optional. Without
it, the proofreading pass is skipped and everything else works the same.

## Install

**For readers:** run `Scripts/package.sh` and share `dist/PDF-to-EPUB.zip`. The person
unzips it and double-clicks **Install.command**, then right-clicks a PDF and chooses
*Quick Actions → Convert to EPUB*. The EPUB appears next to the PDF, followed by a
notification. If macOS blocks the installer the first time, right-click it and choose
*Open*. The binary is signed ad hoc, not notarized.

**For development:** `Scripts/install.sh` builds the tool, installs it to `~/bin`, and
installs the Quick Action into `~/Library/Services`.

## Usage

```bash
pdf2epub book.pdf                       # writes book.epub next to it
```

```
pdf2epub <input.pdf> [-o output.epub]
         [--profile generic|xteink]     # default: generic
         [--ocr auto|always|never]      # default: auto
         [--no-llm]                     # skip the Foundation Models pass
         [--title "…"] [--author "…"]
         [--verse]                      # keep line breaks in short-line passages
         [--keep-intermediate <dir>]    # per-stage JSON + the model transcript
         [--verbose]
```

Exit status is 0 on success, 1 on failure, and 2 on success with warnings (for example,
low-confidence OCR pages, or passages the model declined to review). Progress
(`page 37/212`) goes to stderr.

Profiles:

- **`xteink`:** for the Xteink X4 on CrossPoint-family firmware. It emits a restricted
  XHTML subset, a CSS file under 2 KB, chapter files of at most 64 KB, grayscale baseline
  JPEGs no wider than 480 px, and a 480×800 cover.
- **`generic`:** for Kindle, Kobo, Apple Books, and KOReader. Limits are relaxed: color
  images up to 1200 px wide and no file splitting.

## How it works

```
PDF ─► Ingest ─► Layout heuristics ─► LLM review ─► Structure ─► EPUB
       text layer   headers/folios    narrow yes/no    chapters     EPUB 3 + NCX
       or OCR       columns, verse    questions only   footnotes    own zip writer
                    paragraphs, joins                  figures
```

- **Ingest** (`Sources/PDF2EPUBCore/Ingest`): PDFKit's attributed strings report every font
  as "Helvetica", so `GlyphScanner` walks the content stream with `CGPDFScanner` to recover
  each glyph's real font (italic, bold, small caps), size, and position. It then matches them
  to PDFKit's characters. A page is sent to OCR when it has no text layer, when its text
  layer is a scanner's invisible OCR layer, or when its words mostly fail the spell checker.
- **OCR** (`OCR/VisionOCR.swift`): `RecognizeDocumentsRequest`, with `RecognizeTextRequest`
  as a fallback. Tables are cropped as images.
- **Layout** (`Layout/`): running heads and folios (by repetition, position, and page-number
  sequence); two-column reading order; paragraphs (by indent, gaps, and short last lines);
  verse (capitalized lines, the fill test, alternating indents); headings; footnotes;
  dehyphenation that follows the book's own spelling ("to-day" stays if the book writes
  it); and joins across page breaks.
- **LLM review** (`Cleanup/`): only for the cases the heuristics flag. See below.
- **Structure and EPUB** (`Structure/`, `EPUB/`): chapters come from the PDF outline, or
  from detected headings when there is none. Footnotes become linked endnotes in the same
  file. Figures and captions are paired. Packaging uses its own zip writer, with `mimetype`
  stored first.

### What the day-one spikes found (spec §8)

1. **Foundation Models works from a plain CLI binary and from the Quick Action.** No app
   bundle or entitlements are needed.
2. **Guardrails:** the default model refuses violent classical passages (the Iliad). The
   `SystemLanguageModel(guardrails: .permissiveContentTransformations)` mode accepts them,
   **but only for plain String output.** Guided `@Generable` output still refuses, so the
   pass asks for short string answers and parses them itself.
3. **Vision:** `RecognizeDocumentsRequest` text is excellent, but its paragraph grouping
   is unreliable around dialogue, and its line heights vary by about ±30%. OCR'd pages are
   therefore segmented by geometry, and size only counts when the difference is large.
4. **The ~3B model** can't follow a multi-block reply format and likes to "help" by
   modernizing (unnumber'd → unnumbered, ancle → ankle). So every request is one narrow
   question:
   - "fix this suspicious word"
   - "does B continue A's paragraph?"
   - "heading, text or junk?"

   A spelling change is accepted only if it turns a non-word into a word *through a typical
   OCR confusion* (rn↔m, c↔e, a dropped i). Elisions and ligatures are never removed. With
   these rules, the pass is never worse than heuristics alone on the test fixtures.

## Development

```bash
swift build -c release
swift test
```

If `xcode-select` points at an older Command Line Tools install, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The Scripts do this
automatically.

- **Fixtures:** `Scripts/make-fixtures.swift` typesets public-domain excerpts from
  `Tests/PDF2EPUBCoreTests/Fixtures/sources` (Pride and Prejudice, Pope's Iliad) into
  book-like PDFs. These have running heads, folios, hyphenation, italics, and verse with
  turnovers. It also makes scanned and junk-OCR-layer variants, plus the expected text.
  The golden tests require exact paragraph-for-paragraph output on the born-digital PDFs,
  and a minimum match ratio on the scans.
- **epubcheck** (Java, development only):
  `java -jar epubcheck.jar book.epub`. Every corpus book currently passes with 0 errors and
  0 warnings.
- **Debugging:**
  - `--keep-intermediate dir` writes `blocks-heuristic.json`, `blocks-cleaned.json`,
    `chapters.json`, and `llm-transcript.txt`.
  - `--dump-page N [--ocr always]` prints one page's extracted lines with geometry and
    styles.
  - `PDF2EPUB_DEBUG_VERSE=1` prints the verse-detection statistics for each region.

## Known limits and next steps

- Math-heavy pages: inline fractions and equations come out as approximate text (a
  non-goal in the spec).
- OCR can't see italics, and names that lost their diacritics (Chryseïs → Chryseis) aren't
  restored. That's deliberate: no fix is safer than an invented one.
- Front and back matter from library scans (stamps, bookplates, publisher ads) can survive
  as short junk chapters.
- Not yet tested on the X4 itself (spec §8.4). Tune the chapter size cap, image sizes, and
  CSS on the device.
# pdf2epub
