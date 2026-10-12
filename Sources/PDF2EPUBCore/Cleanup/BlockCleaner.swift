import Foundation

/// A pass that reviews heuristic output and corrects labels, joins and OCR slips.
/// Implementations must never add, drop or rewrite content.
public protocol BlockCleaner {
    func clean(_ blocks: inout [Block], log: Log) async
}
