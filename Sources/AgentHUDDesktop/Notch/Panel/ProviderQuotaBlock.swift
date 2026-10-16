import SwiftUI
import AgentHUDCore

/// Shared columns for quota rows, account resets and API balances in the island.
enum IslandRowLayout {
    static let inset: CGFloat = 6
    static let markerWidth: CGFloat = 8
    static let spacing: CGFloat = 12
    /// Between the parts of a row in half a line, whose name is as wide as it is.
    static let halfSpacing: CGFloat = 8
    static let nameWidth: CGFloat = 152
    static let textInset = inset + markerWidth + spacing
    static let headingFont = Font.ui(13, .bold)
    static let headingVerticalPadding: CGFloat = 1
    /// A block's heading with a picker, as tall as the picker's buttons; in half a line every heading is this tall.
    static let headingHeight: CGFloat = 18
}

/// How a block's picker names and draws the measures it flips between. The Mac uses direct buttons where the phone
/// uses a horizontal swipe.
extension PanelMeasure {
    var label: String {
        switch self {
        case .quota: L10n.text("额度", "Quota")
        case .burnRate: L10n.text("消耗速率", "Burn rate")
        case .tokens: L10n.text("Token 速率", "Tokens / h")
        case .cost: L10n.text("费用估算", "Est. cost")
        }
    }

    var symbol: String {
        switch self {
        case .quota: "percent"
        case .burnRate: "flame.fill"
        case .tokens: "number"
        case .cost: "dollarsign"
        }
    }
}

/// Compact, direct measure selection for a provider block, over the measures its widget offers.
struct IslandQuotaMetricPicker: View {
    @Binding var selection: PanelMeasure
    var measures = PanelBlockKind.quota.measures(under: .bar)
    var theme: Theme = .island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(measures) { metric in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { selection = metric }
                } label: {
                    Image(systemName: metric.symbol)
                        .font(.ui(9, .semibold))
                        .frame(width: 20, height: IslandRowLayout.headingHeight)
                        .foregroundStyle(selection == metric ? theme.text : theme.tertiary)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == metric ? theme.text.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(metric.label)
                .accessibilityLabel(metric.label)
                .accessibilityAddTraits(selection == metric ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("额度指标", "Quota metric"))
    }
}

/// One independently switchable provider block, drawn by the widget its plan names, with a picker over the measures
/// the plan offers where there is more than one. Refreshes keep its selected measure because the vendor is its
/// identity; the panel gives it a new identity when its plan asks for another widget or other measures, and the picker
/// starts from the first of them again. In half a line the agent's name keeps one line and is given its room before
/// anything else on it, the loading spinner and a chart's period giving way first, and the heading is as tall as one
/// with a picker whatever it holds.
struct ProviderQuotaBlock: View {
    let store: UsageStore
    let rows: [AgentRow]
    let plan: PanelBlockPlan
    /// Back to the vendor's latest session; nil when no session of it names a destination.
    var onOpenAgent: (() -> Void)? = nil
    @State private var metric: PanelMeasure
    @Environment(\.panelSpacing) private var spacing
    @Environment(\.panelHalf) private var half
    private let theme = Theme.island

    init(store: UsageStore, rows: [AgentRow], plan: PanelBlockPlan, onOpenAgent: (() -> Void)? = nil) {
        self.store = store
        self.rows = rows
        self.plan = plan
        self.onOpenAgent = onOpenAgent
        _metric = State(initialValue: plan.measure)
    }

    /// A quota block's key is its vendor's id.
    private var vendor: String { plan.key }

    private var logo: some View {
        AgentLogo(vendor: vendor, size: 14)
            .frame(width: IslandRowLayout.inset * 2 + IslandRowLayout.markerWidth)
    }

    private static var openAgentHelp: String { L10n.text("回到最近的会话", "Back to the latest session") }

    /// Whether the block shows reset times: where Settings shows them and the layout does not hide them here.
    private var showsCountdown: Bool { store.settings.settings.showResetCountdown && plan.countdown }

