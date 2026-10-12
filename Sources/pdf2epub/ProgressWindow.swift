import AppKit

/// A small floating window with a real progress bar, for runs started from Finder (the
/// Quick Action) where there's no terminal to show "page 231/432".
@MainActor
final class ProgressWindow: NSObject {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Starting…")

    init(bookName: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 128),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "PDF to EPUB"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let name = NSTextField(labelWithString: bookName)
        name.font = .boldSystemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [name, bar, status, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        name.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        stack.setCustomSpacing(12, after: status)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
    }

    /// Maps pipeline stages onto one bar: reading pages is most of the work.
    func update(stage: String, current: Int, total: Int) {
        let fraction = total > 0 ? Double(current) / Double(total) : 0
        switch stage {
        case "page":
            bar.doubleValue = 0.85 * fraction
            status.stringValue = "Reading page \(current) of \(total)"
        case "cleanup":
            bar.doubleValue = 0.85 + 0.12 * fraction
            status.stringValue = "Proofreading (\(current) of \(total))"
        case "writing":
            bar.doubleValue = 0.97
            status.stringValue = "Writing the EPUB…"
        default:
            status.stringValue = stage
        }
        // Async main doesn't always run a full AppKit display cycle; draw now.
        panel.contentView?.displayIfNeeded()
    }

    func close() { panel.close() }

    @objc private func cancel(_ sender: Any?) {
        exit(130)
    }
}
