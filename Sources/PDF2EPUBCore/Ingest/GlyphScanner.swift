import Foundation
import CoreGraphics

/// Font facts read from a PDF font dictionary.
public struct PDFFontInfo: Sendable {
    public var name: String
    public var isItalic: Bool
    public var isBold: Bool
    public var isSmallCaps: Bool
    var isTwoByte: Bool
    var firstChar: Int
    /// Glyph advances in text-space units (already divided by 1000, or scaled by FontMatrix for Type3).
    var widths: [Double]
    var cidWidths: [Int: Double]
    var defaultWidth: Double

    func width(of code: Int) -> Double {
        if isTwoByte { return cidWidths[code] ?? defaultWidth }
        let i = code - firstChar
        if i >= 0 && i < widths.count, widths[i] > 0 { return widths[i] }
        return defaultWidth
    }
}

/// A glyph as painted by the content stream, in PDF user space.
public struct PlacedGlyph: Sendable {
    /// Bounding box of the glyph cell (advance × font size) in user space.
    public var box: CGRect
    /// Baseline y.
    public var y: Double
    /// Effective font size in user space.
    public var size: Double
    public var font: Int
    public var invisible: Bool
    /// Text not running left-to-right horizontally (e.g. arXiv's sidebar stamp).
    public var rotated: Bool
}

public struct ContentScan: Sendable {
    public var glyphs: [PlacedGlyph] = []
    public var fonts: [PDFFontInfo] = []
    /// Placed image XObjects, in user space.
    public var imageRects: [CGRect] = []
}

/// Walks a page's content stream with `CGPDFScanner` to recover what PDFKit's text API
/// throws away: the real font (name, italic, bold) and size of every glyph, plus where
/// images are drawn. We don't decode glyphs to Unicode here; PDFKit does that well.
/// The two are matched up by position in `TextLayerExtractor`.
public enum GlyphScanner {
    public static func scan(_ page: CGPDFPage) -> ContentScan {
        let state = ScanState()
        let table = makeOperatorTable()
        let content = CGPDFContentStreamCreateWithPage(page)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return state.result
    }

    // MARK: - State

    struct GState {
        var ctm = CGAffineTransform.identity
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var hScale = 1.0
        var leading = 0.0
        var rise = 0.0
        var font: Int? = nil
        var fontSize = 0.0
        var renderMode = 0
    }

    final class ScanState {
        var gs = GState()
        var stack: [GState] = []
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity
        var result = ContentScan()
        var fontCache: [Int: Int] = [:]
        var formDepth = 0
        var table: CGPDFOperatorTableRef?
    }

