import SwiftUI
import AgentHUDCore

extension EnvironmentValues {
    /// Whether a block is drawn in half a line of the hover panel, beside another half block (`PanelLines`): its heading
    /// keeps the logo, the name and the picker, an account's "Current account" gives way before its label shortens
    /// from the middle, and a row laid out in the whole line's columns sets its parts by their own widths, stacking them
    /// where they do not fit side by side. Off for a block across the whole line, which is drawn as it always was.
    @Entry var panelHalf = false
}

/// Two half blocks on one line of the hover panel, or a balance's two columns in half a line: each as wide as half of
/// what the gap between them leaves, both from the line's top, and the line as tall as the taller of them. Unproposed,
/// it is as wide as two of the wider one, which is what a `ViewThatFits` weighs it by. A view stands in the half its
/// `Side` names, else in its place among the others, so a half fading over to another block, which both are while the
/// change animates, takes the same half.
struct PanelHalves: Layout {
    var gap: CGFloat

    /// The half a view stands in: 0 on the left, 1 on the right; nil for its place among the others.
    struct Side: LayoutValueKey {
        static let defaultValue: Int? = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? 2 * (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) + gap
        let half = halfWidth(width)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: half, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let half = halfWidth(bounds.width)
        for (index, subview) in subviews.enumerated() {
            let side = CGFloat(min(1, max(0, subview[Side.self] ?? index)))
            subview.place(at: CGPoint(x: bounds.minX + side * (half + gap), y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: half, height: nil))
        }
    }

    private func halfWidth(_ width: CGFloat) -> CGFloat { max(0, (width - gap) / 2) }
}

/// The panel's blocks in their lines.
extension HoverPanelView {
    /// One block of the panel with what it draws: a vendor's quota rows, or the API accounts under one key.
    enum Block: Identifiable {
        case quota(PanelBlockPlan, rows: [AgentRow])
        case billing(PanelBlockPlan, accounts: [APIBilling])

        var plan: PanelBlockPlan {
            switch self {
            case .quota(let plan, _), .billing(let plan, _): plan
            }
        }

        /// A block that asks for another widget, or other measures, is another view: its picker starts again.
        var id: String { "\(plan.key)|\(plan.widget.rawValue)|" + plan.measures.map(\.rawValue).joined(separator: ",") }
        var isQuota: Bool { plan.kind == .quota }
    }

    /// One line of the panel's blocks: a block across it, or two half blocks side by side. A line of one block is that
    /// block, as before blocks shared lines; two blocks that come to share a line, or stop sharing one, fade over. A
    /// shared line is the two blocks' keys, so where one of them asks for another widget or other measures only that
    /// one fades over and its picker starts again, and the other keeps its own.
    struct BlockLine: Identifiable {
        let blocks: [Block]
        var id: String { blocks.count == 1 ? blocks[0].id : blocks.map(\.plan.key).joined(separator: "+") }
    }

    /// The plan's lines with what each block draws, where a Settings switch leaves the blocks.
    func blockLines(_ plan: PanelLayoutPlan) -> [BlockLine] {
        guard store.settings.settings.showIslandQuota else { return [] }
        let groups = Dictionary(quotaGroups.map { ($0.vendor, $0.rows) }, uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(grouping: billing, by: \.panelBlockKey)
        return plan.lines.compactMap { line in
            let blocks: [Block] = line.compactMap { block in
                switch block.kind {
                case .quota: groups[block.key].map { .quota(block, rows: $0) }
                case .billing: accounts[block.key].map { .billing(block, accounts: $0) }
                }
            }
            return blocks.isEmpty ? nil : BlockLine(blocks: blocks)
        }
    }

    /// The blocks in the layout's order, in their lines. A quota block comes under a divider unless it is the first,
    /// which has one only below another section. An API account's card is always under its own divider, the first one
    /// too, as it has been since before there were layouts, so a panel of balances alone is the panel it was. Two half
    /// blocks share one divider above their line, as a quota block has it, with a thin one between them. Without
    /// separators each divider's room stays and its line goes.
    func blockList(_ lines: [BlockLine], separated: Bool, spacing: PanelSpacingMetrics, divider: Color) -> some View {
        VStack(alignment: .leading, spacing: spacing.blocks) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                Group {
                    if line.blocks.count > 1 {
                        pair(line.blocks, divided: index > 0 || separated, spacing: spacing, divider: divider)
                    } else if let block = line.blocks.first {
                        whole(block, divided: index > 0 || separated, spacing: spacing, divider: divider)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Where a quota block's logo and name lead: back to the vendor's latest session that names a destination.
    private func openAgent(_ vendor: String) -> (() -> Void)? {
        Self.latestDestination(store, vendor: vendor).map { id in { onOpenListedSession(id) } }
    }

    @ViewBuilder
    private func whole(_ block: Block, divided: Bool, spacing: PanelSpacingMetrics, divider: Color) -> some View {
        switch block {
        case .quota(let plan, let rows):
            ProviderQuotaBlock(store: store, rows: rows, plan: plan, onOpenAgent: openAgent(plan.key))
                .padding(.top, divided ? spacing.divided : 0)
                .topDivider(divided ? divider : .clear)
        case .billing(_, let accounts):
            VStack(alignment: .leading, spacing: spacing.blocks) {
                ForEach(accounts) { account in
                    APIBillingCard(billing: account, store: store, theme: theme, compact: true)
                        .padding(.top, spacing.divided)
                        .topDivider(divider)
                }
            }
        }
    }

    /// Two half blocks, left and right, from the line's top, the gap between them the spacing's gap between blocks,
    /// with a thin divider down the middle of it from the line's divider to the foot of the taller block.
    private func pair(_ blocks: [Block], divided: Bool, spacing: PanelSpacingMetrics, divider: Color) -> some View {
        PanelHalves(gap: spacing.blocks) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { side, block in
                half(block, spacing: spacing, divider: divider)
                    .layoutValue(key: PanelHalves.Side.self, value: side)
                    .transition(.opacity)
            }
        }
        .environment(\.panelHalf, true)
        .padding(.top, divided ? spacing.divided : 0)
        .overlay { Rectangle().fill(divider).frame(width: 1) }
        .topDivider(divided ? divider : .clear)
    }

    /// A block in half a line. A balance's accounts stand one under another in it, each after the first under its own
    /// divider, the first under the line's.
    @ViewBuilder
    private func half(_ block: Block, spacing: PanelSpacingMetrics, divider: Color) -> some View {
        switch block {
        case .quota(let plan, let rows):
            ProviderQuotaBlock(store: store, rows: rows, plan: plan, onOpenAgent: openAgent(plan.key))
        case .billing(_, let accounts):
            VStack(alignment: .leading, spacing: spacing.blocks) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    APIBillingCard(billing: account, store: store, theme: theme, compact: true)
                        .padding(.top, index > 0 ? spacing.divided : 0)
                        .topDivider(index > 0 ? divider : .clear)
                }
            }
        }
    }
}
