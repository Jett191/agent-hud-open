import Foundation

/// A Zstandard bitstream read backward, as its entropy-coded parts are: the encoder writes fields forward, least
/// significant bit first, ends the stream with a 1 bit and pads it with zeros to a whole byte, and the decoder takes the
/// last field written first.
struct ZstandardBackwardBits {
    private let base: UnsafePointer<UInt8>
    /// The bits not read yet, counted from the stream's first bit; below zero once a read went past the start, where the
    /// missing bits read as zeros.
    private(set) var remaining: Int

    /// - base: the stream's first byte. The 7 bytes after its last byte must be readable; their values do not matter.
    init(_ base: UnsafePointer<UInt8>, count: Int) throws {
        guard count > 0, base[count - 1] != 0 else { throw ZstandardError.corrupt }
        self.base = base
        remaining = (count - 1) * 8 + 7 - base[count - 1].leadingZeroBitCount
    }

    /// The next `count` bits, at most 56, without taking them.
    @inline(__always) func peek(_ count: Int) -> Int {
        let start = remaining - count
        if start >= 0 {
            let word = UInt64(littleEndian: UnsafeRawPointer(base + (start >> 3)).loadUnaligned(as: UInt64.self))
            return Int(truncatingIfNeeded: (word >> UInt64(start & 7)) & ((1 << UInt64(count)) - 1))
        }
        guard remaining > 0 else { return 0 }
        let word = UInt64(littleEndian: UnsafeRawPointer(base).loadUnaligned(as: UInt64.self))
        return Int(truncatingIfNeeded: (word & ((1 << UInt64(remaining)) - 1)) << UInt64(-start))
    }

    @inline(__always) mutating func read(_ count: Int) -> Int {
        let value = peek(count)
        remaining -= count
        return value
    }

    @inline(__always) mutating func skip(_ count: Int) { remaining -= count }

    /// Whether a read went past the stream's first bit.
    var overflowed: Bool { remaining < 0 }
    /// Whether every bit was read, and none beyond.
    var finished: Bool { remaining == 0 }
}

/// A Zstandard bitstream read forward, least significant bit first, as an FSE table description is.
struct ZstandardForwardBits {
    private let base: UnsafePointer<UInt8>
    private let count: Int
    /// The bits read so far.
    private(set) var position = 0

    init(_ base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    /// The next `width` bits, at most 24; bits past the stream's end read as zeros.
    func peek(_ width: Int) -> Int {
        var value = 0, byte = position >> 3, shift = -(position & 7)
        while shift < width {
            if byte < count { value |= shift >= 0 ? Int(base[byte]) << shift : Int(base[byte]) >> -shift }
            byte += 1
            shift += 8
        }
        return value & ((1 << width) - 1)
    }

    mutating func read(_ width: Int) -> Int {
        let value = peek(width)
        position += width
        return value
    }

    mutating func skip(_ width: Int) { position += width }

    /// The whole bytes the bits read so far take up.
    var bytesRead: Int { (position + 7) >> 3 }
}
