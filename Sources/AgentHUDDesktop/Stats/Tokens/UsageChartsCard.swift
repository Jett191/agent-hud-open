import SwiftUI
import AgentHUDCore

struct UsageChartsCard: View {
    let store: UsageStore
    let theme: Theme

    var body: some View {
        TokenConsumptionChart(store: store, theme: theme, context: .stats)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/// Dashboard controls belong to its chart. The HUD's history shows the latest day in quarter-hour bars, or the last 7 or
/// 30 days in day bars, as its picker flips them: it starts from the period it is handed, its layout's, each time the
/// panel opens, and a flip lasts until the panel closes. The bars keep one height in every period.
struct TokenConsumptionChart: View {
    enum Context { case stats, island }

    struct ModelTokens: Identifiable {
        let consumer: AgentDescriptor
        let tokens: Int
        let paletteIndex: Int
        var id: String { consumer.id }
    }

    let store: UsageStore
    let theme: Theme
    let context: Context
    let compact: Bool
    var onOpenStats: () -> Void
    private let inspectedColumnID: Date?
    /// The island's models, as it is handed them on every pass: a model of an agent its layout or its panel names that
    /// starts spending tokens while the panel is open joins the chart with the next report. Nil on the statistics
    /// window, whose picker keeps its own (`modelFilter`).
    private let handedModels: TokenModelFilter?
    @State private var modelFilter: TokenModelFilter
    @State private var modelsExpanded: Bool
    /// The island's period, which its picker flips.
    @State private var period: PanelTokenPeriod

    init(store: UsageStore, theme: Theme, context: Context, modelsExpanded: Bool = false,
         modelFilter: TokenModelFilter = TokenModelFilter(), period: PanelTokenPeriod = .day, inspectedColumnID: Date? = nil,
         compact: Bool = false, onOpenStats: @escaping () -> Void = {}) {
        self.store = store
        self.theme = theme
        self.context = context
        self.compact = compact
        self.onOpenStats = onOpenStats
        self.inspectedColumnID = inspectedColumnID
        handedModels = context == .island ? modelFilter : nil
        _modelsExpanded = State(initialValue: modelsExpanded)
        _modelFilter = State(initialValue: modelFilter)
        _period = State(initialValue: period)
    }

    var body: some View {
        // The island has no model control of its own; it is handed the models its layout and its panel's agent chart.
        let filter = handedModels ?? modelFilter
        let consumers = store.consumers.filter { filter.includes($0.id) }
        let ids = filter.consumerIDs
        let period = period
        let allColumns = context == .stats ? store.tokenColumns : store.hudTokenColumns(consumerIDs: nil, period: period)
        let columns = ids == nil ? allColumns
            : context == .stats ? store.tokenColumns(consumerIDs: ids) : store.hudTokenColumns(consumerIDs: ids, period: period)
        let interval = context == .stats ? store.statsInterval : store.hudTokenInterval(period)
        let models = context == .stats ? Self.modelTotals(consumers: store.consumers, columns: allColumns) : []
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Token 消耗", "Tokens"))
                    .font(.ui(13, .semibold))
                Spacer()
                if context == .island {
                    TokenPeriodPicker(selection: $period, theme: theme)
                    Text(Self.total(store.report == nil ? nil : columns, period: period))
                        .font(.tabular(12))
                        .foregroundStyle(theme.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TokenFormat.short(columns.reduce(0) { $0 + $1.total }))
                            .font(.tabular(20, .semibold))
                            .help(L10n.text("所选模型、时间与种类的 Token 总量", "Total tokens for the selected models, range and kinds"))
                        if let cost = store.statsListCost(consumerIDs: ids) {
                            Text(L10n.text("按 API 价 ", "At API prices ") + cost.text)
                                .font(.tabular(11))
                                .foregroundStyle(theme.secondary)
                                .help(costHelp(unpriced: cost.unpriced))
                        }
                    }
                }
            }
            if !compact, context == .stats, !models.isEmpty || !modelFilter.isAll {
                modelPicker(models)
            } else if !compact, context == .island {
                let legend = Self.islandLegend(consumers: store.consumers, columns: allColumns, filter: filter)
                if !legend.shown.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(legend.shown) { model in
                            legendLabel(model.consumer, tokens: model.tokens)
                        }
                    }
                    .font(.ui(11))
                    .foregroundStyle(theme.secondary)
                }
                if legend.more > 0 {
                    Button {
                        store.statsTab = .tokens
                        onOpenStats()
                    } label: {
                        Text(L10n.text("另 \(legend.more) 个 · 查看统计", "+\(legend.more) more · View stats"))
                    }
                    .buttonStyle(.plain).font(.ui(10)).foregroundStyle(theme.secondary)
                    .accessibilityIdentifier("island-more-token-models")
                }
            }
            TokenBarsChart(columns: columns, interval: interval,
                           colors: consumers.map { AgentPalette.swiftUIColor(index: store.consumerPaletteIndex($0.id)) },
                           consumers: consumers, theme: theme, isLoading: store.report == nil,
                           noModelsSelected: context == .stats && modelFilter.consumerIDs?.isEmpty == true,
                           inspectedColumnID: inspectedColumnID, compact: compact)
                .id(context == .stats ? [store.statsRange.hours, store.tokenBucketSize.rawValue, store.tokenDimensions.rawValue]
                                     : [Int(period.duration / 3600), period.bucketSize.rawValue, TokenDimensions.all.rawValue])
                .frame(height: compact ? 40 : (context == .island ? 72 : 100))
                .padding(.horizontal, context == .stats ? 12 : 6)
                .padding(.top, compact ? 8 : 12)
                .zIndex(1)

            if !compact {
                HStack {
                    let labels = ChartData.axisLabels(range: context == .stats ? store.statsRange : period.range, now: store.dataDate)
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer() }
                        Text(label)
                            .lineLimit(2)
                            .multilineTextAlignment(index == 0 ? .leading : index == labels.count - 1 ? .trailing : .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.ui(10))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, context == .stats ? 12 : 6)
            }
        }
    }

    /// What stands beside the name of an island chart: its period and the tokens its columns hold, or a dash for `nil`,
    /// while there is no report to count from.
    nonisolated static func total(_ columns: [TokenColumn]?, period: PanelTokenPeriod = .day) -> String {
        guard let columns else { return "\(period.label) · —" }
        return "\(period.label) · \(TokenFormat.short(columns.reduce(0) { $0 + $1.total })) tok"
    }

    nonisolated static func modelTotals(consumers: [AgentDescriptor], columns: [TokenColumn]) -> [ModelTokens] {
        consumers.enumerated().map { index, consumer in
            ModelTokens(consumer: consumer, tokens: columns.reduce(0) { $0 + $1.tokens[index] }, paletteIndex: index)
        }
    }

    /// The HUD limits labels, never the columns or totals. Ties retain the report's model order and palette identity.
    nonisolated static func islandLegend(consumers: [AgentDescriptor], columns: [TokenColumn],
                                         filter: TokenModelFilter = TokenModelFilter()) -> (shown: [ModelTokens], more: Int) {
        let models = modelTotals(consumers: consumers, columns: columns)
            .filter { $0.tokens > 0 && filter.includes($0.consumer.id) }.sorted {
            $0.tokens == $1.tokens ? $0.paletteIndex < $1.paletteIndex : $0.tokens > $1.tokens
        }
        return (Array(models.prefix(10)), max(0, models.count - 10))
    }

    private func modelPicker(_ models: [ModelTokens]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { modelsExpanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: modelsExpanded ? "chevron.down" : "chevron.right").font(.ui(9, .semibold))
                        Text(modelFilter.isAll ? L10n.text("模型 · 全部", "Models · All")
                             : L10n.text("模型 · 已选 \(modelFilter.consumerIDs?.count ?? 0) 个", "Models · \(modelFilter.consumerIDs?.count ?? 0) selected"))
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("token-model-filter")
                .accessibilityValue(modelsExpanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                Spacer()
                if !modelFilter.isAll {
                    Button(L10n.text("清除筛选", "Clear filter")) { modelFilter.selectAll() }
                        .accessibilityIdentifier("token-model-filter-clear")
                }
            }
            if modelsExpanded {
                Button { modelFilter.selectAll() } label: {
                    Label(L10n.text("全部模型", "All models"), systemImage: modelFilter.isAll ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("token-model-filter-all")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(models) { model in
                        Button { modelFilter.toggle(model.id) } label: {
                            HStack(spacing: 5) {
                                legendLabel(model.consumer, tokens: model.tokens)
                                Image(systemName: modelFilter.isPicked(model.id) ? "checkmark.circle.fill"
                                      : modelFilter.isAll ? "plus.circle" : "circle")
                                    .font(.ui(11))
                            }
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .background(modelFilter.isPicked(model.id) ? theme.text.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("token-model-\(model.id)")
                        .accessibilityValue(modelFilter.isPicked(model.id) ? L10n.text("已选", "Selected")
                                            : modelFilter.isAll ? L10n.text("包含在全部模型中", "Included in all models") : L10n.text("未选", "Not selected"))
                        .help(L10n.text("筛选此模型；点选其他模型可多选", "Filter to this model; click other models to add them"))
                    }
                }
            }
        }
        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(theme.secondary)
    }

    private func costHelp(unpriced: [String]) -> String {
        let note = L10n.text("所选模型与种类按厂商 API 公开价折合；选「全部 Token」即这些调用的总价",
                             "The selected models and kinds at the vendors' API list prices; with all tokens selected, what the calls would cost")
        guard !unpriced.isEmpty else { return note }
        return note + "\n" + L10n.text("没有公开价、未计入：", "Not counted, no list price: ")
            + unpriced.map(store.consumerName).joined(separator: L10n.text("、", ", "))
    }

    private func legendLabel(_ consumer: AgentDescriptor, tokens: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(consumer.id))).frame(width: 7, height: 7)
            AgentLogo(vendor: consumer.vendor, size: 12)
            Text(consumer.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(TokenFormat.short(tokens)).font(.tabular(11)).fixedSize()
        }
        .accessibilityLabel("\(consumer.displayName): \(tokens.formatted()) tokens")
        .help("\(consumer.displayName): \(tokens.formatted()) tokens")
    }

}
