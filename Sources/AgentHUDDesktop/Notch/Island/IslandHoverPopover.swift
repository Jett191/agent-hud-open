import AppKit
import SwiftUI

/// Island details must track the mouse even while another app has keyboard focus.
///
/// The details are a window of their own, which the HUD's environment does not reach: they are drawn with the look of
/// the HUD the row is in, which the popover reads where it is placed and hands on. They stand on a surface of that look
/// (`HUDSurface`), whose glass shows what is behind their window, the panel under them included.
struct IslandHoverPopover<Content: View>: NSViewRepresentable {
    let content: Content
    var enabled = true
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> IslandHoverAnchorView<Content> {
        IslandHoverAnchorView(content: content, look: context.environment.hudLook)
    }

    func updateNSView(_ view: IslandHoverAnchorView<Content>, context: Context) {
        view.onHover = { isHovered = $0 }
        view.update(content: content, look: context.environment.hudLook, enabled: enabled, isHovered: isHovered)
    }

    static func dismantleNSView(_ view: IslandHoverAnchorView<Content>, coordinator: ()) {
        view.dismiss()
    }
}

final class IslandHoverAnchorView<Content: View>: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var mouseLocation: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    private var hoverArea: NSTrackingArea?
    private var pointerLocation: CGPoint?
    private var content: Content
    private var look: HUDLook
    /// The details as the popup hosts them: drawn with the look.
    private typealias Details = NSHostingView<ModifiedContent<Content, HUDLookEnvironment>>
    /// Most rows are never hovered, so the panel and its hosting view wait for the first show.
    private var popup: (panel: OverlayPanel, details: Details)?

    init(content: Content, look: HUDLook) {
        self.content = content
        self.look = look
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        trackPointer(event)
        onHover(true)
    }

    override func mouseMoved(with event: NSEvent) { trackPointer(event) }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        onHover(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            pointerLocation = nil
            dismiss()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func update(content: Content, look: HUDLook, enabled: Bool, isHovered: Bool) {
        self.content = content
        self.look = look
        if let popup {
            popup.details.rootView = content.hudLook(look)
            if popup.panel.appearance?.name != look.appearanceName {
                popup.panel.appearance = NSAppearance(named: look.appearanceName)
            }
            // A shadow under details the desktop shows through would darken them, as the HUD keeps shadows from under
            // its own see-through shells.
            if popup.panel.hasShadow == look.seeThrough {
                popup.panel.hasShadow = !look.seeThrough
                popup.panel.invalidateShadow()
            }
        }
        // A tracking area fires only when the pointer crosses the rect in the window's coordinates: when the panel's
        // window moves or the row shifts under a still pointer the exit never comes and the popup would stay pinned.
        // Reconcile with where the cursor actually is so a missed exit clears on this pass instead.
        var isHovered = isHovered
        if isHovered, let window {
            let point = convert(window.convertPoint(fromScreen: mouseLocation()), from: nil)
            if !bounds.insetBy(dx: -1, dy: -1).contains(point) {
                pointerLocation = nil
                // Updating an NSViewRepresentable must not synchronously change its SwiftUI binding. A new enter
                // before this task runs has a pointer location again and owns the newer hover state.
                Task { @MainActor [weak self] in
                    guard let self, self.pointerLocation == nil else { return }
                    self.onHover(false)
                }
                isHovered = false
            }
        }
        guard isHovered, enabled, let window, let pointerLocation else {
            dismiss()
            return
        }
        let popup = self.popup ?? makePopup()
        popup.panel.collectionBehavior = window.collectionBehavior
        position(popup.panel, in: window, at: pointerLocation, size: popup.details.fittingSize)
        if popup.panel.parent !== window { window.addChildWindow(popup.panel, ordered: .above) }
        popup.panel.orderFrontRegardless()
    }

    private func makePopup() -> (panel: OverlayPanel, details: Details) {
        let details = Details(rootView: content.hudLook(look))
        let panel = OverlayPanel(frame: .zero, level: .popUpMenu, acceptsMouse: false)
        panel.title = "Island hover details"
        panel.hasShadow = !look.seeThrough
        panel.appearance = NSAppearance(named: look.appearanceName)
        panel.contentView = details
        popup = (panel, details)
        return (panel, details)
    }

    private func trackPointer(_ event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        pointerLocation = point
        if let panel = popup?.panel, panel.isVisible { position(panel, in: window, at: point, size: panel.frame.size) }
    }

    private func position(_ panel: NSPanel, in window: NSWindow, at point: CGPoint, size: CGSize) {
        var origin = CGPoint(x: point.x + 10, y: point.y - size.height - 12)
        if let screen = window.screen {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            if origin.y < visible.minY { origin.y = point.y + 12 }
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func dismiss() {
        guard let panel = popup?.panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
