import Foundation

/// Why a Zstandard file could not be decoded.
enum ZstandardError: Error, Equatable {
    /// The file does not start with a Zstandard frame.
    case notZstandard
    /// The data breaks the format, or ends inside a frame.
    case corrupt
    /// A frame needs what this decoder leaves out: a dictionary, or a window beyond `ZstandardReader.largestWindow`.
    case unsupported
}

/// An FSE decoding table: for each state, the symbol it decodes and how to reach the next state (RFC 8878, 4.1).
struct ZstandardFSETable: Sendable {
    struct Entry: Sendable {
        var symbol: UInt8 = 0
        var bits: UInt8 = 0
        var base: UInt16 = 0
    }

    private(set) var entries: [Entry]
    let accuracyLog: Int

    /// The table of a normalized distribution, where -1 marks a probability below 1.
    init(distribution: [Int16], accuracyLog: Int) throws {
        let size = 1 << accuracyLog
        var entries = [Entry](repeating: Entry(), count: size), next = [Int](repeating: 0, count: distribution.count)
        var high = size - 1
        // Symbols below 1 take one row each from the end; the rest spread over the table in a fixed stride.
        for (symbol, probability) in distribution.enumerated() {
            if probability == -1 {
                guard high >= 0 else { throw ZstandardError.corrupt }
                entries[high].symbol = UInt8(symbol)
                high -= 1
                next[symbol] = 1
            } else {
                next[symbol] = Int(probability)
            }
        }
        let step = (size >> 1) + (size >> 3) + 3, mask = size - 1
        var position = 0
        for (symbol, probability) in distribution.enumerated() where probability > 0 {
            for _ in 0..<Int(probability) {
                guard position <= high else { throw ZstandardError.corrupt }
                entries[position].symbol = UInt8(symbol)
                repeat { position = (position + step) & mask } while position > high
            }
        }
        guard position == 0 else { throw ZstandardError.corrupt }
        // A symbol's rows, in state order, take the ranges of next states that make up the whole table.
        for state in 0..<size {
            let symbol = Int(entries[state].symbol), count = next[symbol]
            next[symbol] += 1
            let bits = accuracyLog - (Int.bitWidth - 1 - count.leadingZeroBitCount)
            entries[state].bits = UInt8(bits)
            entries[state].base = UInt16((count << bits) - size)
        }
        self.entries = entries
        self.accuracyLog = accuracyLog
    }

    /// A table that decodes one symbol in every state, for a section in RLE mode.
    init(rle symbol: UInt8) {
        entries = [Entry(symbol: symbol, bits: 0, base: 0)]
        accuracyLog = 0
    }

    /// Reads a distribution from the start of `base` and builds its table; also returns the bytes the description took.
    static func read(_ base: UnsafePointer<UInt8>, count: Int, largestSymbol: Int, largestAccuracyLog: Int) throws
        -> (table: ZstandardFSETable, length: Int) {
        var bits = ZstandardForwardBits(base, count: count)
        let accuracyLog = bits.read(4) + 5
        guard accuracyLog <= largestAccuracyLog else { throw ZstandardError.corrupt }
        var remaining = (1 << accuracyLog) + 1, threshold = 1 << accuracyLog, width = accuracyLog + 1
        var distribution: [Int16] = [], previousZero = false
        while remaining > 1, distribution.count <= largestSymbol {
            if previousZero {
                // A zero probability is followed by 2-bit counts of further zeros; 3 means another count follows.
                var zeros = 0, flag = 3
                while flag == 3 {
                    flag = bits.read(2)
                    zeros += flag
                }
                distribution += repeatElement(0, count: zeros)
                guard distribution.count <= largestSymbol else { throw ZstandardError.corrupt }
            }
            // Small values take one bit less; the value is the probability plus one.
            let largest = (2 * threshold - 1) - remaining
            var value = bits.peek(width - 1)
            if value < largest {
                bits.skip(width - 1)
            } else {
                value = bits.peek(width)
                if value >= threshold { value -= largest }
                bits.skip(width)
            }
            let probability = value - 1
            remaining -= abs(probability)
            distribution.append(Int16(probability))
            previousZero = probability == 0
            while remaining < threshold, threshold > 1 {
                width -= 1
                threshold >>= 1
            }
        }
        guard remaining == 1, bits.bytesRead <= count else { throw ZstandardError.corrupt }
        return (try ZstandardFSETable(distribution: distribution, accuracyLog: accuracyLog), bits.bytesRead)
    }

    /// The table of a section's compression mode: predefined, one symbol, described in the section, or the previous
    /// block's. Also returns the bytes the section spent on it.
    static func read(mode: UInt8, _ base: UnsafePointer<UInt8>, count: Int, predefined: ZstandardFSETable,
                     previous: ZstandardFSETable?, largestSymbol: Int, largestAccuracyLog: Int) throws
        -> (table: ZstandardFSETable, length: Int) {
        switch mode {
        case 0: return (predefined, 0)
        case 1:
            guard count >= 1, Int(base[0]) <= largestSymbol else { throw ZstandardError.corrupt }
            return (ZstandardFSETable(rle: base[0]), 1)
        case 2: return try read(base, count: count, largestSymbol: largestSymbol, largestAccuracyLog: largestAccuracyLog)
        default:
            guard let previous else { throw ZstandardError.corrupt }
            return (previous, 0)
        }
    }

