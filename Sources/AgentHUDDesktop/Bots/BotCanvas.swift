import CoreGraphics
import Foundation

/// The bitmaps bot frames are drawn in, kept from one frame to the next.
///
/// A frame is small, but a new bitmap for every one was mapped, zeroed and unmapped again, which cost a twentieth
/// of drawing the bot. A kept bitmap is only cleared, and each frame's picture is still a copy of its own.
@MainActor
enum BotCanvas {
    private struct Key: Hashable {
        var side: Int
        var space: CGColorSpace
    }

    /// Premultiplied blue, green, red and alpha in memory, the way a display's pixels are kept.
    static let layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    private static var kept: [Key: CGContext] = [:]
    /// More sizes than this means the marks are being resized; the next ones start afresh.
    private static let most = 8

    /// A clear bitmap `side` pixels square, in the byte order and the colours of the display it is for. A layer
    /// given any other picture draws it once more, through a colour conversion, before it can show it: for a
    /// bot that is drawn again with every blink, that cost as much as drawing the bot.
    ///
    /// - space: the display's colours; sRGB when it is not known or not RGB.
    static func clear(_ side: Int, space: CGColorSpace?) -> CGContext? {
        let space = space.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let key = Key(side: side, space: space)
        if let context = kept[key], let data = context.data {
            memset(data, 0, context.bytesPerRow * context.height)
            return context
        }
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: layout.rawValue)
                ?? CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layout.rawValue)
        else { return nil }
        if kept.count >= most { kept = [:] }
        kept[key] = context
        return context
    }

    /// Lets every kept bitmap go, so the next frame is drawn in a new one.
    static func forget() { kept = [:] }
}
