import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// A grid whose last line is not full centres that line under the ones above, with cells as wide as theirs: three
/// windows two to a line make a triangle. Read off a picture of the grid with each cell drawn as a solid block, at one
/// to seven windows, two to six columns, and the widths of a whole panel and of half of one.
@MainActor
final class QuotaCellTriangleTests: XCTestCase {
    private static var sampleRows: [AgentRow] = []

    /// Seven of the sample's rows; what they read does not matter, only how many stand on a line.
    private func rows(_ count: Int) throws -> [AgentRow] {
        if Self.sampleRows.isEmpty {
            _ = NSApplication.shared
            let suite = "app.agenthud.tests.quota-cell-triangle.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), defaultAgents: DemoData.everyAgent)
            let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
            store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
            Self.sampleRows = Array(store.rows.prefix(7))
        }
        XCTAssertGreaterThanOrEqual(Self.sampleRows.count, count)
        return Array(Self.sampleRows.prefix(count))
    }

    /// Where each cell stands, line by line, in points from the grid's leading edge.
    private func drawn(_ rows: [AgentRow], columns: Int, width: CGFloat) throws -> [[ClosedRange<CGFloat>]] {
        let scale: CGFloat = 2
        let grid = QuotaCellGrid(rows: rows, columns: columns) { _ in Color(red: 1, green: 0, blue: 0).frame(height: 12) }
            .frame(width: width)
            .background(Color.black)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let (pixelsWide, pixelsHigh) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                              bytesPerRow: pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        func runs(_ y: Int) -> [ClosedRange<Int>] {
            var found: [ClosedRange<Int>] = [], start: Int?
            for x in 0...pixelsWide {
                let index = (y * pixelsWide + x) * 4
                let red = x < pixelsWide && pixels[index] > 128 && pixels[index + 1] < 100
                if red, start == nil { start = x }
                if !red, let first = start { found.append(first...(x - 1)); start = nil }
            }
            return found
        }
        // Each line is a band of rows of pixels with blocks in them; its middle row says where the blocks stand.
        var lines: [[ClosedRange<CGFloat>]] = []
        var band: [Int] = []
        for y in 0...pixelsHigh {
            if y < pixelsHigh, !runs(y).isEmpty { band.append(y); continue }
            guard !band.isEmpty else { continue }
            lines.append(runs(band[band.count / 2]).map { CGFloat($0.lowerBound) / scale...CGFloat($0.upperBound + 1) / scale })
            band = []
        }
        // The picture's rows run from the top, as the grid's lines do.
        return lines
    }

    /// The cells as the rule places them: full lines across, a single line sharing the width, and a last line that is
    /// not full centred with the columns' width.
    private func expected(count: Int, columns: Int, width: CGFloat) -> [[ClosedRange<CGFloat>]] {
        let inset = IslandRowLayout.inset, gap = QuotaCellGrid<EmptyView>.cellGap, inner = width - 2 * inset
        let counts = stride(from: 0, to: count, by: columns).map { min(columns, count - $0) }
        return counts.map { onLine in
            let shared = counts.count == 1 ? onLine : columns
            let cell = (inner - CGFloat(shared - 1) * gap) / CGFloat(shared)
            let start = inset + (inner - (CGFloat(onLine) * cell + CGFloat(onLine - 1) * gap)) / 2
            return (0..<onLine).map { start + CGFloat($0) * (cell + gap)...start + CGFloat($0) * (cell + gap) + cell }
        }
    }

    func testALastLineThatIsNotFullStandsCentredUnderTheLinesAbove() throws {
        // Half of the narrowest panel that pairs, half of the default one, an agent's own panel, the default and the widest.
        let widths: [CGFloat] = [230, 257, 404, 444, 644]
        var checked = 0
        for width in widths {
            for columns in PanelLayout.Block.columnRange {
                for count in 1...7 {
                    let lines = try drawn(try rows(count), columns: columns, width: width)
                    let wanted = expected(count: count, columns: columns, width: width)
                    let label = "\(count) cells, \(columns) columns, \(width) pt"
                    XCTAssertEqual(lines.map(\.count), wanted.map(\.count), label)
                    for (line, want) in zip(lines, wanted) {
                        for (cell, place) in zip(line, want) {
                            XCTAssertEqual(cell.lowerBound, place.lowerBound, accuracy: 1, label)
                            XCTAssertEqual(cell.upperBound, place.upperBound, accuracy: 1, label)
                        }
                    }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 5 * 5 * 7)
    }

    /// Three windows two to a line: two on top, one centred below, as wide as each of them.
    func testThreeCellsTwoToALineMakeATriangle() throws {
        let width: CGFloat = 257
        let lines = try drawn(try rows(3), columns: 2, width: width)
        XCTAssertEqual(lines.map(\.count), [2, 1])
        guard lines.count == 2, lines[0].count == 2, let lone = lines[1].first else { return }
        let top = lines[0]
        XCTAssertEqual((lone.lowerBound + lone.upperBound) / 2, width / 2, accuracy: 0.5, "centred in the grid")
        XCTAssertEqual(lone.upperBound - lone.lowerBound, top[0].upperBound - top[0].lowerBound, accuracy: 0.5, "as wide as a column")
        XCTAssertGreaterThan(lone.lowerBound, top[0].lowerBound)
        XCTAssertLessThan(lone.upperBound, top[1].upperBound)
    }

    func testTheLineLayoutCentresItsCells() {
        XCTAssertEqual(CentredGridLine.origins(count: 1, columns: 2, gap: 8, width: 208), [54])
        XCTAssertEqual(CentredGridLine.origins(count: 1, columns: 4, gap: 8, width: 424), [212 - 50] as [CGFloat])
        XCTAssertEqual(CentredGridLine.origins(count: 2, columns: 4, gap: 8, width: 424), [108, 216])
        XCTAssertEqual(CentredGridLine.origins(count: 4, columns: 4, gap: 8, width: 424), [0, 108, 216, 324], "a full line is not moved")
        XCTAssertEqual(CentredGridLine.cellWidth(columns: 4, gap: 8, width: 424), 100)
    }
}
