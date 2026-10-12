# pdf2epub — Project Spec & Hand-off

A native macOS command-line tool that converts PDFs (born-digital and scanned) into clean, reflowable EPUBs for small e-ink readers. Uses only Apple frameworks: PDFKit, Vision, and Foundation Models. Produces a single binary with no runtime dependencies, which can be invoked from Finder via a Quick Action.

## 1. Goals and non-goals

**Goals**
- Turn book-like PDFs (novels, classics, essays, non-fiction, simple academic papers) into EPUBs that read like a publisher made them: real paragraphs, no running headers or page numbers, no mid-word line breaks, and correct chapter structure.
- Install by copying one binary. No Homebrew, Python, or model downloads.
- Run fully offline and on-device.
- Produce output tuned for a very constrained reader (Xteink X4; see §6), plus a generic profile.

**Non-goals for v1**
- Math-heavy papers with LaTeX equations. Render equations as images if detected.
- Complex magazine or textbook layouts with sidebars and callouts. Best effort only.
- Tables beyond simple ones. Render complex tables as images.
- Any GUI app. The CLI plus a Quick Action is the whole product.

**Requirements:** macOS 26 (Tahoe) or later, Apple Silicon. Foundation Models also needs Apple Intelligence enabled; without it the tool still works, just without the LLM cleanup pass (see §5.4).

## 2. CLI interface

```
pdf2epub <input.pdf> [-o output.epub]
         [--profile xteink|generic]     # default: xteink
         [--ocr auto|always|never]      # default: auto
         [--no-llm]                     # skip Foundation Models pass
         [--title "…"] [--author "…"]   # override metadata
         [--keep-intermediate <dir>]    # dump per-stage JSON for debugging
         [--verbose]
```

- Default output: `<input basename>.epub` next to the input.
- Exit codes: 0 = success; 1 = failure; 2 = success with warnings, such as LLM fallbacks or low-confidence OCR pages. Print a warning summary to stderr.
- Show progress on stderr ("page 37/212") so a Quick Action wrapper can surface it.
- Use `swift-argument-parser`. It compiles in statically, so it isn't a runtime dependency.

## 3. Architecture

A Swift Package with an executable target and a library target, so the pipeline is unit-testable.

```
Sources/
  pdf2epub/            # CLI entry (ArgumentParser)
  PDF2EPUBCore/
    Ingest/            # PDFKit text-layer extraction, page rendering
    OCR/               # Vision document recognition
    Layout/            # block model, heuristics (headers, columns, headings)
    Cleanup/           # Foundation Models pass + deterministic fixes
    Structure/         # chapters, TOC, footnotes
    Images/            # figure cropping, grayscale, resize, JPEG encode
    EPUB/              # XHTML/OPF/NCX writer + zip packaging
Tests/
  Fixtures/            # small PDFs + expected outputs
```

**Intermediate representation.** Every stage reads and writes a single document model, serialized to JSON when `--keep-intermediate` is set:

```swift
struct Block {
  var page: Int
  var bbox: CGRect            // page coordinates, normalized
  var kind: BlockKind         // paragraph, heading(level), listItem, blockquote,
                              // footnote, caption, figure, runningHeader,
                              // runningFooter, pageNumber, unknown
  var text: String
  var fontSize: Double?       // from text layer if available
  var isBold: Bool, isItalic: Bool
  var confidence: Double      // OCR confidence or 1.0 for text layer
  var continuesFromPrevious: Bool // paragraph split across page/column
}
```

## 4. Pipeline

### 4.1 Ingest
- Open with PDFKit. Read the outline (`PDFDocument.outlineRoot`) and metadata (title, author).
- For each page, decide between text layer and OCR:
  - `--ocr auto`: extract the text layer with `PDFPage.attributedString` (this keeps font info). Score it with the fraction of tokens that are real words, using `NSSpellChecker` or a bundled wordlist. If the score is below a threshold (start at about 0.85, then tune), or the layer is empty, OCR that page. Scanned PDFs often carry a garbage OCR layer from the scanner, and this check catches it.
