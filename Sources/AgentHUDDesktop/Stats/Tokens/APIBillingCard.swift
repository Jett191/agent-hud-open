import SwiftUI
import AgentHUDCore

/// API-funded accounts show money directly; there is no percentage quota or reset period. In the hover panel, compact,
/// the card is a block, and its heading stands as far from its rows as a quota block's does under the panel's spacing.
/// In half a line the second column goes under the first where the two do not fit side by side in equal columns, and
/// the heading is as tall as a quota block's with a picker.
///
/// In the hover panel the card draws what its block's widget and measure ask for. Under `number` each balance is a line
/// of two columns, a caption over a figure in each: `quota`, the balance beside the estimated cost, as the card has
/// always been; `burn`, the burn rate, the estimated cost per day over the period, beside when the balance runs out at
/// it; `cost`, the estimated cost beside that burn rate. The columns are weighed in every measure the block offers, so
/// a flip of its picker never resizes the panel. Under `chart` each balance is its estimated cost over the period, with
/// its bars under it. Every figure comes from the readings the report holds: the balance from its provider, the costs
/// from the requests Agent HUD recorded, priced as the Tokens page prices them.
struct APIBillingCard: View {
    let billing: APIBilling
    let store: UsageStore
    let theme: Theme
    var compact = false
    /// What the estimated cost, the burn rate and the chart cover in the hover panel: its block's period
    /// (`PanelBlockPlan.period`), over the span the panel's token chart draws for it, which the statistics window's range
    /// never changes. Nil on the statistics window, where it covers that window's range.
    var period: PanelTokenPeriod? = nil
    /// What draws the card in the hover panel: `number`, its figures, or `chart`, each balance's estimated cost over the
    /// period in bars. Its figures elsewhere.
    var widget = PanelWidget.number
    /// The measures its block's picker offers, each of which the card is weighed in; `quota` alone off the panel.
    var measures: [PanelMeasure] = [.quota]
    /// The measure the card shows, the picker's selection, among `measures`.
    var measure = PanelMeasure.quota
    /// The picker its heading carries, over `measures`: the first card's of a block that offers more than one; nil for
    /// none.
    var picker: Binding<PanelMeasure>? = nil
    @Environment(\.panelSpacing) private var panelSpacing
    @Environment(\.panelHalf) private var half

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? panelSpacing.blockParts : 12) {
            HStack(spacing: compact ? 6 : 7) {
                AgentLogo(vendor: billing.vendor, size: 14)
                    .frame(width: compact ? IslandRowLayout.inset * 2 + IslandRowLayout.markerWidth : 14)
                Text(billing.displayName)
                    .font(compact ? IslandRowLayout.headingFont : .ui(12, .semibold))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: half, vertical: false)
                    .layoutPriority(1)
                Spacer()
                if let picker {
                    // The picker stands over the heading's padding rather than making its line taller, so the card is as
                    // tall with it as the card was before it had measures, and the default view is the panel as it was.
                    IslandQuotaMetricPicker(selection: picker, measures: measures, kind: .billing, theme: theme)
                        .frame(height: 0)
                        .padding(.trailing, 2)
                }
            }
            // As tall as a quota block's heading with a picker, so a balance beside one starts its rows level with it.
            .frame(minHeight: compact && half ? IslandRowLayout.headingHeight : nil)
            .padding(.vertical, compact ? IslandRowLayout.headingVerticalPadding : 0)
            // A balance whose read failed keeps its last amount without a colour, and says why; the panel's picture for
            // an agent draws the reason, which its provider wrote, as placeholder bars.
            if let reason = store.view.assessment(of: billing).status.reason {
                Text(reason)
                    .font(.ui(11))
                    .foregroundStyle(theme.statusText(.warning))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .redactedOnPicture()
                    .padding(.leading, compact ? IslandRowLayout.textInset : 0)
            }
            ForEach(lines) { line in
                if compact && widget == .chart {
                    chartLine(currency: line.currency, balance: line.balance)
                } else {
                    balanceLine(currency: line.currency, balance: line.balance)
                    if !compact, let balance = line.balance {
                        Text(L10n.text("充值余额 ", "Topped up ") + MoneyFormat.amount(balance.toppedUp, currency: balance.currency)
                             + L10n.text(" · 赠送余额 ", " · Granted ") + MoneyFormat.amount(balance.granted, currency: balance.currency))
                            .font(.ui(11)).foregroundStyle(theme.secondary)
                    }
                }
            }
            if !compact {
                HStack(alignment: .top) {
                    Text(L10n.text("费用仅估算本机 Harness 已记录的请求，包含缓存和峰谷价格。", "Costs estimate requests recorded by local Harness, including cache and peak pricing."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Link(L10n.text("计价说明", "Pricing"), destination: DeepSeekPricing.sourceURL)
                }
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .help(L10n.text("官方价格核对日期：", "Official prices checked: ") + DeepSeekPricing.checkedOn)
            }
        }
    }

    /// One balance, by its currency; the account's currency without a balance before its first reading.
    private struct Line: Identifiable {
        let currency: String
        let balance: AccountBalance?
        var id: String { currency }
    }

    /// Each balance by its currency, or the account's currency without a balance before its first reading.
    private var lines: [Line] {
        billing.balances.isEmpty ? [Line(currency: billing.currency, balance: nil)]
            : billing.balances.map { Line(currency: $0.currency, balance: $0) }
    }

    @ViewBuilder
    private func balanceLine(currency: String, balance: AccountBalance?) -> some View {
        if compact && half {
            ViewThatFits(in: .horizontal) {
                // Two equal columns, as across the whole line, weighed as such: each as wide as the wider of the two in
                // every measure, so neither label wraps in its column and a flip keeps the arrangement.
                PanelHalves(gap: 24) {
                    column(.first, currency: currency, balance: balance)
                    column(.second, currency: currency, balance: balance)
                }
                .padding(.leading, IslandRowLayout.textInset)
                .padding(.trailing, IslandRowLayout.inset)
                VStack(alignment: .leading, spacing: panelSpacing.blockParts) {
                    column(.first, currency: currency, balance: balance)
                    column(.second, currency: currency, balance: balance)
                }
                .padding(.leading, IslandRowLayout.textInset)
                .padding(.trailing, IslandRowLayout.inset)
            }
        } else {
            sideBySide(currency: currency, balance: balance)
        }
    }

    private func sideBySide(currency: String, balance: AccountBalance?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 24 : nil) {
            column(.first, currency: currency, balance: balance)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            if !compact { Spacer() }
            column(.second, currency: currency, balance: balance)
                .frame(maxWidth: compact ? .infinity : nil, alignment: compact ? .leading : .trailing)
        }
        .padding(.leading, compact ? IslandRowLayout.textInset : 0)
        .padding(.trailing, compact ? IslandRowLayout.inset : 0)
    }

    // MARK: Figures

    /// A column as the selected measure draws it, over the same column in every other measure the block offers, which
    /// are drawn clear: it is as wide and as tall as the widest of them, so a flip of the picker never resizes the card
    /// or moves its second column under its first, and the figures fade from one measure to the next.
    private func column(_ side: BalanceMetrics.Side, currency: String, balance: AccountBalance?) -> some View {
        let metrics = metrics(currency: currency, balance: balance)
        return ZStack(alignment: compact ? .topLeading : side == .first ? .topLeading : .topTrailing) {
            ForEach(measures.contains(measure) ? measures : [measure]) { shown in
                let drawn = metrics.figure(side, of: shown)
                VStack(alignment: compact || side == .first ? .leading : .trailing, spacing: 3) {
                    Text(drawn.caption).font(.ui(11)).foregroundStyle(theme.secondary)
                    Text(drawn.value)
                        .font(.tabular(compact ? 15 : side == .first ? 22 : 20, .semibold))
                        .foregroundStyle(color(drawn.ink, level: metrics.level))
                        .help(shown == .quota && side == .first ? availability : "")
                }
                .opacity(shown == measure ? 1 : 0)
                .allowsHitTesting(shown == measure)
                .accessibilityHidden(shown != measure)
            }
        }
    }

    /// What the balance's figure says on hover: whether the API is available, else where the balance comes from.
    private var availability: String {
        billing.isAvailable == false ? L10n.text("余额不足，API 暂不可用", "Insufficient balance; API unavailable")
            : L10n.text("来自 DeepSeek 官方余额接口", "From the official DeepSeek balance API")
    }

    /// A figure's ink: the balance's level, the text's without one, or the secondary text's.
    private func color(_ ink: BalanceMetrics.Ink, level: StatusLevel?) -> Color {
        switch ink {
        case .level: level.map { theme.statusText($0) } ?? theme.text
        case .text: theme.text
        case .secondary: theme.secondary
        }
    }

    private func metrics(currency: String, balance: AccountBalance?) -> BalanceMetrics {
        BalanceMetrics(billing: billing, balance: balance, currency: currency, store: store, period: period)
    }

    // MARK: Chart

    /// A balance drawn as a chart: its estimated cost over the period, in the cost's caption and figure, over its bars in
    /// the period's columns, the token chart's, coloured by the balance's level.
    private func chartLine(currency: String, balance: AccountBalance?) -> some View {
        let charted = self.period ?? .day
        let metrics = metrics(currency: currency, balance: balance)
        let total = metrics.figure(.first, of: .cost)
        return VStack(alignment: .leading, spacing: panelSpacing.chartTop) {
            VStack(alignment: .leading, spacing: 3) {
                Text(total.caption).font(.ui(11)).foregroundStyle(theme.secondary)
                Text(total.value).font(.tabular(15, .semibold)).foregroundStyle(color(total.ink, level: metrics.level))
            }
            .padding(.leading, IslandRowLayout.textInset)
            .padding(.trailing, IslandRowLayout.inset)
            CostBarsChart(columns: store.balanceCostColumns(billing, currency: currency, period: charted),
                          interval: store.hudTokenInterval(charted), currency: currency,
                          color: metrics.level.map { theme.status($0) } ?? theme.secondary, theme: theme,
                          isLoading: store.report == nil)
                // Another period is other columns: the bars fade over, as a quota block's chart's do.
                .id(charted)
                .frame(height: 40)
                .padding(.horizontal, IslandRowLayout.inset)
        }
    }
}

