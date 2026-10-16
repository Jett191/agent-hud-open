import Foundation

/// Decodes a frame's compressed blocks: each block's literals, then its sequences, which copy literals and earlier text
/// into the output (RFC 8878, 3.1.1.3). A block hands the next its Huffman table, its sequence tables and the three most
/// recent offsets.
final class ZstandardBlocks {
    /// The most text a block holds, whatever the window.
    static let largestSize = 128 << 10

    private let literals = UnsafeMutablePointer<UInt8>.allocate(capacity: largestSize)
    private var literalCount = 0
    private var huffman: ZstandardHuffmanTable?
    private var literalLengths: ZstandardFSETable?, offsets: ZstandardFSETable?, matchLengths: ZstandardFSETable?
    private var recent = (1, 4, 8)

    deinit { literals.deallocate() }

    /// Forgets what earlier blocks handed on, as a new frame starts.
    func startFrame() {
        huffman = nil
        literalLengths = nil; offsets = nil; matchLengths = nil
        recent = (1, 4, 8)
    }

    /// Decodes the `count` bytes of a compressed block at `block` into `output` from `position`, and returns where its
    /// text ends. `output` holds the frame's text from its start or from a window's length back; the block's text holds at
    /// most `limit` bytes. The 7 bytes after the block must be readable.
    func decode(_ block: UnsafePointer<UInt8>, count: Int, into output: UnsafeMutablePointer<UInt8>, at position: Int,
                limit: Int) throws -> Int {
        let length = try readLiterals(block, count: count, limit: limit)
        return try execute(block + length, count: count - length, into: output, at: position, limit: limit)
    }

    /// Decodes the block's literals section into `literals`; returns the section's length.
    private func readLiterals(_ block: UnsafePointer<UInt8>, count: Int, limit: Int) throws -> Int {
        guard count >= 1 else { throw ZstandardError.corrupt }
        let first = Int(block[0]), type = first & 3, format = (first >> 2) & 3
        if type < 2 {
            // Raw or RLE literals: a size of 5, 12 or 20 bits.
            let header: Int, size: Int
            switch format {
            case 1:
                guard count >= 2 else { throw ZstandardError.corrupt }
                header = 2; size = (first >> 4) + (Int(block[1]) << 4)
            case 3:
                guard count >= 3 else { throw ZstandardError.corrupt }
                header = 3; size = (first >> 4) + (Int(block[1]) << 4) + (Int(block[2]) << 12)
            default:
                header = 1; size = first >> 3
            }
            guard size <= limit else { throw ZstandardError.corrupt }
            literalCount = size
            if type == 0 {
                guard header + size <= count else { throw ZstandardError.corrupt }
                literals.update(from: block + header, count: size)
                return header + size
            }
            guard header < count else { throw ZstandardError.corrupt }
            literals.update(repeating: block[header], count: size)
            return header + 1
        }
        // Huffman-coded literals, with a table of their own or the previous block's, in 1 or 4 streams.
        let header = format < 2 ? 3 : format + 2, width = format < 2 ? 10 : 4 * format + 6
        guard count >= header else { throw ZstandardError.corrupt }
        var fields = 0
        for index in 0..<header { fields |= Int(block[index]) << (8 * index) }
        let size = (fields >> 4) & ((1 << width) - 1), compressed = (fields >> (4 + width)) & ((1 << width) - 1)
        guard size <= limit, header + compressed <= count else { throw ZstandardError.corrupt }
        var start = header
        if type == 2 {
            let (table, length) = try ZstandardHuffmanTable.read(block + start, count: compressed)
            huffman = table
            start += length
        }
        guard let huffman else { throw ZstandardError.corrupt }
        let streams = header + compressed - start
        if format == 0 {
            try huffman.decode(block + start, count: streams, symbols: size, into: literals)
        } else {
            // A jump table gives the first three streams' sizes; each of them decodes a quarter, rounded up.
            guard streams >= 10 else { throw ZstandardError.corrupt }
            func size16(_ at: Int) -> Int { Int(block[start + at]) | Int(block[start + at + 1]) << 8 }
            let sizes = [size16(0), size16(2), size16(4)]
            let quarter = (size + 3) / 4, last = streams - 6 - sizes.reduce(0, +)
            guard last >= 1, size >= 3 * quarter else { throw ZstandardError.corrupt }
            var stream = block + start + 6
            for (index, length) in (sizes + [last]).enumerated() {
                try huffman.decode(stream, count: length, symbols: index < 3 ? quarter : size - 3 * quarter,
                                   into: literals + index * quarter)
                stream += length
            }
        }
        literalCount = size
        return header + compressed
    }

