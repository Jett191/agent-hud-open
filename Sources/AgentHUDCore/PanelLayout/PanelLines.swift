import Foundation

/// How the hover panel sets its blocks in lines, in points. A block takes a whole line unless it takes half of one and
/// so does the block next to it in the panel's order: those two share a line, left and right, each half of what the gap
/// between them leaves. A half block with no half block beside it, or where a half would be narrower than
/// `narrowestHalf`, takes the whole line, so a line never has an empty half. The panel's views draw to these numbers,
/// which the Mac's tests measure them against.
public enum PanelLines {
    /// The room the panel's content keeps from its sides beside the notch, the two together. A dock gives its own.
    public static let sideInsets = 36.0
    /// The room a block's cells keep from its sides, each side.
    public static let cellInset = 6.0
    /// Between two cells of a line.
    public static let cellGap = 8.0
    /// The cells a half block sets on a line where the layout gives no columns.
    public static let halfColumns = 2

    /// The width of one cell when `columns` of them share a block `width` wide.
    public static func cellWidth(in width: Double, columns: Int) -> Double {
        let count = Double(max(1, columns))
        return (width - 2 * cellInset - (count - 1) * cellGap) / count
    }

    /// The narrowest content any panel has: an agent's own panel at its narrowest, 440 pt, inside its insets: 404 pt.
    public static let narrowestContent = Double(PanelStyle.narrowestAgentWidth) - sideInsets

    /// The narrowest cell the panel draws: six columns of the narrowest content, 58.7 pt. Every name, caption and figure
    /// gives way there rather than being cut, so a half block sets no more cells on a line than leave each this wide.
    public static let narrowestCell = cellWidth(in: narrowestContent, columns: PanelLayout.Block.columnRange.upperBound)

    /// The room the metric buttons share in a half block's heading. Five measures use narrower buttons to keep the
    /// same space as the original four, without taking room from the agent's name.
    public static let metricPickerWidth = 86.0

    /// The room a block's heading takes in half a line with the longest name the app gives an agent, GitHub Copilot's,
    /// 96 pt in the heading's type: the logo, 20 pt, the name, the least room before the picker, 8 pt, and a picker of
    /// at most `metricPickerWidth` plus 2 pt of trailing room, 6 pt apart, so 230 pt. A longer name the app does not
    /// know wraps rather than being cut.
    public static let widestHeading = 20.0 + 6 + 96 + 6 + 8 + 6 + metricPickerWidth + 2

    /// The narrowest half a block is drawn in, 230 pt: room for the widest heading, and for two cells as wide as the
    /// whole panel's default four at its narrowest, 480 pt, which are 102 pt each, 224 pt with their insets. A half of
    /// the 480 pt panel is 215 to 219 pt and its two cells 97.5 to 99.5 pt, where a ring's caption that panel shows
    /// whole gives way to its figure alone, as the sample's "0.6%/h · Sun 22:02" (102 pt) does. Two halves share a line
    /// beside the notch from a panel 506 pt wide at regular spacing, 502 at compact and 510 at roomy.
    public static let narrowestHalf = max(widestHeading, 2 * cellWidth(in: Double(PanelStyle.widthRange.lowerBound) - sideInsets,
                                                                       columns: PanelLayout.Block.defaultColumns) + 2 * cellInset + cellGap)

    /// Each half of a line `width` wide at `spacing`: half of what the gap between the two leaves.
    public static func halfWidth(in width: Double, spacing: PanelSpacing) -> Double { (width - spacing.blockGap) / 2 }

    /// The most cells, two to six, that stand on a line of a half `width` wide, each at least `narrowestCell` wide.
    public static func columns(fitting width: Double) -> Int {
        let range = PanelLayout.Block.columnRange
        return range.reversed().first { cellWidth(in: width, columns: $0) >= narrowestCell } ?? range.lowerBound
    }
}

public extension PanelSpacing {
    /// The gap between two blocks in points, one above the other or side by side on a line: 6, 10 and 14.
    var blockGap: Double {
        switch self {
        case .compact: 6
        case .regular: 10
        case .roomy: 14
        }
    }
}

extension PanelLayoutPlan {
    /// The blocks with the span each takes in effect: two next to each other that both ask for half a line share one
    /// where `halfWidth` is given, each with the cells it sets on a line there; every other block takes the whole line,
    /// with the columns it has there.
    static func paired(_ blocks: [PanelBlockPlan], changes: [String: PanelLayout.Block], halfWidth: Double?) -> [PanelBlockPlan] {
        lineRanges(blocks).flatMap { line -> [PanelBlockPlan] in
            guard let halfWidth, line.count == 2 else { return blocks[line].map { $0.spanning(.full, columns: $0.columns) } }
            return blocks[line].map { $0.spanning(.half, columns: columns(of: $0, asked: changes[$0.key]?.columns, in: halfWidth)) }
        }
    }

    /// Where each line starts and ends in `blocks`: two next to each other that both take half a line, from the first,
    /// share one; every other block has its own.
    private static func lineRanges(_ blocks: [PanelBlockPlan]) -> [Range<Int>] {
        var lines: [Range<Int>] = [], start = blocks.startIndex
        while start < blocks.endIndex {
            let pairs = start + 1 < blocks.endIndex && blocks[start].span == .half && blocks[start + 1].span == .half
            lines.append(start..<(start + (pairs ? 2 : 1)))
            start = lines[lines.count - 1].upperBound
        }
        return lines
    }

    /// The cells a half block sets on a line: the layout's columns, else two, never more than fit the half. Four for a
    /// block without cells.
    private static func columns(of block: PanelBlockPlan, asked: Int?, in halfWidth: Double) -> Int {
        guard block.kind.takesColumns(under: block.widget) else { return PanelLayout.Block.defaultColumns }
        let asked = asked.flatMap { PanelLayout.Block.columnRange.contains($0) ? $0 : nil } ?? PanelLines.halfColumns
        return min(asked, PanelLines.columns(fitting: halfWidth))
    }

    /// The blocks in lines, in order: two half blocks side by side, every other block alone.
    public var lines: [[PanelBlockPlan]] { Self.lineRanges(blocks).map { Array(blocks[$0]) } }
}

extension PanelBlockPlan {
    /// The block taking `span` of its line with `columns` cells on a line.
    func spanning(_ span: PanelSpan, columns: Int) -> PanelBlockPlan {
        PanelBlockPlan(key: key, kind: kind, widget: widget, measures: measures, hiddenRows: hiddenRows, rowOrder: rowOrder,
                       accounts: accounts, countdown: countdown, columns: columns, ringSize: ringSize, span: span, period: period)
    }
}