/// What one API balance's measures read on its card: under `quota` the balance, then the estimated cost; under `burn`
/// the burn rate, then when the balance runs out at it; under `cost` the estimated cost, then the burn rate. The
/// estimated cost is that of the requests recorded over the period, as `UsageStore.balanceSpend(_:currency:period:)`
/// adds it, and the burn rate that cost per day over the period so far; the balance and the burn rate are drawn in the
/// balance's level, the others in the text's ink. A reading that shows no level has no level and no run-out time, as a
/// quota window's has none.
struct BalanceMetrics {
    /// One of a balance line's two columns.
    enum Side { case first, second }
    /// The ink a figure is drawn in: the balance's level, the text's, or the secondary text's for what is not known.
    enum Ink: Equatable { case level, text, secondary }

    /// A column's caption over its figure.
    struct Figure: Equatable {
        let caption: String
        let value: String
        let ink: Ink
    }

    let balance: AccountBalance?
    /// The balance's level, nil where its reading shows none.
    let level: StatusLevel?
    /// What the account spent in the balance's currency over the period; nil where a request had no price in it.
    let spend: BalanceSpend?
    /// The output tokens per second the balance's models reply at, from the ledger's call gaps; nil where none
    /// answered recently.
    let replyRate: QuotaReplyRate?
    /// The tokens the balance's consumers recorded over the period; nil where none are recorded.
    let tokens: Int?
    /// The tokens per hour the balance's consumers recorded over the period's elapsed part.
    let tokensPerHour: Double?
    /// When the balance runs out at the burn rate, where its reading shows a level and the pace gives a time.
    let runsOut: Date?
    let currency: String
    let now: Date
    /// The period, as a caption names it: `Last 7 days`.
    let periodLabel: String