    /// Decodes the sequences section and writes the block's text: each sequence copies literals, then a match from
    /// earlier text; the literals left after the last sequence end the block.
    private func execute(_ section: UnsafePointer<UInt8>, count: Int, into output: UnsafeMutablePointer<UInt8>, at start: Int,
                         limit: Int) throws -> Int {
        guard count >= 1 else { throw ZstandardError.corrupt }
        let first = Int(section[0])
        var sequences: Int, read: Int
        if first < 128 {
            sequences = first; read = 1
        } else if first < 255 {
            guard count >= 2 else { throw ZstandardError.corrupt }
            sequences = ((first - 128) << 8) + Int(section[1]); read = 2
        } else {
            guard count >= 3 else { throw ZstandardError.corrupt }
            sequences = Int(section[1]) + (Int(section[2]) << 8) + 0x7F00; read = 3
        }
        let end = start + limit
        var position = start, literal = 0
        if sequences == 0 {
            guard read == count else { throw ZstandardError.corrupt }
        } else {
            guard read < count else { throw ZstandardError.corrupt }
            let modes = section[read]
            read += 1
            guard modes & 3 == 0 else { throw ZstandardError.corrupt }
            let lengths = try ZstandardFSETable.read(mode: modes >> 6, section + read, count: count - read,
                predefined: .literalLengths, previous: literalLengths, largestSymbol: 35, largestAccuracyLog: 9)
            read += lengths.length
            let distances = try ZstandardFSETable.read(mode: (modes >> 4) & 3, section + read, count: count - read,
                predefined: .offsets, previous: offsets, largestSymbol: 31, largestAccuracyLog: 8)
            read += distances.length
            let matches = try ZstandardFSETable.read(mode: (modes >> 2) & 3, section + read, count: count - read,
                predefined: .matchLengths, previous: matchLengths, largestSymbol: 52, largestAccuracyLog: 9)
            read += matches.length
            literalLengths = lengths.table; offsets = distances.table; matchLengths = matches.table
            var bits = try ZstandardBackwardBits(section + read, count: count - read)
            var recent = recent
            let literals = literals, literalCount = literalCount
            try lengths.table.entries.withUnsafeBufferPointer { lengthTable in
                try distances.table.entries.withUnsafeBufferPointer { offsetTable in
                    try matches.table.entries.withUnsafeBufferPointer { matchTable in
                        var lengthState = bits.read(lengths.table.accuracyLog)
                        var offsetState = bits.read(distances.table.accuracyLog)
                        var matchState = bits.read(matches.table.accuracyLog)
                        for index in 0..<sequences {
                            let lengthEntry = lengthTable[lengthState], offsetEntry = offsetTable[offsetState]
                            let matchEntry = matchTable[matchState]
                            // Extra bits come offset first, then match length, then literal length.
                            let offsetCode = Int(offsetEntry.symbol)
                            let offsetValue = (1 << offsetCode) + bits.read(offsetCode)
                            let matchCode = Int(matchEntry.symbol), lengthCode = Int(lengthEntry.symbol)
                            let matchLength = ZstandardLengthCodes.matchBase[matchCode] + bits.read(ZstandardLengthCodes.matchBits[matchCode])
                            let literalLength = ZstandardLengthCodes.literalBase[lengthCode]
                                + bits.read(ZstandardLengthCodes.literalBits[lengthCode])
                            // Values 1 to 3 name a recent offset, shifted by one after a sequence without literals.
                            let offset: Int
                            if offsetValue > 3 {
                                offset = offsetValue - 3
                                recent = (offset, recent.0, recent.1)
                            } else {
                                let which = offsetValue - (literalLength == 0 ? 0 : 1)
                                switch which {
                                case 0: offset = recent.0
                                case 1: offset = recent.1; recent = (offset, recent.0, recent.2)
                                case 2: offset = recent.2; recent = (offset, recent.0, recent.1)
                                default: offset = recent.0 - 1; recent = (offset, recent.0, recent.1)
                                }
                            }
                            if index + 1 < sequences {
                                lengthState = Int(lengthEntry.base) + bits.read(Int(lengthEntry.bits))
                                matchState = Int(matchEntry.base) + bits.read(Int(matchEntry.bits))
                                offsetState = Int(offsetEntry.base) + bits.read(Int(offsetEntry.bits))
                            }
                            guard literalLength <= literalCount - literal, matchLength <= end - position - literalLength
                            else { throw ZstandardError.corrupt }
                            (output + position).update(from: literals + literal, count: literalLength)
                            position += literalLength
                            literal += literalLength
                            guard offset > 0, offset <= position else { throw ZstandardError.corrupt }
                            // A match closer than its length repeats itself: copy what is already there, doubling.
                            let source = position - offset
                            var copied = 0
                            while copied < matchLength {
                                let length = min(position + copied - source, matchLength - copied)
                                (output + position + copied).update(from: output + source, count: length)
                                copied += length
                            }
                            position += matchLength
                        }
                    }
                }
            }
            guard bits.finished else { throw ZstandardError.corrupt }
            self.recent = recent
        }
        let rest = literalCount - literal
        guard rest <= end - position else { throw ZstandardError.corrupt }
        (output + position).update(from: literals + literal, count: rest)
        return position + rest
    }
}
