import Foundation

/// How tall the hover panel is at the width a display's island gives it, and the tallest it opens there: the screen's
/// height less 80 points. A panel taller than that scrolls. The shared layout is measured on the main display.
public struct PanelFit: Equatable, Sendable {
    /// The panel's natural height in whole points, never below the 80 the island opens to at least.
    public let height: Double
    /// The tallest the panel opens on its display, in points.
    public let maximumHeight: Double
    /// The width the panel lays its blocks out in there, inside the display's insets, which decides whether two half
    /// blocks share a line (`PanelLayoutPlan`); nil where the measure does not say, which counts as beside the notch.
    public let contentWidth: Double?

    public init(height: Double, maximumHeight: Double, contentWidth: Double? = nil) {
        self.height = height
        self.maximumHeight = maximumHeight
        self.contentWidth = contentWidth
    }

    /// Whether the panel is taller than its display lets it open, so a person scrolls to see the rest.
    public var scrolls: Bool { height > maximumHeight }
}

/// The hover panel drawn for an agent that checks how a layout looks: a screen's whole panel as the layout in effect
/// there draws it, on the island's black card, as PNG data. It shows no account name and no session title
/// (`IdentityMask`).
public struct PanelPicture: Equatable, Sendable {
    /// The pixels a point the picture is drawn at, unless that would make it taller than `pixelLimit`.
    public static let pointScale: Double = 2
    /// The tallest picture drawn, in pixels. A taller panel is drawn at the scale that keeps it at this.
    public static let pixelLimit = 2400

    /// The picture as PNG data.
    public let png: Data
    /// The panel's width in points.
    public let width: Double
    /// The panel's height, which the picture shows whole, and whether it scrolls on the main display.
    public let fit: PanelFit
    /// The pixels a point the picture was drawn at.
    public let scale: Double

    public init(png: Data, width: Double, fit: PanelFit, scale: Double) {
        self.png = png
        self.width = width
        self.fit = fit
        self.scale = scale
    }

    /// The pixels a point a panel `height` points tall is drawn at: `pointScale`, or what keeps it at `limit` pixels.
    public static func scale(forHeight height: Double, limit: Int = pixelLimit) -> Double {
        guard height > 0 else { return pointScale }
        return min(pointScale, Double(limit) / height)
    }

    /// Whether the picture is drawn smaller than `pointScale` to stay within the pixel limit.
    public var isScaledDown: Bool { scale < Self.pointScale }
}

/// A screen's resting HUD drawn for an agent that checks how a style looks: the island at the notch, a Dynamic dock's
/// marks or a Simple panel, as that screen draws it now with any style draft, on a dark backdrop, as PNG data. A dock is
/// laid along a top edge, as Settings previews it. It shows marks and figures, and no account or session.
public struct HUDPicture: Equatable, Sendable {
    /// The picture as PNG data, at `PanelPicture.pointScale` pixels a point.
    public let png: Data
    /// The picture's size in points.
    public let width: Double
    public let height: Double
    /// The pixels a point the picture was drawn at.
    public let scale: Double
    /// Whether the HUD's glow is in the picture. A Simple panel draws none.
    public let drawsGlow: Bool

    public init(png: Data, width: Double, height: Double, scale: Double, drawsGlow: Bool) {
        self.png = png
        self.width = width
        self.height = height
        self.scale = scale
        self.drawsGlow = drawsGlow
    }
}

/// How the panel's picture hides whose it is. A picture goes to an agent's model like any tool result, so it shows
/// how the panel is drawn and never whose accounts or work it shows. Off the picture nothing is masked.
public enum IdentityMask {
    /// An account's label as the picture writes it: the first and the last character of the part before any "@", with
    /// three asterisks between them, and the domain after it kept. "jazzenus@gmail.com" is "j***s@gmail.com" and
    /// "Personal" is "P***l"; a part of one or two characters is "***", and an empty one stays empty.
    public static func account(_ label: String) -> String {
        guard let at = label.firstIndex(of: "@") else { return masked(label[...]) }
        return masked(label[..<at]) + label[at...]
    }

    private static func masked(_ name: Substring) -> String {
        guard !name.isEmpty else { return "" }
        guard name.count > 2, let first = name.first, let last = name.last else { return "***" }
        return "\(first)***\(last)"
    }

    /// A session row's name in the picture, in place of its title and its project: the row's place in the list,
    /// counted from 1.
    public static func session(at position: Int) -> String {
        L10n.text("会话 \(position)", "Session \(position)")
    }
}