    /// - period: the block's in the hover panel; nil on the statistics window, whose range the cost then covers.
    @MainActor
    init(billing: APIBilling, balance: AccountBalance?, currency: String, store: UsageStore, period: PanelTokenPeriod?) {
        self.balance = balance
        self.currency = currency
        level = balance.flatMap { store.balanceLevel($0, billing: billing) }
        let interval = period.map { store.hudTokenInterval($0) } ?? store.statsInterval
        let spent = billing.spend(currency: currency, during: interval, now: store.dataDate)
        spend = spent
        replyRate = store.view.billingReplyRate(billing)
        tokens = store.view.billingTokens(billing, during: interval)
        tokensPerHour = store.view.billingTokensPerHour(billing, during: interval)
        runsOut = balance.flatMap { balance in spent.flatMap { store.balanceRunsOut(balance, billing: billing, at: $0) } }
        now = store.dataDate
        periodLabel = (period?.range ?? store.statsRange).recentLabel
    }

    func figure(_ side: Side, of measure: PanelMeasure) -> Figure {
        switch (measure, side) {
        case (.burnRate, .first): burnRate(caption: L10n.text("消耗速率 · ", "Burn rate · ") + periodLabel)
        case (.burnRate, .second): runOut
        case (.tokens, .first):
            Figure(caption: L10n.text("回复速率 · ", "Reply rate · ") + periodLabel,
                   value: replyRate.map { $0.tokensPerSecond < 10 ? String(format: "%.1f/s", $0.tokensPerSecond)
                                                                    : "\(Int($0.tokensPerSecond))/s" } ?? "—",
                   ink: .text)
        case (.tokens, .second):
            Figure(caption: L10n.text("回复次数", "Replies"),
                   value: replyRate.map { "\($0.calls)" } ?? "—", ink: .text)
        case (.consumed, .first):
            Figure(caption: L10n.text("Token 消耗 · ", "Tokens · ") + periodLabel,
                   value: tokens.map { TokenFormat.short($0) } ?? "—", ink: .text)
        case (.consumed, .second):
            Figure(caption: L10n.text("平均速率", "Pace"),
                   value: tokensPerHour.map { TokenFormat.short(Int($0.rounded())) + "/h" } ?? "—", ink: .text)
        case (.cost, .first): cost
        case (.cost, .second): burnRate(caption: L10n.text("消耗速率", "Burn rate"))
        case (_, .first):
            Figure(caption: L10n.text("账户余额", "Account balance"),
                   value: balance.map { MoneyFormat.amount($0.total, currency: currency) } ?? "—", ink: .level)
        case (_, .second): cost
        }
    }

