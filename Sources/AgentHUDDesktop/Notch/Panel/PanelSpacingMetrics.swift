import SwiftUI
import AgentHUDCore

/// The hover panel's gaps in one of a layout's three spacings (`PanelSpacing`): what separates its sections, its
/// blocks, a block's heading from its rows, and its rows and cells from one another. Regular is the panel as the
/// default view draws it; compact is about six tenths of each gap and roomy about one and four tenths, in whole points.
/// The panel's insets, its footer, the draft bar and every font are the same in all three.
struct PanelSpacingMetrics: Equatable, Sendable {
    /// Between the panel's sections, and between them and the lines above them: an error, an alert, an agent's title.
    let sections: CGFloat
    /// Between two blocks, and between two balance cards of one block.
    let blocks: CGFloat
    /// Above the divider of a block, a balance card or a section that has something above it.
    let divided: CGFloat
    /// Between a block's heading and its rows, and between the parts under the heading, in a quota block and in a
    /// balance's card alike.
    let blockParts: CGFloat
    /// Above and below each bar row.
    let rowPadding: CGFloat
    /// Between two lines of ring or number cells.
    let cellLines: CGFloat
    /// Above and below a grid of cells.
    let cellPadding: CGFloat
    /// Above the chart a block draws in place of its windows.
    let chartTop: CGFloat
    /// Between the sessions' heading and its rows, and between two of its rows.
    let sessionRows: CGFloat

    init(_ spacing: PanelSpacing) {
        switch spacing {
        case .compact:
            self.init(sections: 6, blocks: 6, divided: 5, blockParts: 5, rowPadding: 2, cellLines: 6, cellPadding: 1,
                      chartTop: 2, sessionRows: 4)
        case .regular:
            self.init(sections: 10, blocks: 10, divided: 8, blockParts: 8, rowPadding: 4, cellLines: 10, cellPadding: 2,
                      chartTop: 4, sessionRows: 6)
        case .roomy:
            self.init(sections: 14, blocks: 14, divided: 11, blockParts: 11, rowPadding: 6, cellLines: 14, cellPadding: 3,
                      chartTop: 6, sessionRows: 8)
        }
    }

    private init(sections: CGFloat, blocks: CGFloat, divided: CGFloat, blockParts: CGFloat, rowPadding: CGFloat,
                 cellLines: CGFloat, cellPadding: CGFloat, chartTop: CGFloat, sessionRows: CGFloat) {
        self.sections = sections
        self.blocks = blocks
        self.divided = divided
        self.blockParts = blockParts
        self.rowPadding = rowPadding
        self.cellLines = cellLines
        self.cellPadding = cellPadding
        self.chartTop = chartTop
        self.sessionRows = sessionRows
    }
}

extension EnvironmentValues {
    /// The gaps of the hover panel a view is drawn in, which the panel sets from its layout's spacing; regular
    /// anywhere else.
    @Entry var panelSpacing: PanelSpacingMetrics = PanelSpacingMetrics(.regular)
}