    static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    static func popNumbers(_ s: CGPDFScannerRef, _ n: Int) -> [Double]? {
        var out = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v) else { return nil }
            out[i] = Double(v)
        }
        return out
    }

    // MARK: - Operators

    static func makeOperatorTable() -> CGPDFOperatorTableRef {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, info in
            let st = GlyphScanner.state(info); st.stack.append(st.gs)
        }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let st = GlyphScanner.state(info); if let g = st.stack.popLast() { st.gs = g }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            guard let n = GlyphScanner.popNumbers(s, 6) else { return }
            let st = GlyphScanner.state(info)
            let m = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            st.gs.ctm = m.concatenating(st.gs.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "BT") { _, info in
            let st = GlyphScanner.state(info); st.tm = .identity; st.tlm = .identity
        }
        CGPDFOperatorTableSetCallback(t, "Tc") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.charSpacing = n[0] }
        }
        CGPDFOperatorTableSetCallback(t, "Tw") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.wordSpacing = n[0] }
        }
        CGPDFOperatorTableSetCallback(t, "Tz") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.hScale = n[0] / 100 }
        }
        CGPDFOperatorTableSetCallback(t, "TL") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.leading = n[0] }
        }
        CGPDFOperatorTableSetCallback(t, "Ts") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.rise = n[0] }
        }
        CGPDFOperatorTableSetCallback(t, "Tr") { s, info in
            if let n = GlyphScanner.popNumbers(s, 1) { GlyphScanner.state(info).gs.renderMode = Int(n[0]) }
        }
        CGPDFOperatorTableSetCallback(t, "Tf") { s, info in
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>? = nil
            guard CGPDFScannerPopNumber(s, &size), CGPDFScannerPopName(s, &name), let name else { return }
            let st = GlyphScanner.state(info)
            st.gs.fontSize = Double(size)
            st.gs.font = GlyphScanner.resolveFont(scanner: s, name: name, state: st)
        }
        CGPDFOperatorTableSetCallback(t, "Td") { s, info in
            guard let n = GlyphScanner.popNumbers(s, 2) else { return }
            GlyphScanner.moveText(GlyphScanner.state(info), n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(t, "TD") { s, info in
            guard let n = GlyphScanner.popNumbers(s, 2) else { return }
            let st = GlyphScanner.state(info)
            st.gs.leading = -n[1]
            GlyphScanner.moveText(st, n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(t, "Tm") { s, info in
            guard let n = GlyphScanner.popNumbers(s, 6) else { return }
            let st = GlyphScanner.state(info)
            st.tm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            st.tlm = st.tm
        }
        CGPDFOperatorTableSetCallback(t, "T*") { _, info in
            let st = GlyphScanner.state(info); GlyphScanner.moveText(st, 0, -st.gs.leading)
        }
        CGPDFOperatorTableSetCallback(t, "Tj") { s, info in
            var str: CGPDFStringRef? = nil
            guard CGPDFScannerPopString(s, &str), let str else { return }
            GlyphScanner.show(GlyphScanner.state(info), str)
        }
        CGPDFOperatorTableSetCallback(t, "'") { s, info in
            var str: CGPDFStringRef? = nil
            guard CGPDFScannerPopString(s, &str), let str else { return }
            let st = GlyphScanner.state(info)
            GlyphScanner.moveText(st, 0, -st.gs.leading)
            GlyphScanner.show(st, str)
        }
        CGPDFOperatorTableSetCallback(t, "\"") { s, info in
            var str: CGPDFStringRef? = nil
            guard CGPDFScannerPopString(s, &str), let str, let n = GlyphScanner.popNumbers(s, 2) else { return }
            let st = GlyphScanner.state(info)
            st.gs.wordSpacing = n[0]
            st.gs.charSpacing = n[1]
            GlyphScanner.moveText(st, 0, -st.gs.leading)
            GlyphScanner.show(st, str)
        }
        CGPDFOperatorTableSetCallback(t, "TJ") { s, info in
            var arr: CGPDFArrayRef? = nil
            guard CGPDFScannerPopArray(s, &arr), let arr else { return }
            let st = GlyphScanner.state(info)
            for i in 0..<CGPDFArrayGetCount(arr) {
                var str: CGPDFStringRef? = nil
                var num: CGPDFReal = 0
                if CGPDFArrayGetString(arr, i, &str), let str {
                    GlyphScanner.show(st, str)
                } else if CGPDFArrayGetNumber(arr, i, &num) {
                    let tx = -Double(num) / 1000 * st.gs.fontSize * st.gs.hScale
                    st.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(st.tm)
                }
            }
        }
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            var name: UnsafePointer<CChar>? = nil
            guard CGPDFScannerPopName(s, &name), let name else { return }
            GlyphScanner.doXObject(scanner: s, name: name, state: GlyphScanner.state(info))
        }
        return t
    }

    static func moveText(_ st: ScanState, _ tx: Double, _ ty: Double) {
        st.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(st.tlm)
        st.tm = st.tlm
    }

    static func show(_ st: ScanState, _ str: CGPDFStringRef) {
        guard let fontIndex = st.gs.font, let bytes = CGPDFStringGetBytePtr(str) else { return }
        let len = CGPDFStringGetLength(str)
        let font = st.result.fonts[fontIndex]
        let gs = st.gs
        let invisible = gs.renderMode == 3 || gs.renderMode == 7
        var i = 0
        while i < len {
            let code: Int
            if font.isTwoByte {
                guard i + 1 < len else { break }
                code = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
            } else {
                code = Int(bytes[i])
                i += 1
            }
            let w0 = font.width(of: code)
            let m = st.tm.concatenating(gs.ctm)
            let fs = gs.fontSize
            let advance = w0 * fs * gs.hScale
            let corners = [CGPoint(x: 0, y: gs.rise - 0.2 * fs), CGPoint(x: advance, y: gs.rise - 0.2 * fs),
                           CGPoint(x: 0, y: gs.rise + 0.8 * fs), CGPoint(x: advance, y: gs.rise + 0.8 * fs)]
                .map { $0.applying(m) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let size = fs * hypot(m.c, m.d)
            let rotated = abs(m.b) > 0.2 * abs(m.a) || abs(m.c) > 0.2 * abs(m.d) || m.a < 0 || m.d < 0
            if size > 0.5 {
                st.result.glyphs.append(PlacedGlyph(
                    box: box, y: CGPoint(x: 0, y: gs.rise).applying(m).y,
                    size: size, font: fontIndex, invisible: invisible, rotated: rotated))
            }
            let spacing = gs.charSpacing + ((!font.isTwoByte && code == 32) ? gs.wordSpacing : 0)
            let tx = (w0 * gs.fontSize + spacing) * gs.hScale
            st.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(st.tm)
        }
    }

    static func doXObject(scanner: CGPDFScannerRef, name: UnsafePointer<CChar>, state st: ScanState) {
        let cs = CGPDFScannerGetContentStream(scanner)
        guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
        var stream: CGPDFStreamRef? = nil
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(st.gs.ctm)
            st.result.imageRects.append(rect)
        case "Form":
            guard st.formDepth < 8 else { return }
            let saved = st.gs
            let savedTm = st.tm, savedTlm = st.tlm
            if let m = numberArray(dict, "Matrix"), m.count == 6 {
                let matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                st.gs.ctm = matrix.concatenating(st.gs.ctm)
            }
            var resources: CGPDFDictionaryRef? = nil
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
            let formCS = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, cs)
            let table = makeOperatorTable()
            let sub = CGPDFScannerCreate(formCS, table, Unmanaged.passUnretained(st).toOpaque())
            st.formDepth += 1
            CGPDFScannerScan(sub)
            st.formDepth -= 1
            CGPDFScannerRelease(sub)
            CGPDFOperatorTableRelease(table)
            CGPDFContentStreamRelease(formCS)
            st.gs = saved
            st.tm = savedTm
            st.tlm = savedTlm
        default:
            break
        }
    }

    // MARK: - Fonts

    static func resolveFont(scanner: CGPDFScannerRef, name: UnsafePointer<CChar>, state st: ScanState) -> Int? {
        let cs = CGPDFScannerGetContentStream(scanner)
        guard let obj = CGPDFContentStreamGetResource(cs, "Font", name) else { return nil }
        var dict: CGPDFDictionaryRef? = nil
        guard CGPDFObjectGetValue(obj, .dictionary, &dict), let dict else { return nil }
        let key = unsafeBitCast(dict, to: Int.self)
        if let idx = st.fontCache[key] { return idx }
        let info = parseFont(dict)
        st.result.fonts.append(info)
        st.fontCache[key] = st.result.fonts.count - 1
        return st.result.fonts.count - 1
    }

    static func parseFont(_ dict: CGPDFDictionaryRef) -> PDFFontInfo {
        let subtype = name(dict, "Subtype") ?? ""
        var baseFont = name(dict, "BaseFont") ?? ""
        var descriptor: CGPDFDictionaryRef? = nil
        var info = PDFFontInfo(name: "", isItalic: false, isBold: false, isSmallCaps: false, isTwoByte: false,
                               firstChar: 0, widths: [], cidWidths: [:], defaultWidth: 0.5)

        if subtype == "Type0" {
            info.isTwoByte = true
            var descendants: CGPDFArrayRef? = nil
            var cidFont: CGPDFDictionaryRef? = nil
            if CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &cidFont), let cidFont {
                info.defaultWidth = (number(cidFont, "DW") ?? 1000) / 1000
                info.cidWidths = parseCIDWidths(cidFont)
                _ = CGPDFDictionaryGetDictionary(cidFont, "FontDescriptor", &descriptor)
                if baseFont.isEmpty { baseFont = name(cidFont, "BaseFont") ?? "" }
            }
        } else {
            var scale = 1.0 / 1000
            if subtype == "Type3", let fm = numberArray(dict, "FontMatrix"), fm.count == 6 { scale = fm[0] }
            info.firstChar = Int(number(dict, "FirstChar") ?? 0)
            info.widths = (numberArray(dict, "Widths") ?? []).map { $0 * scale }
            _ = CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor)
            if let descriptor, let missing = number(descriptor, "MissingWidth"), missing > 0 {
                info.defaultWidth = missing * scale
            } else if !info.widths.isEmpty {
                let nonZero = info.widths.filter { $0 > 0 }
                info.defaultWidth = nonZero.isEmpty ? 0.5 : nonZero.reduce(0, +) / Double(nonZero.count)
            } else if baseFont.lowercased().contains("courier") {
                info.defaultWidth = 0.6
            }
        }

        // Strip a subset prefix like "ABCDEF+".
        if let plus = baseFont.firstIndex(of: "+"), baseFont.distance(from: baseFont.startIndex, to: plus) == 6 {
            baseFont = String(baseFont[baseFont.index(after: plus)...])
        }
        info.name = baseFont
        let style = styleFromName(baseFont)
        info.isItalic = style.italic
        info.isBold = style.bold
        info.isSmallCaps = style.smallCaps

        if let descriptor {
            let flags = Int(number(descriptor, "Flags") ?? 0)
            if flags & (1 << 6) != 0 { info.isItalic = true }
            if flags & (1 << 18) != 0 { info.isBold = true }
            if let angle = number(descriptor, "ItalicAngle"), abs(angle) > 4 { info.isItalic = true }
            if let weight = number(descriptor, "FontWeight"), weight >= 600 { info.isBold = true }
        }
        return info
    }

    /// Guesses style from a PostScript font name, including TeX's Computer Modern naming.
    public static func styleFromName(_ raw: String) -> (italic: Bool, bold: Bool, smallCaps: Bool) {
        let n = raw.lowercased()
        let tex = n.replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
        var italic = n.contains("italic") || n.contains("oblique") || n.contains("ital")
            || n.range(of: #"[-_,](it|obl|slanted|sl|kursiv)\b"#, options: .regularExpression) != nil
            || n.hasSuffix("-it") || n.hasSuffix("it-") || n.range(of: #"-(bold|semibold|medium|light)?it$"#, options: .regularExpression) != nil
        var bold = n.contains("bold") || n.contains("black") || n.contains("heavy") || n.contains("semibold")
            || n.contains("demi") || n.range(of: #"[-_,](bd|bx|sb|db|medi|mediital)\b"#, options: .regularExpression) != nil
        var smallCaps = n.contains("smallcaps") || n.range(of: #"[-_,]?(sc|osf|caps)$"#, options: .regularExpression) != nil
        // Computer Modern / cm-super / Latin Modern families.
        for prefix in ["cmti", "cmsl", "cmmi", "cmbxti", "cmbxsl", "sfti", "sfsl", "sfbi", "lmromanslant"] where tex.hasPrefix(prefix) { italic = true }
        for prefix in ["cmbx", "cmb", "sfbx", "sfbi", "cmssbx"] where tex.hasPrefix(prefix) { bold = true }
        for prefix in ["cmcsc", "sfcc", "lmromancaps"] where tex.hasPrefix(prefix) { smallCaps = true }
        if tex.hasPrefix("cmbright") { bold = false }
        return (italic, bold, smallCaps)
    }

    static func parseCIDWidths(_ dict: CGPDFDictionaryRef) -> [Int: Double] {
        var arr: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(dict, "W", &arr), let arr else { return [:] }
        var out: [Int: Double] = [:]
        let count = CGPDFArrayGetCount(arr)
        var i = 0
        while i < count {
            var first: CGPDFReal = 0
            guard CGPDFArrayGetNumber(arr, i, &first) else { break }
            var list: CGPDFArrayRef? = nil
            if CGPDFArrayGetArray(arr, i + 1, &list), let list {
                for j in 0..<CGPDFArrayGetCount(list) {
                    var w: CGPDFReal = 0
                    if CGPDFArrayGetNumber(list, j, &w) { out[Int(first) + j] = Double(w) / 1000 }
                }
                i += 2
            } else {
                var last: CGPDFReal = 0, w: CGPDFReal = 0
                guard CGPDFArrayGetNumber(arr, i + 1, &last), CGPDFArrayGetNumber(arr, i + 2, &w) else { break }
                if last - first < 65536 {
                    for c in Int(first)...max(Int(first), Int(last)) { out[c] = Double(w) / 1000 }
                }
                i += 3
            }
        }
        return out
    }

    // MARK: - CGPDF helpers

    static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var p: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(dict, key, &p), let p else { return nil }
        return String(cString: p)
    }

    static func number(_ dict: CGPDFDictionaryRef, _ key: String) -> Double? {
        var v: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dict, key, &v) else { return nil }
        return Double(v)
    }

    static func numberArray(_ dict: CGPDFDictionaryRef, _ key: String) -> [Double]? {
        var arr: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(dict, key, &arr), let arr else { return nil }
        return (0..<CGPDFArrayGetCount(arr)).map { i in
            var v: CGPDFReal = 0
            _ = CGPDFArrayGetNumber(arr, i, &v)
            return Double(v)
        }
    }
}