    var body: some View {
        // A chart draws the models this vendor's windows count in place of the windows: their tokens over the panel's
        // last day, in the quarter hours and the colours of the panel's own token chart.
        let charted = plan.widget == .chart
        let chartConsumers: [AgentDescriptor] = charted ? store.consumers.filter { $0.displayVendor == vendor } : []
        let chartColumns: [TokenColumn] = charted ? store.hudTokenColumns(consumerIDs: Set(chartConsumers.map(\.id))) : []
        VStack(alignment: .leading, spacing: spacing.blockParts) {
            HStack(spacing: 6) {
                if half {
                    // The name is given its room first and keeps one line: the spinner gives way where both have no
                    // room, and a name longer than any the app gives an agent (`PanelLines.widestHeading`) wraps.
                    HStack(spacing: 6) {
                        logo
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { name.lineLimit(1); spinner }
                            name.lineLimit(1)
                            name
                        }
                    }
                    .clickTarget(onOpenAgent, help: Self.openAgentHelp)
                    .layoutPriority(1)
                } else {
                    // The logo and the name lead back to the agent's latest session, looking as they always do.
                    HStack(spacing: 6) { logo; name }
                        .clickTarget(onOpenAgent, help: Self.openAgentHelp)
                    spinner
                }
                Spacer()
                if plan.measures.count > 1 {
                    IslandQuotaMetricPicker(selection: $metric, measures: plan.measures, theme: theme)
                        .padding(.trailing, 2)
                } else if plan.widget == .chart {
                    let total = TokenConsumptionChart.total(store.report == nil ? nil : chartColumns)
                    Group {
                        if half {
                            // The figure stays where the period has no room beside the name.
                            ViewThatFits(in: .horizontal) {
                                Text(total)
                                Text(total.components(separatedBy: " · ").last ?? total).fixedSize()
                            }
                        } else {
                            Text(total)
                        }
                    }
                    .font(.tabular(12))
                    .padding(.trailing, IslandRowLayout.inset)
                }
            }
            // In half a line every heading is as tall as one with a picker, so two halves' rows start level.
            .frame(minHeight: half ? IslandRowLayout.headingHeight : nil)
            .font(.ui(11))
            .foregroundStyle(theme.secondary)
            .padding(.vertical, IslandRowLayout.headingVerticalPadding)

            let sections = store.accountSections(rows)
            ForEach(sections) { section in
                let shown = section.rows.filter { !plan.hiddenRows.contains($0.agent.windowKey) }
                let wallets = section.account?.wallets ?? []
                // Earned resets belong to the signed-in Codex account.
                let resets = section.isCurrent && section.rows.contains(where: { $0.agent.vendor == "Codex" })
                    ? store.report?.resetCredits(for: section.id) : nil
                if !shown.isEmpty || !wallets.isEmpty || resets != nil {
                    if let account = section.account {
                        let warning = store.view.assessment(of: account).status.reason
                        let details = store.view.accountSourceNotice(for: section)
                        AccountSectionHeader(account: account, label: store.accountLabel(for: account),
                                             notice: details, warning: warning)
                    }
                    windows(shown)
                        .opacity(section.isCurrent ? 1 : 0.55)
                    ForEach(wallets) { wallet in
                        AccountWalletRow(wallet: wallet)
                            .opacity(section.isCurrent ? 1 : 0.55)
                    }
                    if let resets {
                        CodexResetCreditsView(resets: resets, showExpiry: showsCountdown)
                    }
                }
            }
            if plan.widget == .chart {
                TokenBarsChart(columns: chartColumns, interval: store.hudTokenInterval,
                               colors: chartConsumers.map { AgentPalette.swiftUIColor(index: store.consumerPaletteIndex($0.id)) },
                               consumers: chartConsumers, theme: theme, isLoading: store.report == nil, compact: true)
                    .frame(height: 40)
                    .padding(.horizontal, IslandRowLayout.inset)
                    .padding(.top, spacing.chartTop)
            }
        }
    }

    private var name: Text {
        Text(VendorCatalog.name(vendor)).font(IslandRowLayout.headingFont).foregroundStyle(theme.text)
    }

    @ViewBuilder
    private var spinner: some View {
        if store.isLoading {
            LoadingSpinner(color: theme.secondary)
                .accessibilityLabel(L10n.text("正在读取额度", "Loading quota"))
        }
    }

    /// An account's quota windows as the block's widget draws them.
    @ViewBuilder
    private func windows(_ rows: [AgentRow]) -> some View {
        let showReset = showsCountdown
        switch plan.widget {
        case .ring, .number:
            QuotaCellGrid(rows: rows, columns: plan.columns) { row in
                QuotaCell(row: row, metrics: metrics(row), metric: metric, style: plan.widget == .ring ? .ring : .number,
                          showReset: showReset, forecastHint: store.quotaForecastHint(for: row.id), isLoading: store.isLoading,
                          ringSize: plan.ringSize)
            }
        case .chart:
            // The chart under the accounts stands for the windows.
            EmptyView()
        case .bar:
            ForEach(rows) { row in
                ModelUsageRow(row: row, now: store.now, metric: metric, showReset: showReset, showVendor: false,
                              insights: store.report?.insightsByAgent[row.id],
                              outlook: store.view.outlook(for: row.id),
                              tokensPerHour: store.quotaTokensPerHour(for: row.id),
                              forecastHint: store.quotaForecastHint(for: row.id),
                              cost: cost(row), isLoading: store.isLoading)
            }
        }
    }

    private func metrics(_ row: AgentRow) -> QuotaRowMetrics {
        QuotaRowMetrics(row: row, insights: store.report?.insightsByAgent[row.id], outlook: store.view.outlook(for: row.id),
                        now: store.now, tokensPerHour: store.quotaTokensPerHour(for: row.id), cost: cost(row))
    }

    /// The cycle's list cost is priced from every bucket of the window, so only the measure that shows it asks for it.
    private func cost(_ row: AgentRow) -> QuotaListCost? {
        metric == .cost ? store.view.listCost(for: row.id) : nil
    }
}

