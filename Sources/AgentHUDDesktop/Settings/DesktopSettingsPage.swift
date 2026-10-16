import SwiftUI

/// A host-provided page presented alongside the built-in desktop settings, after General, Agents and Display and before
/// Experimental. A page with a built-in page's id gets no page of its own; one with the id `experimental` is drawn on
/// that page instead, below its rows, as a `DesktopSettingsSection` would be.
@MainActor
public struct DesktopSettingsPage: Identifiable {
    public let id: String
    public var title: () -> String
    public var subtitle: () -> String
    public var symbol: String
    public var color: Color
    public var preferredContentWidth: CGFloat?
    let content: () -> AnyView

    public init<Content: View>(id: String, title: @escaping () -> String,
                               subtitle: @escaping () -> String, symbol: String, color: Color,
                               preferredContentWidth: CGFloat? = nil,
                               @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.preferredContentWidth = preferredContentWidth
        self.content = { AnyView(content()) }
    }
}

/// Rows a host adds to a built-in settings page, drawn below the page's own: `DesktopApplication`'s
/// `experimentalSettings` go on the Experimental page. The content draws its own sections, as a page's does.
@MainActor
public struct DesktopSettingsSection: Identifiable {
    /// Tells the host's sections apart; any string unique among them.
    public let id: String
    let content: () -> AnyView

    /// `content` is drawn as given, typically one or more `SettingsSection`-like groups of rows.
    public init<Content: View>(id: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.content = { AnyView(content()) }
    }
}
