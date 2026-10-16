import SwiftUI
import AgentHUDCore

extension PanelTokenPeriod {
    /// What the picker says a period is, for VoiceOver and its help.
    var spokenLabel: String {
        switch self {
        case .day: L10n.text("最近 24 小时", "Last 24 hours")
        case .week: L10n.text("最近 7 天", "Last 7 days")
        case .month: L10n.text("最近 30 天", "Last 30 days")
        }
    }
}

/// Compact, direct period selection for the panel's token chart, drawn as a block's measure picker is: three small
/// buttons, `24h`, `7d` and `30d`. It takes no more height than the header's text, and every period is as tall, so the
/// picker neither grows the panel nor resizes it with a flip.
struct TokenPeriodPicker: View {
    @Binding var selection: PanelTokenPeriod
    var theme: Theme = .island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far a chip reaches above and below its label.
    private static let overhang: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTokenPeriod.allCases) { period in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { selection = period }
                } label: {
                    // The chip reaches past the line it stands on, so the header keeps the height of its text.
                    Text(period.label)
                        .font(.tabular(9, .semibold))
                        .frame(minWidth: 24)
                        .padding(.horizontal, 2)
                        .padding(.vertical, Self.overhang)
                        .foregroundStyle(selection == period ? theme.text : theme.tertiary)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == period ? theme.text.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                        .padding(.vertical, -Self.overhang)
                }
                .buttonStyle(.plain)
                .help(period.spokenLabel)
                .accessibilityLabel(period.spokenLabel)
                .accessibilityAddTraits(selection == period ? .isSelected : [])
                .accessibilityIdentifier("island-token-period-\(period.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Token 时段", "Token period"))
    }
}