/// Names the account above its windows once a client has more than one, or when it is no longer signed in. A client
/// that said why it has no current reading says it here, where the stale rows are. On the panel's picture for an agent
/// the name is masked, where the reading came from is not said, and the warning and the notice, which their provider
/// or client wrote, are placeholder bars. In half a line, where the line is short, whether the account is current
/// gives way first, and then the name shortens from the middle.
struct AccountSectionHeader: View {
    let account: AccountObservation
    /// Whether the account is current or when it was last read.
    let label: String
    var notice: String?
    var warning: String?
    private let theme = Theme.island
    @Environment(\.masksIdentity) private var masksIdentity
    @Environment(\.panelHalf) private var half

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if half {
                ViewThatFits(in: .horizontal) {
                    line(label: label)
                    line(label: nil)
                }
            } else {
                line(label: label)
            }
            if let warning {
                Text(warning)
                    .foregroundStyle(theme.statusText(.warning))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .redactedOnPicture()
            }
            if let notice, notice != warning {
                Text(notice)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .redactedOnPicture()
            }
        }
        .font(.ui(11))
        .padding(.horizontal, IslandRowLayout.inset)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    /// The account's name, its plan and where its reading came from, with `label` at the end of the line.
    private func line(label: String?) -> some View {
        HStack(spacing: 6) {
            Text(masksIdentity ? IdentityMask.account(account.displayName) : account.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.text.opacity(account.isCurrent ? 0.85 : 0.6))
            if let plan = account.planLabel {
                Text(plan).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: half, vertical: false)
            }
            if let sourceDetails {
                let said = masksIdentity ? "" : sourceDetails
                Image(systemName: "info.circle")
                    .foregroundStyle(theme.tertiary)
                    .help(said)
                    .accessibilityLabel(L10n.text("读数来源", "Reading source"))
                    .accessibilityHint(said)
            }
            Spacer(minLength: 8)
            if let label {
                Text(label)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var sourceDetails: String? {
        guard let info = account.sourceInfo else { return nil }
        let date = account.observedAt.formatted(Date.FormatStyle().month(.abbreviated).day()
            .hour().minute().second().locale(L10n.dateLocale))
        return info + "\n" + L10n.text("读取时间：\(date)", "Read at: \(date)")
    }
}

/// Earned resets belong to the account, so they appear once beneath its quota windows. In half a line, which has no bar
/// rows to line up with, the name is as wide as it is and the parts stand closer.
struct CodexResetCreditsView: View {
    let resets: CodexResetCredits
    let showExpiry: Bool
    private let theme = Theme.island
    @State private var isHovered = false
    @Environment(\.panelHalf) private var half

    var body: some View {
        HStack(spacing: half ? IslandRowLayout.halfSpacing : IslandRowLayout.spacing) {
            Image(systemName: "arrow.counterclockwise")
                .font(.ui(12, .medium))
                .frame(width: IslandRowLayout.markerWidth)
            Text(L10n.text("额度重置", "Usage resets"))
                .font(.ui(12, .medium))
                .frame(width: half ? nil : IslandRowLayout.nameWidth, alignment: .leading)
                .layoutPriority(half ? 1 : 0)
            Text(availabilityLabel)
                .font(.tabular(12, .semibold))
                .foregroundStyle(resets.availableCount > 0 ? theme.status(.ok) : theme.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            if resets.availableCount > 0 {
                if showExpiry {
                    // Never cut: where the whole label has no room beside the count, as in a narrow panel, the date
                    // alone stands in for it, and where that has none either the icon, whose card tells every expiry.
                    let label = nextExpiryLabel
                    ViewThatFits(in: .horizontal) {
                        Text(label.full)
                        Text(label.short)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.tabular(11))
                }
                Image(systemName: "info.circle")
                    .font(.ui(11))
                    .foregroundStyle(isHovered ? theme.secondary : theme.tertiary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, IslandRowLayout.inset)
        .padding(.bottom, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.text.opacity(isHovered ? 0.06 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .background(IslandHoverPopover(content: ResetCreditsDetails(resets: resets),
                                       enabled: resets.availableCount > 0, isHovered: $isHovered))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("额度重置", "Usage resets"))
        .accessibilityValue(ResetCreditsDetails.accessibilityText(resets))
    }

    private var availabilityLabel: String {
        L10n.text("\(resets.availableCount) 次可用", "\(resets.availableCount) available")
    }

    /// The earliest expiry, whole and short: the short form of a date is the date alone; a label without one has none
    /// shorter than itself.
    var nextExpiryLabel: (full: String, short: String) {
        let dates = resets.creditsByExpiry.compactMap(\.expirationDate)
        guard let date = dates.first else {
            let label = L10n.text("有效期未提供", "Expiry unavailable")
            return (label, label)
        }
        guard dates.count == resets.availableCount else {
            let label = L10n.text("部分有效期可查看", "Partial expiry details")
            return (label, label)
        }
        let label = date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(L10n.dateLocale))
        return (L10n.text("最早 \(label) 到期", "First expires \(label)"), label)
    }
}
