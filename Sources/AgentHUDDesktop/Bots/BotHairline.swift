import Accelerate
import CoreGraphics
import Foundation

/// The dark hairline round a bot that sits on a wallpaper beside the logo queue's outlined marks: the bot's
/// silhouette spread by a pixel, hardened so a soft edge still gives a crisp line, and laid behind the bot at
/// half strength.
///
/// The marks build theirs once, from masks. A bot is drawn again whenever it blinks, so its hairline comes from
/// the picture's own alpha instead, spread by Accelerate. Laid behind the bot by Core Graphics, through a mask,
/// it cost a seventh of a frame, most of it a mask bitmap made and thrown away every time, so Accelerate lays it
/// too: dark laid behind a pixel leaves its colour as it was and raises its alpha, one blend of two alpha planes.
/// Core Graphics is asked once what it makes of every pair of alphas, and Accelerate lays the hairline only if it
/// gives the very same bytes.
@MainActor
enum BotHairline {
    /// Darkens the pixels just outside the bot drawn in `context`, a square bitmap from `BotCanvas`.
    ///
    /// - byCoreGraphics: lays it the way it was laid before Accelerate did, to hold the two against each other.
    static func lay(on context: CGContext, reach: Int, byCoreGraphics: Bool = false) {
        guard let data = context.data else { return }
        let side = context.width, count = side * side, size = vImagePixelCount(side)
        // A frame is far too small to be worth splitting across threads, which is what vImage does unasked.
        let flags = vImage_Flags(kvImageDoNotTile)
        // One block for the bot's alpha, the hairline behind each pixel, and the alpha the two make.
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
        defer { scratch.deallocate() }
        var picture = vImage_Buffer(data: data, height: size, width: size, rowBytes: context.bytesPerRow)
        var own = vImage_Buffer(data: scratch, height: size, width: size, rowBytes: side)
        var spread = vImage_Buffer(data: scratch + count, height: size, width: size, rowBytes: side)
        var laid = vImage_Buffer(data: scratch + count * 2, height: size, width: size, rowBytes: side)
        let kernel = vImagePixelCount(2 * reach + 1)
        // A frame's pixels are blue, green, red, alpha in memory: alpha is the fourth byte.
        guard vImageExtractChannel_ARGB8888(&picture, &own, 3, flags) == kvImageNoError,
              vImageMax_Planar8(&own, &spread, nil, 0, 0, kernel, kernel, flags) == kvImageNoError
        else { return }
        guard !byCoreGraphics, let strength = strengths(for: context) else {
            vImageTableLookUp_Planar8(&spread, &spread, harder, flags)
            return layWithCoreGraphics(scratch + count, on: context)
        }
        guard vImageTableLookUp_Planar8(&spread, &spread, strength, flags) == kvImageNoError,
              vImagePremultipliedAlphaBlend_Planar8(&own, &own, &spread, &laid, flags) == kvImageNoError
        else { return }
        // A copy mask counts a pixel's bytes from the right.
        vImageOverwriteChannels_ARGB8888(&laid, &picture, &picture, 0x1, flags)
    }

    /// Alpha tripled: the spread silhouette's soft edge made crisp.
    private static let harder: [UInt8] = (0..<256).map { UInt8(min(255, $0 * 3)) }

    /// Lays `mask`, one byte a pixel in the bitmap's own row order, behind what `context` holds, the way the
    /// hairline was laid before Accelerate laid it: black at half strength, through the mask.
    private static func layWithCoreGraphics(_ mask: UnsafePointer<UInt8>, on context: CGContext) {
        let width = context.width, height = context.height
        guard let provider = CGDataProvider(data: Data(bytes: mask, count: width * height) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.saveGState()
        context.setBlendMode(.destinationOver)
        context.setAlpha(LogoImages.outlineOpacity)
        context.clip(to: whole, mask: image)
        context.setFillColor(.black)
        context.fill(whole)
        context.restoreGState()
    }

    // MARK: Matching Core Graphics

    private static var tables: [CGColorSpace: [UInt8]?] = [:]

    /// How strongly the hairline lies behind a pixel, for each value of the spread silhouette: hardened, then
    /// at the half strength Core Graphics lays it at. Nil when Accelerate's blend would not give the bytes Core
    /// Graphics gives, or for a bitmap laid out other than `BotCanvas` lays its own; the hairline is then laid
    /// through Core Graphics.
    static func strengths(for context: CGContext) -> [UInt8]? {
        guard context.bitsPerPixel == 32, context.bitmapInfo == BotCanvas.layout, let space = context.colorSpace else { return nil }
        if let known = tables[space] { return known }
        let table = matched(in: space)
        tables[space] = table
        return table
    }

    /// Lays every strength of mask behind every alpha through Core Graphics, then blends the same pairs with
    /// Accelerate, and gives the strengths if the two agree on every byte.
    private static func matched(in space: CGColorSpace) -> [UInt8]? {
        // Row by row the probe's alpha rises, over some colour that the hairline should leave as it was; column by
        // column the mask behind it grows stronger.
        guard let probe = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                    space: space, bitmapInfo: BotCanvas.layout.rawValue),
              let data = probe.data
        else { return nil }
        let count = 256 * 256, flags = vImage_Flags(kvImageDoNotTile)
        let planes = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3), expected = UnsafeMutableRawPointer.allocate(byteCount: count * 4, alignment: 16)
        defer { planes.deallocate(); expected.deallocate() }
        let alphas = planes, masks = planes + count, blended = planes + count * 2
        let rising = [UInt8](0...255)
        for row in 0..<256 {
            var pixel = [UInt8(row), UInt8(row / 2), UInt8(row / 3), UInt8(row)]
            memset_pattern4(data + row * 256 * 4, &pixel, 256 * 4)
            memset(alphas + row * 256, Int32(row), 256)
            rising.withUnsafeBytes { _ = memcpy(masks + row * 256, $0.baseAddress!, 256) }
        }
        memcpy(expected, data, count * 4)
        layWithCoreGraphics(masks, on: probe)

        // Over nothing, what Core Graphics lays is the hairline's own strength.
        let pixels = data.assumingMemoryBound(to: UInt8.self), laid = rising.map { pixels[Int($0) * 4 + 3] }
        for row in 0..<256 { laid.withUnsafeBytes { _ = memcpy(masks + row * 256, $0.baseAddress!, 256) } }
        var top = vImage_Buffer(data: alphas, height: 256, width: 256, rowBytes: 256)
        var bottom = vImage_Buffer(data: masks, height: 256, width: 256, rowBytes: 256)
        var result = vImage_Buffer(data: blended, height: 256, width: 256, rowBytes: 256)
        var wanted = vImage_Buffer(data: expected, height: 256, width: 256, rowBytes: 256 * 4)
        guard vImagePremultipliedAlphaBlend_Planar8(&top, &top, &bottom, &result, flags) == kvImageNoError,
              vImageOverwriteChannels_ARGB8888(&result, &wanted, &wanted, 0x1, flags) == kvImageNoError,
              memcmp(expected, data, count * 4) == 0
        else { return nil }
        return harder.map { laid[Int($0)] }
    }
}