- To OCR a page, render it with `PDFPage` into a `CGContext` at roughly 300 DPI, grayscale.

### 4.2 OCR and layout (Vision)
- Primary: the macOS 26 Swift Vision API `RecognizeDocumentsRequest`. It returns document structure (paragraphs, lists, tables) with bounding boxes. Map its output to `Block`s.
- Fallback: `VNRecognizeTextRequest` with `.accurate` and language correction on. Group lines into blocks by geometry.
- Even for text-layer pages, run layout analysis on the rendered image if PDFKit's block grouping is poor. Treat this as an experiment and measure it.

### 4.3 Deterministic structure heuristics (before the LLM)
Do as much as possible here: it's cheap, predictable, and testable.
- **Running headers and footers.** Text in the top or bottom roughly 8% of the page that repeats (fuzzy match, ignoring digits) across many pages. Remove it.
- **Page numbers.** Isolated numerals or roman numerals in the margins. Remove them.
- **Columns and reading order.** Detect 2-column layouts by the x-distribution of block centers. Read left column top to bottom, then right.
- **Headings.** Font size noticeably above the body median, short length, often centered, often followed by whitespace. Cross-check against the PDF outline when present.
- **Hyphenation.** A line ends in `-` and the next starts lowercase: join the parts if the joined word is in the dictionary. If both the joined and hyphenated forms are valid words, as in "well-known", mark it ambiguous for the LLM.
- **Paragraph joins across pages and columns.** The previous block doesn't end in terminal punctuation and the next starts lowercase: set `continuesFromPrevious`. Leave ambiguous cases for the LLM.
- **Footnotes.** Small-font blocks at the page bottom starting with a marker (¹, *, 1.), matched to superscript markers in the body.
- **Ligatures and quotes.** Normalize ligatures (ﬁ → fi) and the junk characters PDF extraction often produces, and normalize to Unicode NFC.

### 4.4 Foundation Models cleanup pass
See §5. Input is the block list with heuristic labels; output is corrected labels, joins, and fixed OCR text.

### 4.5 Chapters and TOC
- Prefer the PDF outline for chapter boundaries and titles.
- Otherwise use detected `heading(1)` blocks, with patterns like "Chapter", "CHAPTER", roman numerals, "Book I", "Canto".
- Write one XHTML file per chapter. If a chapter would exceed the profile's size cap (§6), split it at a paragraph boundary into `ch05a.xhtml`, `ch05b.xhtml`, and so on.

### 4.6 Images and figures
- Crop figure regions from the rendered page image using Vision bounding boxes.
- `xteink` profile: grayscale, max 480 px wide, baseline (non-progressive) JPEG, quality around 75. `generic` profile: max 1200 px, JPEG or PNG.
- Use the image caption as alt text when one is detected.
- Skip decorative images, such as tiny ornaments, unless they serve as section breaks; those become `<hr/>`.

## 5. Foundation Models usage

### 5.1 Scope: formatting and judgment calls only
The model never adds content, summarizes, modernizes spelling, or "improves" prose. Archaic spelling, unusual punctuation, and dialect are intentional. Its jobs:
1. Correct or confirm block kinds (heading vs. paragraph vs. caption vs. leftover header junk).
2. Decide ambiguous joins: does this paragraph continue across the page break? Is this hyphen real?
3. Fix obvious OCR errors in low-confidence spans (`rn`→`m`, `l`/`1`/`I`, `0`/`O`, broken diacritics). Only fix where the correction is unambiguous in context.

### 5.2 Chunking
- The context window is 4,096 tokens, covering instructions, input, and output. Send about one page of blocks per request, plus the last 1–2 blocks of the previous page and the first block of the next for continuity context.
- Use a new `LanguageModelSession` per chunk. No conversation history; keep it stateless and parallel-safe, but run requests serially unless testing shows concurrency helps.

### 5.3 Guided generation
Use `@Generable` output types so responses are always structurally valid:

```swift
@Generable struct PageCleanup {
  var blocks: [CleanBlock]
}
@Generable struct CleanBlock {
  @Guide(description: "Index of the input block this corresponds to")
  var index: Int
  var kind: CleanKind            // @Generable enum mirroring BlockKind
  var joinWithPrevious: Bool
  @Guide(description: "Corrected text. Must equal input text except for OCR fixes and hyphenation joins.")
  var text: String
}
```

**Validation after every response.** Reject the model's text for a block if its edit distance from the input exceeds a small threshold relative to length (start around 5%, tune with tests), and keep the original. This is the guard against the model rewriting prose.

### 5.4 Fallbacks
Fallbacks are a design requirement. The source material includes the classical and literary canon (Ovid, Sappho, Boccaccio, war literature, and so on), and the on-device model's guardrails may refuse some passages.
- **Guardrail violation** (`LanguageModelSession.GenerationError.guardrailViolation`): keep the heuristic output for that chunk unchanged, log a warning with the page number, and continue. Never drop or alter content because of a refusal.
- Investigate early whether `SystemLanguageModel(guardrails: .permissiveContentTransformations)` (or whatever the current SDK equivalent is) applies here. This is a content-transformation task on user-supplied text, which is the case that mode exists for. Verify the API name and behavior against the current SDK; don't trust this doc's spelling of it.
- **Context window exceeded:** split the chunk in half and retry once; if it fails again, fall back to heuristics.
- **Model unavailable** (Apple Intelligence off, unsupported Mac, model still downloading): check `SystemLanguageModel.default.availability` at startup, print one clear notice, and run heuristics only. Same behavior as `--no-llm`.
- Any other error: fall back for that chunk and continue. One bad page must never fail a whole book.

## 6. EPUB output

### 6.1 Target device: Xteink X4 with custom firmware
- ESP32-C3, about **380 KB usable RAM**, no PSRAM. 480×800 portrait display, 4-level grayscale.
- The planned firmware is CrossPoint Reader or a fork (Papyrix, CrossInk, SUMI, Inx…). These parse EPUB 2 and 3, cache aggressively to SD, and render a subset of XHTML and CSS.
- The stock Xteink firmware reportedly does not render EPUB images at all. Custom firmware does.
- **Before buying:** some units from third-party stores are reportedly USB-locked, and flashing them can brick the device. Buy from a source the CrossPoint project recommends, such as its Developer Edition.

### 6.2 `xteink` profile rules
- **EPUB 3 package with an EPUB 2 NCX** as well, for maximum reader compatibility.
- **Allowed XHTML elements only:** `html head body title meta link section div p span h1–h6 b strong i em u s sub sup small br hr blockquote ul ol li a img figure figcaption table tr td th`. Emit nothing else. No `script`, `iframe`, `svg`, `video`, `audio`, `canvas`, `form`, or `style` attributes with layout tricks.
- **CSS:** one tiny stylesheet (under 2 KB) with simple element selectors and a few classes only: margins, `text-indent`, `text-align`, `font-style`, `font-weight`, `page-break-before`. No web fonts, floats, positioning, flex, grid, or media queries.
- **No embedded fonts.** The device supplies its own.
- **Chapter file size cap:** start at about 64 KB of XHTML per file and tune on device. Small files are the main lever against the memory ceiling.
- **Images:** grayscale baseline JPEG, max 480 px wide, ideally under 100 KB each.
- **Cover:** render page 1, or the first full-page image, as `cover.jpg` at 480×800, marked in the OPF.
- **Footnotes:** collect as endnotes at the end of each chapter, with `<a href="#fn3" id="fnref3">` links and back-links. Avoid `epub:type="noteref"` popups unless verified to work on device.

### 6.3 `generic` profile
Same structure, with relaxed limits: larger images, a larger CSS budget, and no file-size splitting. Targets Kindle (via Send to Kindle), Kobo, Apple Books, and KOReader.

