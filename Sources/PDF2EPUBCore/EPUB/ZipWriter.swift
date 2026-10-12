import Foundation
import Compression

/// A minimal zip writer: stored or deflated entries, no zip64, no extra fields.
/// Enough for EPUB, whose spec wants `mimetype` first and uncompressed.
public struct ZipWriter {
    struct Entry {
        var name: Data
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var method: UInt16
        var offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []
    // 1980-01-01 00:00, the DOS epoch: deterministic output.
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    public init() {}

    public mutating func add(_ path: String, _ content: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        var stored = content
        var method: UInt16 = 0
        if compress, content.count > 64, let deflated = Self.deflate(content), deflated.count < content.count {
            stored = deflated
            method = 8
        }
        let offset = UInt32(data.count)
        data.append(le32(0x04034b50))
        data.append(le16(20))           // version needed
        data.append(le16(0x0800))       // flags: UTF-8 names
        data.append(le16(method))
        data.append(le16(dosTime))
        data.append(le16(dosDate))
        data.append(le32(crc))
        data.append(le32(UInt32(stored.count)))
        data.append(le32(UInt32(content.count)))
        data.append(le16(UInt16(name.count)))
        data.append(le16(0))            // extra length
        data.append(name)
        data.append(stored)
        entries.append(Entry(name: name, crc: crc, compressedSize: UInt32(stored.count),
                             size: UInt32(content.count), method: method, offset: offset))
    }

    public mutating func add(_ path: String, _ text: String, compress: Bool = true) {
        add(path, Data(text.utf8), compress: compress)
    }

    public func finish() -> Data {
        var out = data
        let cdStart = UInt32(out.count)
        for e in entries {
            out.append(le32(0x02014b50))
            out.append(le16(0x031E))    // made by: Unix, spec 3.0
            out.append(le16(20))
            out.append(le16(0x0800))
            out.append(le16(e.method))
            out.append(le16(dosTime))
            out.append(le16(dosDate))
            out.append(le32(e.crc))
            out.append(le32(e.compressedSize))
            out.append(le32(e.size))
            out.append(le16(UInt16(e.name.count)))
            out.append(le16(0))         // extra
            out.append(le16(0))         // comment
            out.append(le16(0))         // disk
            out.append(le16(0))         // internal attrs
            out.append(le32(0o100644 << 16)) // external attrs: regular file rw-r--r--
            out.append(le32(e.offset))
            out.append(e.name)
        }
        let cdSize = UInt32(out.count) - cdStart
        out.append(le32(0x06054b50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(cdSize))
        out.append(le32(cdStart))
        out.append(le16(0))
        return out
    }

    /// Raw DEFLATE (RFC 1951), which is what Compression's ZLIB algorithm emits.
    static func deflate(_ input: Data) -> Data? {
        let capacity = input.count + input.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buf in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}
