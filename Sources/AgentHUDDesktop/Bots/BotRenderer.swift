import AppKit
import AgentHUDCore
import CoreGraphics

/// Draws one frame of a bot: wherever its motion says it is between the logo and the bot, with the eyes it
/// has at that moment. The frame is the bot standing still and upright; how it sits — hopping, leaning,
/// breathing — is a transform the caller applies to the layer, so a breath never costs a redraw.
@MainActor
enum BotRenderer {
    /// Room round the mark for what overflows it — ears, a hat, a ring, rays on their way in — as a share of
    /// the mark's side on every edge.
    static let margin: CGFloat = 0.3

    /// What a frame depends on, in steps finer than the eye can tell apart. Two motions with the same look
    /// draw the same picture, so a bot that has not visibly changed is not drawn again.
    struct Look: Hashable {
        var morph, turn, open, look, lookY, wide, happy, lean, lift, scale: Int
    }

    static func look(of motion: BotMotion) -> Look {
        let face = motion.face
        func step(_ value: CGFloat, _ steps: CGFloat) -> Int { Int((value * steps).rounded()) }
        return Look(morph: step(motion.morph, 60), turn: step(motion.turn, 0.5), open: step(face.open, 40),
                    look: step(face.look, 50), lookY: step(face.lookY, 50), wide: step(face.wide, 50),
                    happy: step(face.happy, 30), lean: step(face.lean, 30),
                    lift: step(motion.kept.lift, 300), scale: step(motion.kept.scale, 60))
    }

    /// The island's own dark: eyes drawn in it read as cut out of any body, on the island or over a wallpaper.
    private static let ink = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    private static let box = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// One frame, `side` pixels to the mark's side, with `margin` of room on every edge.
    ///
    /// - outline: pixels of dark hairline round the bot, for a bot that sits on a wallpaper beside the logo
    ///   queue's outlined marks. The picture grows by that much on every edge.
    /// - space: the colours of the display the frame is shown on; sRGB when it is not known.
    static func image(_ form: BotForm, motion: BotMotion, side: CGFloat, outline: Int = 0, space: CGColorSpace? = nil) -> CGImage? {
        guard let context = bare(form, motion: motion, side: side, outline: outline, space: space) else { return nil }
        if outline > 0 { BotHairline.lay(on: context, reach: outline) }
        return context.makeImage()
    }

    /// The frame without its hairline, with `outline` pixels of room left for one on every edge, in the kept
    /// bitmap the next frame is drawn in.
    static func bare(_ form: BotForm, motion: BotMotion, side: CGFloat, outline: Int, space: CGColorSpace?) -> CGContext? {
        let inner = Int((side * (1 + 2 * margin)).rounded(.up)), extent = inner + outline * 2
        guard inner > 0, let context = BotCanvas.clear(extent, space: space) else { return nil }
        context.saveGState()
        // From here one unit is the mark's side, measured from its top left with y running down.
        let unit = CGFloat(inner) / (1 + 2 * margin)
        context.translateBy(x: CGFloat(outline), y: CGFloat(extent - outline))
        context.scaleBy(x: unit, y: -unit)
        context.translateBy(x: margin, y: margin)
        context.interpolationQuality = .high

        if let eyes = form.spec.ownEyes {
            context.setAlpha(1 - motion.morph)
            draw(form.artwork, in: box, on: context)
            if motion.morph > 0 {
                // Blend the complete eye animation as one picture: its drawing sets its own alpha.
                context.setAlpha(motion.morph)
                context.setBlendMode(.plusLighter)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(form.stripped ?? form.artwork, in: box, on: context)
                ownEyes(eyes, face: motion.face, on: context)
                context.endTransparencyLayer()
            }
        } else {
            body(form, motion: motion, on: context)
        }
        context.restoreGState()
        return context
    }

    // MARK: The morph

    /// How far each part of a body has come through the morph. Worked out once a frame, so the still part kept
    /// from an earlier frame and the part drawn over it follow the same curves.
    private struct Morph {
        /// How far the logo has turned into the bot, from 0 to 1.
        let share: CGFloat
        /// The share eased in and out: how far the outline has come and how far the body has settled.
        let eased: CGFloat
        /// The body's colour field, solid well before the outline has arrived.
        let solid: CGFloat
        /// What the body wears, which arrives with the eyes.
        let dressed: CGFloat

        init(_ share: CGFloat) {
            self.share = share
            eased = BotMotion.easeInOut(share)
            solid = min(1, share / 0.22)
            dressed = max(0, min(1, (share - 0.45) / 0.45))
        }

        /// The logo stays where it is; the bot it turns into may settle a little above or below it.
        func settle(_ spec: BotSpec, on context: CGContext) {
            context.translateBy(x: 0, y: spec.settle * eased)
        }
    }