### 6.4 Packaging
- The zip must have `mimetype` as the first entry, stored uncompressed, followed by `META-INF/container.xml`, then content.
- Use `/usr/bin/zip`, which ships with macOS: `zip -X0 out.epub mimetype`, then `zip -Xr9D out.epub META-INF OEBPS`. Alternatively, write a minimal zip writer in Swift. Either way, add no third-party dependency.
- Validate with **epubcheck** during development, in CI or on the dev machine only. It's a Java tool and must not become a user dependency.

## 7. Finder Quick Action
- Install the binary to `~/bin/pdf2epub` or `/usr/local/bin/pdf2epub`. Codesign it ad hoc (`codesign -s -`), and notarize it if it will be shared.
- Create a Shortcuts or Automator Quick Action: "Receives PDF files in Finder" → Run Shell Script (`for f in "$@"; do /usr/local/bin/pdf2epub "$f"; done`) → show a notification on completion or warnings.
- Optional: a second action, "Convert & copy to e-reader", that copies the EPUB to the mounted SD card or USB volume.

## 8. Risks to check on day one
Prove each of these with a throwaway spike before building the rest:
1. **Foundation Models from a CLI binary.** Confirm `SystemLanguageModel` is available and works from a plain command-line executable launched from Terminal **and** from a Quick Action. This could need entitlements or an app bundle; if so, wrap the CLI in a minimal `.app` and invoke the inner binary.
2. **Guardrails on literary content.** Run 10–20 pages of explicit or violent classical text (Ovid's *Metamorphoses*, *The Iliad*, *Decameron*) through the cleanup pass. Measure the refusal rate with default and permissive guardrails.
3. **`RecognizeDocumentsRequest` quality** on a real scanned book page vs. `VNRecognizeTextRequest`.
4. **EPUB rendering on the target device.** Hand-build a tiny EPUB using the §6.2 subset (headings, italics, endnote links, one image, one split chapter) and confirm it renders on the X4 firmware, or the old Kindle in the meantime.

## 9. Test plan
- **Fixtures**, with small excerpts committed and full books kept local:
  - A born-digital novel: single column, running headers, chapter outline.
  - A scanned public-domain book (an Internet Archive or Gutenberg-era scan) with a junk OCR text layer.
  - A two-column academic paper with footnotes and a figure.
  - A book with heavy italics, verse or poetry (line breaks must be preserved), and archaic spelling.
- **Unit tests** for each heuristic: header detection, hyphen joins, page-break joins, footnote matching.
- **Golden tests:** fixture in, expected XHTML out, with diffs reviewed by a person.
- **epubcheck** passes on every fixture.
- **Acceptance:** on each fixture, the output has no running headers or page numbers in body text, no mid-word breaks, and chapters match the source. The text also matches the source exactly, apart from deliberate OCR fixes.

## 10. Milestones
1. **Spikes** (§8) and package skeleton.
2. **Born-digital path:** PDFKit extraction, heuristics, and the EPUB writer. With no LLM or OCR yet, this should already handle most of her library.
3. **OCR path:** Vision and the text-layer quality check.
4. **Foundation Models pass** with validation and fallbacks.
5. **Images, cover, footnotes.**
6. **Quick Action, install script, README.**
7. **On-device tuning** on the X4: chapter size cap, image sizes, CSS.

## 11. Verse and poetry
The heuristics in §4.3 will try to join lines into paragraphs, which destroys verse. Detect verse as runs of short lines with consistent left alignment and capitalized line starts, with ragged right edges and no justification. Emit each stanza as `<div class="stanza">` with `<br/>` between lines and no joining. This matters for the Ovid shelf. Add a `--verse` flag to force verse mode if the heuristic misses it.

## 12. Open questions
- Which firmware fork will the X4 run? Its supported CSS and footnote behavior may change §6.2.
- Should the tool also accept a folder and convert every PDF in it as a batch?
- Should it copy EPUBs straight to the device, which mounts over USB or uses WebDAV on some firmwares?
