import Foundation

/// Applies a character-level edit (old plain text → new plain text) to text that carries
/// inline style markers, so corrections from the model keep italics and superscripts.
public enum TextPatch {
    enum Op { case keep, substitute(Character), insert(Character), delete }

    /// Returns nil if the texts are too long to align or the edit can't be mapped.
    public static func apply(to marked: String, newPlain: String) -> String? {
        let old = Array(InlineStyle.strip(marked))
        let new = Array(newPlain)
        guard old.count <= 4000, new.count <= 4000 else { return nil }
        let ops = align(old, new)

        // Walk the marked string, consuming one op per visible character.
        var out = ""
        var opIndex = 0
        func flushInserts() {
            while opIndex < ops.count, case .insert(let c) = ops[opIndex] {
                out.append(c)
                opIndex += 1
            }
        }
        for c in marked {
            if InlineStyle.isMarker(c) { out.append(c); continue }
            flushInserts()
            guard opIndex < ops.count else { return nil }
            switch ops[opIndex] {
            case .keep: out.append(c)
            case .substitute(let n): out.append(n)
            case .delete: break
            case .insert: return nil
            }
            opIndex += 1
        }
        flushInserts()
        guard opIndex == ops.count else { return nil }
        return InlineStyle.tidy(out)
    }

    /// Levenshtein alignment with backtrace, as a list of ops over `a`.
    static func align(_ a: [Character], _ b: [Character]) -> [Op] {
        let n = a.count, m = b.count
        var d = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Int32(i) }
        for j in 0...m { d[0][j] = Int32(j) }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let cost: Int32 = a[i - 1] == b[j - 1] ? 0 : 1
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(a[i - 1] == b[j - 1] ? .keep : .substitute(b[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.delete)
                i -= 1
            } else {
                ops.append(.insert(b[j - 1]))
                j -= 1
            }
        }
        return ops.reversed()
    }
}