    /// The estimated cost over the period, unpriced where one of its requests had no price in the currency.
    private var cost: Figure {
        Figure(caption: L10n.text("费用估算 · ", "Est. cost · ") + periodLabel,
               value: spend.map { MoneyFormat.amount($0.cost, currency: currency, estimated: true) } ?? Self.unpriced, ink: .text)
    }

    /// The estimated cost per day over the period, the days without a recorded request included.
    private func burnRate(caption: String) -> Figure {
        guard let spend else { return Figure(caption: caption, value: Self.unpriced, ink: .secondary) }
        return Figure(caption: caption, value: MoneyFormat.short(spend.perDay, currency: currency) + L10n.text("/天", "/day"),
                      ink: .level)
    }

    /// When the balance runs out at the burn rate: a time where it gives one; Exhausted for a balance at or below zero;
    /// No usage where nothing was spent over the period; and a dash where the balance or the burn rate is not known or
    /// the reading shows no level.
    private var runOut: Figure {
        let caption = L10n.text("预计耗尽", "Runs out")
        guard let balance, spend != nil, level != nil else { return Figure(caption: caption, value: "—", ink: .secondary) }
        if balance.total <= 0 { return Figure(caption: caption, value: L10n.text("已耗尽", "Exhausted"), ink: .level) }
        guard let runsOut else { return Figure(caption: caption, value: L10n.text("暂无消耗", "No usage"), ink: .secondary) }
        return Figure(caption: caption, value: Self.runOutLabel(runsOut, now: now), ink: .text)
    }

    private static var unpriced: String { L10n.text("暂无价格", "Unpriced") }

    /// When a balance runs out, as a window's run-out is written within a week, a weekday and a time, then a date and a
    /// time, and from a year on, which a slow pace can reach, the month and the year.
    static func runOutLabel(_ date: Date, now: Date) -> String {
        let ahead = date.timeIntervalSince(now)
        if ahead < 7 * 86400 { return ChartData.relativeWeekdayTime(date, now: now) }
        let style = Date.FormatStyle().locale(L10n.dateLocale)
        if ahead < 365 * 86400 {
            return date.formatted(style.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return date.formatted(style.month(.abbreviated).year())
    }
}
