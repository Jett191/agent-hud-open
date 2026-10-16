import SwiftUI
import AgentHUDCore

/// Says that the panel shows a layout an agent proposed and nobody has saved, or that its screen's resting HUD shows a
/// style an agent proposed, and lets a person keep it or drop it. It sits above the footer, outside the scrolling
/// content, for as long as the draft waits. It acts on the document the panel draws (`PanelLayoutStore.draftScope(on:)`),
/// its screen's own draft or the shared draft, which shows its bar on every screen that uses it, and on the screen's
/// style draft, so one Save keeps both as one version.
struct PanelDraftBar: View {
    let layout: PanelLayoutStore
    /// The key of the screen whose panel this is; nil for the shared layout's.
    let screen: String?
    private let theme = Theme.island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What waits: a layout, with or without a style, or a style alone.
    private var title: String {
        layout.draftScope(on: screen) == nil ? L10n.text("HUD 样式未保存", "Unsaved HUD style")
            : L10n.text("布局未保存", "Unsaved layout")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.status(.warning))
            Text(title)
                .font(.ui(12, .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            // An agent's own panel on a separated dock is narrower than the whole panel: where a screen's note does not
            // fit there, it says only that the draft is this display's.
            ViewThatFits(in: .horizontal) {
                noteText(note.full)
                noteText(note.short)
            }
            Spacer(minLength: 8)
            Button { change { layout.discardPanel(on: screen) } } label: {
                Text(L10n.text("放弃", "Discard"))
                    .font(.ui(11, .medium)).lineLimit(1)
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 9).frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.cardBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("island-layout-discard")
            Button { change { layout.savePanel(on: screen) } } label: {
                Text(L10n.text("保存", "Save"))
                    .font(.ui(11, .medium)).lineLimit(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(theme.text, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("island-layout-save")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, IslandRowLayout.inset)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// When the draft goes, and for a screen's own draft or a style alone that it is this display's alone; `short` where
    /// `full` does not fit on one line.
    private var note: (full: String, short: String) {
        switch layout.draftScope(on: screen) {
        case .shared?:
            let restart = L10n.text("重启后丢弃", "Dropped on restart")
            return (restart, restart)
        case .screen?, nil:
            return (L10n.text("仅此显示器，重启后丢弃", "This display only, dropped on restart"),
                    L10n.text("仅此显示器", "This display only"))
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.ui(11))
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
    }

    private func change(_ body: () -> Void) {
        withAnimation(reduceMotion ? nil : IslandAnimation.curve, body)
    }
}