    // The predefined distributions of RFC 8878, 3.1.1.3.2.2.
    static let literalLengths = try! ZstandardFSETable(distribution: [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
    ], accuracyLog: 6)
    static let matchLengths = try! ZstandardFSETable(distribution: [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
    ], accuracyLog: 6)
    static let offsets = try! ZstandardFSETable(distribution: [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ], accuracyLog: 5)
}

/// The lengths that literal-length and match-length codes stand for: a baseline plus that many bits read after it.
enum ZstandardLengthCodes {
    static let literalBase: [Int] = Array(0..<16) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
                                                     8192, 16384, 32768, 65536]
    static let literalBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
                                                                     13, 14, 15, 16]
    static let matchBase: [Int] = Array(3..<35) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
                                                   4099, 8195, 16387, 32771, 65539]
    static let matchBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
                                                                   12, 13, 14, 15, 16]
}

/// A Huffman decoding table for literals: looked up by a stream's next `maxBits` bits, an entry holds the symbol in its
/// high byte and the length of its code in its low byte (RFC 8878, 4.2).
struct ZstandardHuffmanTable {
    private(set) var entries: [UInt16]
    let maxBits: Int

    /// Reads a tree description from the start of `base`; also returns the bytes the description took.
    static func read(_ base: UnsafePointer<UInt8>, count: Int) throws -> (table: ZstandardHuffmanTable, length: Int) {
        guard count >= 1 else { throw ZstandardError.corrupt }
        let header = Int(base[0])
        var weights: [UInt8] = [], length: Int
        if header < 128 {
            // FSE-compressed weights: two states take turns on one stream until a state update runs past its start.
            length = 1 + header
            guard length <= count else { throw ZstandardError.corrupt }
            let (table, used) = try ZstandardFSETable.read(base + 1, count: header, largestSymbol: 255, largestAccuracyLog: 6)
            var bits = try ZstandardBackwardBits(base + 1 + used, count: header - used)
            var states = (bits.read(table.accuracyLog), bits.read(table.accuracyLog))
            guard !bits.overflowed else { throw ZstandardError.corrupt }
            try table.entries.withUnsafeBufferPointer { entries in
                func decode(_ state: inout Int) -> UInt8 {
                    let entry = entries[state]
                    state = Int(entry.base) + bits.read(Int(entry.bits))
                    return entry.symbol
                }
                while true {
                    guard weights.count < 254 else { throw ZstandardError.corrupt }
                    weights.append(decode(&states.0))
                    if bits.overflowed { weights.append(entries[states.1].symbol); break }
                    weights.append(decode(&states.1))
                    if bits.overflowed { weights.append(entries[states.0].symbol); break }
                }
            }
        } else {
            // Weights written directly, four bits each, the first in the high half of a byte.
            let number = header - 127
            length = 1 + (number + 1) / 2
            guard length <= count else { throw ZstandardError.corrupt }
            for index in 0..<number {
                let byte = base[1 + index / 2]
                weights.append(index % 2 == 0 ? byte >> 4 : byte & 0x0F)
            }
        }
        return (try ZstandardHuffmanTable(weights: weights), length)
    }

    /// The table of the weights of every symbol but the last present one, whose weight completes a power of two.
    init(weights given: [UInt8]) throws {
        var total = 0
        for weight in given where weight > 0 {
            guard weight <= 11 else { throw ZstandardError.corrupt }
            total += 1 << (Int(weight) - 1)
        }
        guard total > 0 else { throw ZstandardError.corrupt }
        let maxBits = Int.bitWidth - total.leadingZeroBitCount
        let left = (1 << maxBits) - total
        guard maxBits <= 11, left & (left - 1) == 0, given.count < 256 else { throw ZstandardError.corrupt }
        let weights = given + [UInt8(Int.bitWidth - left.leadingZeroBitCount)]
        // Rows go to the lowest weights first, and within a weight to symbols in order.
        var counts = [Int](repeating: 0, count: maxBits + 1)
        for weight in weights where weight > 0 { counts[Int(weight)] += 1 }
        guard counts[1] >= 2, counts[1] % 2 == 0 else { throw ZstandardError.corrupt }
        var starts = [Int](repeating: 0, count: maxBits + 1), next = 0
        for weight in 1...maxBits {
            starts[weight] = next
            next += counts[weight] << (weight - 1)
        }
        var entries = [UInt16](repeating: 0, count: 1 << maxBits)
        for (symbol, weight) in weights.enumerated() where weight > 0 {
            let rows = 1 << (Int(weight) - 1), entry = UInt16(symbol) << 8 | UInt16(maxBits + 1 - Int(weight))
            for row in starts[Int(weight)]..<(starts[Int(weight)] + rows) { entries[row] = entry }
            starts[Int(weight)] += rows
        }
        self.entries = entries
        self.maxBits = maxBits
    }

    /// Decodes `symbols` literals from one stream into `output`; the stream must end exactly at its first bit.
    func decode(_ stream: UnsafePointer<UInt8>, count: Int, symbols: Int, into output: UnsafeMutablePointer<UInt8>) throws {
        var bits = try ZstandardBackwardBits(stream, count: count)
        let maxBits = maxBits
        entries.withUnsafeBufferPointer { entries in
            for index in 0..<symbols {
                let entry = entries[bits.peek(maxBits)]
                output[index] = UInt8(truncatingIfNeeded: entry >> 8)
                bits.skip(Int(entry & 0xFF))
            }
        }
        guard bits.finished else { throw ZstandardError.corrupt }
    }
}
