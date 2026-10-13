import Foundation
import AppKit
import ArgumentParser
import PDF2EPUBCore

@main
struct PDF2EPUB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf2epub",
        abstract: "Convert a PDF book or article into a clean, reflowable EPUB.",
        discussion: """
        Exit status: 0 on success, 1 on failure, 2 on success with warnings.
        """,
        version: "1.1.1")

    @Argument(help: "The PDF to convert.", completion: .file(extensions: ["pdf"]))
    var input: String

    @Option(name: .shortAndLong, help: "Output path (default: next to the input, with .epub).")
    var output: String?

    @Option(help: ArgumentHelp("Device profile: " + Profile.all.map { "\($0.name) (\($0.summary))" }.joined(separator: ", ") + "."))
    var profile: String = Profile.all[0].name

    @Option(help: "When to OCR pages: auto, always or never.")
    var ocr: String = "auto"

    @Flag(name: .customLong("no-llm"), help: "Skip the Foundation Models cleanup pass.")
    var noLLM = false

    @Option(help: "Override the book title.")
    var title: String?

    @Option(help: "Override the author.")
    var author: String?

    @Flag(help: "Treat short-line passages as verse (keep line breaks).")
    var verse = false

    @Option(name: .customLong("keep-intermediate"), help: "Write per-stage JSON to this directory for debugging.")
    var keepIntermediate: String?

    @Option(help: ArgumentHelp("Only convert these pages, e.g. 10-20 (1-based).", visibility: .hidden))
    var pages: String?

    @Flag(name: .shortAndLong, help: "Print details while converting.")
    var verbose = false

    @Flag(name: .customLong("progress-window"), help: "Show a progress window (used by the Finder Quick Action).")
    var progressWindow = false

    @Option(name: .customLong("dump-page"), help: ArgumentHelp("Print the extracted lines of one page (1-based) and exit.", visibility: .hidden))
    var dumpPage: Int?

    /// Exit codes per the spec: 0 success, 1 failure (including bad arguments), 2 warnings.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            let code = exitCode(for: error)
            if code == .success {
                print(fullMessage(for: error))
                Foundation.exit(0)
            }
            if code.rawValue != 2 {
                let message = fullMessage(for: error)
                if !message.isEmpty { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                Foundation.exit(1)
            }
            Foundation.exit(2)
        }
    }

    /// Runs the conversion in the background while AppKit drives a progress window.
    @MainActor
    static func convertWithWindow(_ pipeline: Pipeline, log: Log, input: URL, output: URL) async throws -> ConversionReport {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon
        let window = ProgressWindow(bookName: input.deletingPathExtension().lastPathComponent)
        window.show()
        log.onProgress = { stage, current, total in
            DispatchQueue.main.async { window.update(stage: stage, current: current, total: total) }
        }
        defer { window.close() }
        return try await Task.detached { try await pipeline.convert(input: input, output: output) }.value
    }

    mutating func run() async throws {
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("No such file: \(input)")
        }
        let outputURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? inputURL.deletingPathExtension().appendingPathExtension("epub")
        guard let profile = Profile.named(self.profile) else {
            throw ValidationError("Unknown profile '\(self.profile)'. Use one of: \(Profile.all.map(\.name).joined(separator: ", ")).")
        }
        guard let ocrMode = OCRMode(rawValue: ocr.lowercased()) else {
            throw ValidationError("Unknown OCR mode '\(ocr)'. Use auto, always or never.")
        }

        if let dumpPage {
            try await Debug.dumpPage(inputURL, page: dumpPage - 1, ocr: ocr.lowercased() == "always")
            return
        }

        var options = ConversionOptions()
        options.profile = profile
        options.ocr = ocrMode
        options.useLLM = !noLLM
        options.title = title
        options.author = author
        options.forceVerse = verse
        options.keepIntermediate = keepIntermediate.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let pages {
            let parts = pages.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = parts.first { options.pageRange = (first - 1)...((parts.last ?? first) - 1) }
        }

        let log = Log(verbose: verbose)
        let pipeline = Pipeline(options: options, log: log)
        if options.useLLM {
            pipeline.cleaner = LLMCleaner.makeIfAvailable(log: log)
        }
        do {
            let report: ConversionReport
            if progressWindow {
                report = try await Self.convertWithWindow(pipeline, log: log, input: inputURL, output: outputURL)
            } else {
                report = try await pipeline.convert(input: inputURL, output: outputURL)
            }
            log.info("Wrote \(report.output.path) (\(report.chapters) chapters, \(report.pages) pages, \(report.ocrPages) OCR'd, \(report.stats.totalBytes / 1024) KB)")
            if !report.warnings.isEmpty {
                log.info("\(report.warnings.count) warning(s):")
                for w in report.warnings.prefix(20) { log.info("  - \(w)") }
                if report.warnings.count > 20 { log.info("  … and \(report.warnings.count - 20) more") }
                throw ExitCode(2)
            }
        } catch let error as ConversionError {
            log.info("error: \(error.description)")
            throw ExitCode(1)
        }
    }
}
