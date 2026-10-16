import Accelerate
import CoreGraphics
import Foundation
@testable import AgentHUDDesktop

/// The outline and the hairline as a bot's frames drew them before either was made cheaper, kept unchanged so
/// the rewritten ones can be held to them. Neither shares code with the renderer's own.
@MainActor
enum BotFramesAsBefore {
    /// The outline at one moment of the morph, built a point at a time from the angle.
    static func outline(_ form: BotForm, eased: CGFloat, turn: CGFloat) -> CGPath {
        let path = CGMutablePath(), count = BotForm.samples, center = form.spec.center
        for index in 0..<count {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
            // The body turns under the face, so its reach is read `turn` degrees back.
            var from = (CGFloat(index) - turn).truncatingRemainder(dividingBy: CGFloat(count))
            if from < 0 { from += CGFloat(count) }
            let low = Int(from) % count, part = from - CGFloat(Int(from))
            let body = form.bodyReach[low] + (form.bodyReach[(low + 1) % count] - form.bodyReach[low]) * part
            let reach = form.logoReach[index] + (body - form.logoReach[index]) * eased
            let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// The hairline spread by a dilation and laid behind the bot by Core Graphics, through a mask.
    static func hairline(on context: CGContext, extent: Int, reach: Int) {
        guard let data = context.data else { return }
        let count = extent * extent, size = vImagePixelCount(extent), none = vImage_Flags(kvImageNoFlags)
        let alpha = UnsafeMutablePointer<UInt8>.allocate(capacity: count), spread = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { alpha.deallocate(); spread.deallocate() }
        var picture = vImage_Buffer(data: data, height: size, width: size, rowBytes: context.bytesPerRow)
        var own = vImage_Buffer(data: alpha, height: size, width: size, rowBytes: extent)
        var ring = vImage_Buffer(data: spread, height: size, width: size, rowBytes: extent)
        let side = 2 * reach + 1, flat = [UInt8](repeating: 0, count: side * side)
        guard vImageExtractChannel_ARGB8888(&picture, &own, 3, none) == kvImageNoError,
              vImageDilate_Planar8(&own, &ring, 0, 0, flat, vImagePixelCount(side), vImagePixelCount(side), none) == kvImageNoError
        else { return }
        let harder = (0..<256).map { UInt8(min(255, $0 * 3)) }
        vImageTableLookUp_Planar8(&ring, &ring, harder, none)
        guard let provider = CGDataProvider(data: Data(bytes: spread, count: count) as CFData),
              let mask = CGImage(width: extent, height: extent, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: extent,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let whole = CGRect(x: 0, y: 0, width: extent, height: extent)
        context.saveGState()
        context.setBlendMode(.destinationOver)
        context.setAlpha(LogoImages.outlineOpacity)
        context.clip(to: whole, mask: mask)
        context.setFillColor(.black)
        context.fill(whole)
        context.restoreGState()
    }

    /// A frame drawn with room for its hairline but without it, with the hairline then laid as it was before.
    static func hairlined(_ bare: CGContext, reach: Int) -> CGImage? {
        let extent = bare.width
        guard bare.height == extent, let space = bare.colorSpace, let from = bare.data,
              let context = CGContext(data: nil, width: extent, height: extent, bitsPerComponent: 8, bytesPerRow: bare.bytesPerRow,
                                      space: space, bitmapInfo: bare.bitmapInfo.rawValue),
              let data = context.data
        else { return nil }
        memcpy(data, from, bare.bytesPerRow * extent)
        hairline(on: context, extent: extent, reach: reach)
        return context.makeImage()
    }

    /// A path's elements and the bits of their points, to compare two paths exactly.
    static func elements(of path: CGPath) -> [UInt] {
        var elements: [UInt] = []
        path.applyWithBlock { element in
            let kind = element.pointee.type, points: Int
            switch kind {
            case .moveToPoint, .addLineToPoint: points = 1
            case .addQuadCurveToPoint: points = 2
            case .addCurveToPoint: points = 3
            case .closeSubpath: points = 0
            @unknown default: points = 0
            }
            elements.append(UInt(kind.rawValue))
            for index in 0..<points {
                let point = element.pointee.points[index]
                elements += [point.x.bitPattern, point.y.bitPattern]
            }
        }
        return elements
    }
}