    /// A body's frame: its still part, kept from an earlier frame when nothing has moved it, then what moves
    /// with the face.
    private static func body(_ form: BotForm, motion: BotMotion, on context: CGContext) {
        let spec = form.spec, morph = Morph(motion.morph), radius = spec.radius
        // Everything drawn before a kept piece, or before a piece that rides with the face, moves with the morph
        // and the turn alone. A bot that does not spin draws that part once and then only what its face changes.
        let settled = spec.keeps == nil ? spec.decor.firstIndex { $0.followsFace } ?? spec.decor.count : 0
        let still = BotStill(form: form, morph: morph.share, turn: motion.turn, on: context)
        if !still.restore() {
            context.saveGState()
            stillPart(form, morph: morph, turn: motion.turn, decor: settled, on: context)
            context.restoreGState()
            still.keep()
        }

        morph.settle(spec, on: context)
        if let kept = spec.keeps {
            context.saveGState()
            context.setAlpha(morph.solid)
            context.translateBy(x: kept.midX, y: kept.midY - motion.kept.lift)
            context.scaleBy(x: motion.kept.scale, y: motion.kept.scale)
            context.translateBy(x: -kept.midX, y: -kept.midY)
            context.clip(to: kept.insetBy(dx: -0.01, dy: -0.01))
            draw(form.artwork, in: box, on: context)
            context.restoreGState()
        }

        guard morph.dressed > 0 else { return }
        let face = motion.face, turn = spec.reach * 0.72
        let yaw = max(-1.15, min(1.15, face.look)) * turn, pitch = max(-1.15, min(1.15, face.lookY)) * turn
        let glance = CGPoint(x: sin(yaw) * radius * 0.72, y: sin(pitch) * radius * 0.62)
        if spec.keeps != nil {
            wear(spec, outline: form.outline(eased: morph.eased, turn: motion.turn), strength: morph.dressed, on: context)
        }
        for item in spec.decor[settled...] {
            decorate(item, spec: spec, offset: item.followsFace ? glance : .zero, strength: morph.dressed, on: context)
        }
        eyes(spec, face: face, yaw: yaw, pitch: pitch, awake: morph.dressed, on: context)
    }

    /// The part of a body that only the morph and the turn change: the logo fading out, the body and its
    /// paint, a ring, and what it wears up to the first piece that moves with its face. `decor` counts the
    /// pieces of `spec.decor` drawn here; a body with a kept piece draws none here, as that piece comes first.
    private static func stillPart(_ form: BotForm, morph: Morph, turn: CGFloat, decor: Int, on context: CGContext) {
        let spec = form.spec, share = morph.share, eased = morph.eased, solid = morph.solid, dressed = morph.dressed
        let center = spec.center, radius = spec.radius
        // The artwork fades into the colour field while the outline is still close to the logo's.
        let artwork = 1 - min(1, share / 0.4)
        if artwork > 0 {
            context.setAlpha(artwork)
            draw(form.artwork, in: box, on: context)
        }
        morph.settle(spec, on: context)
        let outline = form.outline(eased: eased, turn: turn)

        // A ring goes on in two passes: all of it first, so the body covers the far side; then the near side
        // drawn across the body.
        let ringShare = spec.ring == nil ? 0 : max(0, min(1, (share - 0.5) / 0.5))
        if let ring = spec.ring, ringShare > 0 {
            context.setAlpha(ringShare)
            context.setStrokeColor(.white)
            context.setLineWidth(ring.width * radius)
            context.setLineCap(.round)
            context.addPath(ringPath(ring, spec: spec, grown: ringShare, nearSideOnly: false))
            context.strokePath()
        }

        // Feelers go on before the body, which then covers where they start.
        for item in spec.decor where dressed > 0 {
            guard case .feelers(let lines, let paint, let width) = item else { continue }
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: radius, y: radius)
            context.setAlpha(dressed)
            context.setStrokeColor(color(paint))
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            for line in lines { context.addLines(between: line) }
            context.strokePath()
            context.restoreGState()
        }

