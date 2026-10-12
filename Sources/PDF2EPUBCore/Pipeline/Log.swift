import Foundation

/// Progress, notices and warnings, all on stderr so stdout stays clean.
public final class Log: @unchecked Sendable {
    public let verbose: Bool
    private let lock = NSLock()
    private var _warnings: [String] = []
    private let isTTY = isatty(STDERR_FILENO) != 0
    private var lastProgress = Date.distantPast
    private var progressShown = false

    public init(verbose: Bool) {
        self.verbose = verbose
    }

    public var warnings: [String] {
        lock.lock(); defer { lock.unlock() }
        return _warnings
    }

    public func warn(_ message: String) {
        lock.lock()
        _warnings.append(message)
        lock.unlock()
        if verbose { emit("warning: \(message)") }
    }

    public func info(_ message: String) {
        emit(message)
    }

    public func debug(_ message: String) {
        if verbose { emit(message) }
    }

    /// Called on every progress update (stage, current, total), e.g. to drive a window.
    public var onProgress: (@Sendable (String, Int, Int) -> Void)?

    /// "page 37/212". On a terminal it redraws one line; otherwise prints every few seconds.
    public func progress(_ stage: String, _ current: Int, _ total: Int) {
        onProgress?(stage, current, total)
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let done = current == total
        if isTTY {
            guard done || now.timeIntervalSince(lastProgress) > 0.1 else { return }
            FileHandle.standardError.write(Data("\r\u{1B}[K\(stage) \(current)/\(total)".utf8))
            progressShown = !done
            if done { FileHandle.standardError.write(Data("\n".utf8)) }
        } else {
            guard done || now.timeIntervalSince(lastProgress) > 2 else { return }
            FileHandle.standardError.write(Data("\(stage) \(current)/\(total)\n".utf8))
        }
        lastProgress = now
    }

    private func emit(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if progressShown && isTTY {
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            progressShown = false
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
