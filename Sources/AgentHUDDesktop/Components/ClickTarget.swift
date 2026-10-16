import AppKit
import SwiftUI

extension View {
    /// Makes a part open something when clicked, with nothing about its look changed: the pointing hand while the
    /// pointer is over it, and the click. Without an action the part is left as it is, and the pointer with it.
    func clickTarget(_ action: (() -> Void)?, help: String) -> some View {
        modifier(ClickTarget(action: action, help: help))
    }
}

private struct ClickTarget: ViewModifier {
    let action: (() -> Void)?
    let help: String
    @State private var pointing = false

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .onHover { point($0) }
                // A click that collapses the HUD takes the part away under the pointer, which then never leaves it.
                .onDisappear { point(false) }
                .help(help)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(help)
                .accessibilityAction(.default, action)
        } else {
            content
        }
    }

    private func point(_ inside: Bool) {
        guard inside != pointing else { return }
        pointing = inside
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}