        context.setAlpha(solid)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        fill(spec.paint, form: form, on: context)
        if let patch = spec.patch {
            // The face panel grows in with the morph.
            let width = patch.box.width * radius, height = patch.box.height * radius
            let corner = min(patch.round * radius, min(width, height) / 2)
            context.saveGState()
            context.translateBy(x: center.x + patch.box.midX * radius, y: center.y + patch.box.midY * radius)
            context.scaleBy(x: 0.4 + 0.6 * eased, y: 0.4 + 0.6 * eased)
            context.setAlpha(solid * max(0, min(1, (share - 0.2) / 0.4)))
            context.addPath(CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                   cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.clip()
            fill(patch.paint, form: form, on: context, origin: CGPoint(x: -center.x - patch.box.midX * radius,
                                                                       y: -center.y - patch.box.midY * radius))
            context.restoreGState()
        }
        if let stroke = spec.stroke {
            context.setStrokeColor(color(stroke))
            context.setLineWidth(0.07)
            context.setLineJoin(.round)
            context.addPath(outline)
            context.strokePath()
        }
        context.restoreGState()

        if let ring = spec.ring, ringShare > 0 {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.setAlpha(ringShare)
            context.setStrokeColor(ink)
            context.setLineWidth(ring.width * radius)
            context.setLineCap(.butt)
            context.addPath(ringPath(ring, spec: spec, grown: ringShare, nearSideOnly: true))
            context.strokePath()
            context.restoreGState()
        }

        guard spec.keeps == nil, dressed > 0 else { return }
        wear(spec, outline: outline, strength: dressed, on: context)
        for item in spec.decor.prefix(decor) { decorate(item, spec: spec, offset: .zero, strength: dressed, on: context) }
    }

    /// One piece a body wears over its outline, `offset` from where it sits on the body.
    private static func decorate(_ item: BotSpec.Decor, spec: BotSpec, offset: CGPoint, strength: CGFloat,
                                 on context: CGContext) {
        context.saveGState()
        context.translateBy(x: spec.center.x + offset.x, y: spec.center.y + offset.y)
        context.scaleBy(x: spec.radius, y: spec.radius)
        context.setAlpha(strength)
        switch item {
        case .blocks(let rects, let paint, _):
            context.setFillColor(color(paint))
            context.fill(rects)
        case .cut(let rects):
            context.setBlendMode(.destinationOut)
            context.setFillColor(.black)
            context.fill(rects)
        case .notch(let points):
            context.setBlendMode(.destinationOut)
            context.setFillColor(.black)
            context.addLines(between: points)
            context.closePath()
            context.fillPath()
        case .line(let points, let width):
            context.setStrokeColor(ink)
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.addLines(between: points)
            context.strokePath()
        case .soft, .feelers:
            break
        }
        context.restoreGState()
    }

    /// The soft pieces a body wears, kept to its outline: a fringe, a scarf. Sizes are in body radii from
    /// the body's centre.
    private static func wear(_ spec: BotSpec, outline: CGPath, strength: CGFloat, on context: CGContext) {
        for item in spec.decor {
            guard case .soft(let rects, let paint, let round) = item else { continue }
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.translateBy(x: spec.center.x, y: spec.center.y)
            context.scaleBy(x: spec.radius, y: spec.radius)
            context.setAlpha(strength)
            context.setFillColor(color(paint))
            for rect in rects {
                let corner = min(rect.width, rect.height) / 2 * round
                context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            }
            context.fillPath()
            context.restoreGState()
        }
    }

