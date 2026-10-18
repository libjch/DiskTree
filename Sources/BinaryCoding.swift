import Foundation

// Shared little-endian primitives for DiskTree's binary formats (`.dtscan`
// trees and `.dtsum` history summaries).
//
// Reading goes through `ByteReader`, which borrows the decompressed buffer
// instead of copying it into an `[UInt8]` and allocates nothing per field.
// Decoding a multi-million-node `/` scan touches tens of millions of fields,
// so a per-field array allocation dominated the whole load.

// MARK: Writing

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendI32(_ value: Int32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendI64(_ value: Int64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendF64(_ value: Double) {
        appendI64(Int64(bitPattern: value.bitPattern))
    }

    /// u16 byte length followed by UTF-8 bytes (truncated at 65535 bytes).
    mutating func appendString(_ value: String) {
        let bytes = Array(value.utf8)
        appendU16(UInt16(Swift.min(bytes.count, 0xFFFF)))
        append(contentsOf: bytes.prefix(0xFFFF))
    }
}

// MARK: Reading

/// A non-owning cursor over a decoded buffer. Lifetime is bounded by the
/// `withUnsafeBytes` block that creates it.
struct ByteReader {
    private let bytes: UnsafeRawBufferPointer
    var index: Int

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        self.index = 0
    }

    var remaining: Int { bytes.count - index }
    var isAtEnd: Bool { index == bytes.count }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        index += count
        return true
    }

    mutating func matches(magic: [UInt8]) -> Bool {
        guard remaining >= magic.count else { return false }
        for (offset, expected) in magic.enumerated() where bytes[index + offset] != expected {
            return false
        }
        index += magic.count
        return true
    }

    mutating func readByte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readU16() -> Int? {
        guard remaining >= 2 else { return nil }
        defer { index += 2 }
        return Int(bytes[index]) | Int(bytes[index + 1]) << 8
    }

    mutating func readI32() -> Int32? {
        guard remaining >= 4 else { return nil }
        defer { index += 4 }
        var bits: UInt32 = 0
        for offset in 0..<4 { bits |= UInt32(bytes[index + offset]) << UInt32(8 * offset) }
        return Int32(bitPattern: bits)
    }

    mutating func readI64() -> Int64? {
        guard remaining >= 8 else { return nil }
        defer { index += 8 }
        var bits: UInt64 = 0
        for offset in 0..<8 { bits |= UInt64(bytes[index + offset]) << UInt64(8 * offset) }
        return Int64(bitPattern: bits)
    }

    mutating func readF64() -> Double? {
        guard let value = readI64() else { return nil }
        return Double(bitPattern: UInt64(bitPattern: value))
    }

    /// Byte range of a length-prefixed string, without materializing it.
    /// Skipped subtrees never pay for a `String` allocation this way.
    mutating func readStringRange() -> Range<Int>? {
        guard let count = readU16(), remaining >= count else { return nil }
        defer { index += count }
        return index..<(index + count)
    }

    func string(in range: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    mutating func readString() -> String? {
        guard let range = readStringRange() else { return nil }
        return string(in: range)
    }
}
