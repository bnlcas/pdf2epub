# pdf2epub

Convert PDFs into clean reflowable EPUBs on macOS.
Built with Apple's PDFKit, Vision and Foundation Models to scan, format and clean up PDFs and turn them into EPUB files. Works on scans and transcriptions.

Just want to convert some books? Follow the [Quick start](#quick-start) below. No Terminal
needed. Developers can [build from source](#build-from-source).

**Requirements:** macOS 26 or later on Apple Silicon. Apple Intelligence is optional. Apple's foundation model is used for a proofreading/formatting pass. Should run fine without this.

## Quick start

1. **Download** the latest `PDF-to-EPUB-<version>.pkg` from the
   [Releases page](https://github.com/bnlcas/pdf2epub/releases/latest) (under *Assets*).
2. **Install:** double-click the `.pkg` and click through the installer. It asks for your
   Mac's password because it installs a small command-line tool for all users.
3. **Turn on the Quick Action (first time only).** macOS adds new Quick Actions to Finder's
   right-click menu, but sometimes leaves them switched off. To check:
   - In Finder, right-click (or Control-click) any PDF and open the **Quick Actions** submenu.
   - If **Convert to EPUB** is listed, you're done.
   - If not, choose **Customize…** at the bottom of that submenu, tick **Convert to EPUB**
     under Finder, and close System Settings. (The same list is in System Settings →
     General → Login Items & Extensions → Extensions → Finder.)
   <!-- TODO screenshot: Quick Actions → Customize… with "Convert to EPUB" ticked -->
4. **Convert:** right-click a PDF → **Quick Actions → Convert to EPUB**. You can select
   several PDFs at once. A notification appears when each book is done, and the `.epub` is
   saved next to the original PDF.
5. **Allow permissions on first use.** The first time you convert, macOS may ask whether to
   allow access to the folder the PDF is in (Desktop, Documents, Downloads…) or to show
   notifications. Click **Allow**, or the conversion can't read the PDF or tell you it
   finished.

Good to know:

- Big scanned books can take a few minutes. Born-digital PDFs are usually quick.
- The Quick Action only appears when PDFs are selected.
- Quick Actions are a built-in macOS feature, so they also show up in Finder's preview pane
  and in the *Services* menu.
- The installer also adds the `pdf2epub` command for Terminal users. See [Usage](#usage) for
  its options.
- **Uninstall:** run `Scripts/uninstall.sh` (also handy to clean up before reinstalling).
  It removes `/usr/local/bin/pdf2epub`, `~/bin/pdf2epub`, `/Library/Application Support/PDF
  to EPUB`, `~/Library/Services/Convert to EPUB.workflow`, and the installer's receipt.

## Build from source

Requires Xcode (or its Command Line Tools) with the macOS 26 SDK. See
[Development](#development) for tests and debugging.

**Install for yourself:** `Scripts/install.sh` builds the tool, installs it to `~/bin`, and
installs the Quick Action into `~/Library/Services`. Then enable the Quick Action as in step 3
of the [Quick start](#quick-start).

**Making a release:** `Scripts/release.sh` builds, signs (Developer ID, hardened runtime),
packages, notarizes, and staples `dist/PDF-to-EPUB-<version>.pkg`. The version comes from
`pdf2epub --version`. One-time setup: create *Developer ID Application* and *Developer ID
Installer* certificates (Xcode → Settings → Accounts → Manage Certificates), then store
notarization credentials with
`xcrun notarytool store-credentials pdf2epub-notary --apple-id <you> --team-id <TEAMID>`,
using an app-specific password from appleid.apple.com.

**Without a Developer ID:** run `Scripts/package.sh` and share `dist/PDF-to-EPUB.zip`. The person
unzips it and double-clicks **Install.command**, then right-clicks a PDF and chooses
*Quick Actions → Convert to EPUB*. The EPUB appears next to the PDF, followed by a
notification. The binary is signed ad hoc, not notarized, so if it was downloaded macOS
blocks it the first time: open System Settings → Privacy & Security and click
*Open Anyway*.

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
         [--progress-window]            # a progress bar window (the Quick Action uses it)
         [--verbose]
```

Exit status is 0 on success, 1 on failure, and 2 on success with warnings (for example,
low-confidence OCR pages, or passages the model declined to review). Progress
(`page 37/212`) goes to stderr, or to a small window with `--progress-window`.

When the PDF has no title or author, they come from a download-style file name
(`Title _ Subtitle -- Last, First_.pdf`) or from the title page.

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
  to PDFKit's characters. A scanner's invisible OCR layer is kept when it carries real
  typography (several fonts, italics: professional OCR, which also marks superscript note
  numbers) and reads well. A page goes to Vision OCR when it has no text layer, a plain
  single-font hidden layer (Internet Archive style), or text that mostly fails the spell
  checker.
- **OCR** (`OCR/VisionOCR.swift`): `RecognizeDocumentsRequest`, with `RecognizeTextRequest`
  as a fallback, pinned to the book's language (auto-detection turns old-style numerals into
  Cyrillic). Tables are cropped as images. OCR'd text then gets deterministic repairs
  (`Cleanup/`): small caps read as mixed case (SeTTLeMENTS → SETTLEMENTS), Cyrillic
  look-alikes, fullwidth punctuation, and glyph mis-mappings learned from the book itself
  (one layer's italic "k" came out as "\").
- **Layout** (`Layout/`): running heads and folios (by repetition, position, and page-number
  sequence); two-column reading order; paragraphs (by indent, gaps, and short last lines);
  verse (capitalized lines, the fill test, alternating indents); headings; footnotes;
  dehyphenation that follows the book's own spelling ("to-day" stays if the book writes
  it); and joins across page breaks.
- **LLM review** (`Cleanup/`): only for the cases the heuristics flag. See below.
- **Structure and EPUB** (`Structure/`, `EPUB/`): chapters come from the PDF outline; else
  from the book's printed Contents page, placed through the printed page numbers (this
  works even when chapter titles are display art); else from detected headings. Footnotes
  become linked notes in the same file; references to a Notes chapter link to the right
  endnote and back. Figures and captions are paired. Packaging uses its own zip writer, with `mimetype`
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
   OCR confusion* (rn↔m, tl↔d, c↔e). Digits, elisions, diacritics and ligatures are never
   removed, and names are left alone. With these rules, the pass is never worse than
   heuristics alone on the test fixtures. It asks at most 400 questions per book.

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

## Et Cetera:
Claude Opus 5.5 made all of this. I take no credit beyond the initial desire and some busy work to bundle it up. It's MIT license so I also take no legal responsibility. I found this to be a useful tool. Hopefully this tool will be useful to you.