    private static func ringPath(_ ring: BotSpec.Ring, spec: BotSpec, grown: CGFloat, nearSideOnly: Bool) -> CGPath {
        let path = CGMutablePath(), radius = spec.radius, size = 0.5 + 0.5 * grown
        let tilt = ring.tilt * .pi / 180, steps = 48
        let sweep = nearSideOnly ? CGFloat.pi : 2 * CGFloat.pi
        for step in 0...steps {
            let angle = sweep * CGFloat(step) / CGFloat(steps)
            let x = ring.radiusX * radius * size * cos(angle), y = ring.radiusY * radius * size * sin(angle)
            let point = CGPoint(x: spec.center.x + x * cos(tilt) - y * sin(tilt),
                                y: spec.center.y + ring.drop * radius + x * sin(tilt) + y * cos(tilt))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if !nearSideOnly { path.closeSubpath() }
        return path
    }

    /// Paints the current clip. `origin` moves the mark's coordinates when the context has been re-centred.
    private static func fill(_ paint: BotSpec.Paint, form: BotForm, on context: CGContext, origin: CGPoint = .zero) {
        let spec = form.spec
        func at(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + spec.center.x + (point.x - 0.5) * 2 * spec.radius,
                    y: origin.y + spec.center.y + (point.y - 0.5) * 2 * spec.radius)
        }
        let everything = CGRect(x: origin.x - 0.3, y: origin.y - 0.3, width: 1.6, height: 1.6)
        let both: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch paint {
        case .artwork:
            if let field = form.field {
                draw(field, in: CGRect(x: origin.x - 0.25, y: origin.y - 0.25, width: 1.5, height: 1.5), on: context)
            } else {
                context.setFillColor(.white)
                context.fill(everything)
            }
        case .solid(let value):
            context.setFillColor(color(value))
            context.fill(everything)
        case .linear(let from, let to, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawLinearGradient(gradient, start: at(from), end: at(to), options: both)
        case .radial(let center, let inner, let outer, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawRadialGradient(gradient, startCenter: at(center), startRadius: inner * 2 * spec.radius,
                                       endCenter: at(center), endRadius: outer * 2 * spec.radius, options: both)
        }
    }

    // MARK: Eyes

    /// Two small eyes that sit on the body as on a ball: turning the gaze slides them across it and narrows
    /// the far one, so the body reads as a head looking somewhere. They stay upright.
    private static func eyes(_ spec: BotSpec, face: BotFace, yaw: CGFloat, pitch: CGFloat, awake: CGFloat,
                             on context: CGContext) {
        let radius = spec.radius, size: CGFloat = 0.78, spread = spec.eye.spread
        let paint = spec.eyeColor.map(color) ?? ink
        // A smile is sized from how far apart the eyes are right now, so two never join into one line.
        let apart = (sin(yaw + spread) - sin(yaw - spread)) * radius * 0.76
        for side in [-1.0, 1.0] as [CGFloat] {
            let angle = yaw + side * spread
            let x = spec.center.x + spec.face.x * radius + sin(angle) * radius * 0.76
            let y = spec.center.y + spec.face.y * radius + sin(pitch) * radius * 0.62
            let narrow = pow(max(0.25, cos(angle)), 1.4), tall = (0.72 + 0.28 * cos(angle)) * pow(cos(pitch), 0.5)
            let big = (1 + 0.26 * side * face.lean) * face.wide * (0.6 + 0.4 * awake) * size
            let width = spec.eye.width * radius * big * narrow
            let height = spec.eye.height * radius * big * tall * max(0.08, face.open) * awake
            context.saveGState()
            context.translateBy(x: x, y: y)
            if face.happy < 0.98 {
                context.setAlpha(1 - face.happy)
                context.setFillColor(paint)
                context.addPath(pill(width, max(height, width * 0.16), round: spec.eye.round))
                context.fillPath()
                if let pupil = spec.pupil, height > width * 0.45 {
                    context.setFillColor(color(pupil))
                    let across = width * 0.21, down = min(height, width) * 0.21
                    context.fillEllipse(in: CGRect(x: face.look * width * 0.2 - across,
                                                   y: face.lookY * height * 0.2 - height * 0.06 - down,
                                                   width: across * 2, height: down * 2))
                }
            }
            if face.happy > 0.02 {
                let stroke = min(spec.eye.width * radius * 0.58 * size, apart * 0.2)
                let half = max(stroke * 0.7, min(spec.eye.width * radius * 0.8 * size, apart / 2 - stroke * 1.05)) * max(0.6, narrow)
                smile(half: half, stroke: stroke, paint: paint, strength: face.happy, on: context)
            }
            context.restoreGState()
        }
    }

    /// Eyes that belong to the artwork: drawn where the mark draws them, in the mark's own light ink.
    private static func ownEyes(_ eyes: [CGRect], face: BotFace, on context: CGContext) {
        guard let first = eyes.first, let last = eyes.last else { return }
        let middle = (first.midX + last.midX) / 2, apart = abs(last.midX - first.midX)
        for eye in eyes {
            let side: CGFloat = eye.midX > middle ? 1 : -1
            let big = (1 + 0.26 * side * face.lean) * face.wide
            let width = eye.width * big, height = eye.height * big * max(0.06, face.open)
            context.saveGState()
            context.translateBy(x: eye.midX + min(0.04, eye.width * 0.45) * face.look,
                                y: eye.midY + min(0.03, eye.height * 0.14) * face.lookY)
            if face.happy < 0.98 {
                context.setAlpha(1 - face.happy)
                context.setFillColor(.white)
                context.addPath(pill(width, max(height, width * 0.16), round: 1))
                context.fillPath()
            }
            if face.happy > 0.02 {
                smile(half: min(eye.width * 0.95, apart * 0.3), stroke: min(eye.width * 0.6, apart * 0.2),
                      paint: .white, strength: face.happy, on: context)
            }
            context.restoreGState()
        }
    }

    /// An arch whose top points up the face, about the current origin.
    private static func smile(half: CGFloat, stroke: CGFloat, paint: CGColor, strength: CGFloat, on context: CGContext) {
        let rise = half * 0.95
        context.setAlpha(strength)
        context.setStrokeColor(paint)
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: -half, y: rise * 0.45))
        context.addQuadCurve(to: CGPoint(x: half, y: rise * 0.45), control: CGPoint(x: 0, y: -rise * 1.1))
        context.strokePath()
    }

    private static func pill(_ width: CGFloat, _ height: CGFloat, round: CGFloat) -> CGPath {
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let corner = min(width, height) / 2 * round
        return corner > 0.0005 ? CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    // MARK: Pieces

    /// An image the right way up in coordinates whose y runs down.
    private static func draw(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func color(_ value: RGBA) -> CGColor {
        CGColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    private static func gradient(_ stops: [RGBA]) -> CGGradient? {
        guard stops.count > 1 else { return nil }
        let places = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(color) as CFArray,
                          locations: places)
    }
}
