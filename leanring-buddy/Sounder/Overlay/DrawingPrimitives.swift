//
//  DrawingPrimitives.swift
//  leanring-buddy
//
//  The drawing vocabulary. Analysis results are turned into primitives here,
//  deterministically, from element IDs and row/column indices — never from
//  model prose. All geometry is in capture pixels; DrawingLayerView converts.
//

import CoreGraphics
import Foundation

nonisolated enum DrawingColor: Sendable {
    case red
    case blue
    case yellow
    case orange
}

nonisolated enum DrawingPrimitive: Identifiable, Sendable {
    /// Rounded-rect stroke around a row (or any box), optionally with a numbered tag.
    case circle(id: String, rectInCapturePixels: CGRect, tagNumber: Int?, color: DrawingColor)
    /// Horizontal importance bar docked under a header cell. Top weight glows.
    case bar(id: String, rectInCapturePixels: CGRect, isTopWeight: Bool)
    /// Fitted curve polyline, clipped to the chart plot area.
    case polyline(id: String, pointsInCapturePixels: [CGPoint], clipRectInCapturePixels: CGRect?)
    /// Translucent confidence band between two polylines.
    case band(id: String, upperPointsInCapturePixels: [CGPoint], lowerPointsInCapturePixels: [CGPoint], clipRectInCapturePixels: CGRect?)
    /// Filled translucent rectangle (cell highlight / element highlight).
    case highlight(id: String, rectInCapturePixels: CGRect, color: DrawingColor)
    /// Small text label anchored at a point.
    case badge(id: String, anchorInCapturePixels: CGPoint, text: String)
    /// Curved connector between two text boxes (drug–drug interaction) with a chip at the apex.
    case link(id: String, fromRectInCapturePixels: CGRect, toRectInCapturePixels: CGRect, color: DrawingColor, label: String?)
    /// Coloured underline beneath a text box (dose out of range, condition with evidence).
    case underline(id: String, rectInCapturePixels: CGRect, color: DrawingColor)
    /// Citation drawer pinned to the bottom-right of the screen.
    case footnoteDrawer(id: String, lines: [String])

    var id: String {
        switch self {
        case .circle(let id, _, _, _), .bar(let id, _, _), .polyline(let id, _, _),
             .band(let id, _, _, _), .highlight(let id, _, _), .badge(let id, _, _),
             .link(let id, _, _, _, _), .underline(let id, _, _), .footnoteDrawer(let id, _):
            return id
        }
    }
}

/// Builders for the PRD's four ops (circle_rows, bars_under_headers, curve,
/// highlight_cells) plus General-mode highlight.
@MainActor
enum DrawingOpsBuilder {

    static func circleRows(table: ExtractedTable, rowIndices: [Int]) -> [DrawingPrimitive] {
        var primitives: [DrawingPrimitive] = []
        for (position, rowIndex) in rowIndices.enumerated() {
            guard let rowBox = table.boundingBox(forRow: rowIndex) else { continue }
            let padding = max(3, rowBox.height * 0.18)
            let paddedBox = rowBox.insetBy(dx: -padding * 1.6, dy: -padding)
            primitives.append(.circle(id: "row-\(rowIndex)", rectInCapturePixels: paddedBox, tagNumber: position + 1, color: .red))
        }
        return primitives
    }

    static func barsUnderHeaders(table: ExtractedTable, importancesByColumnName: [String: Double]) -> [DrawingPrimitive] {
        let maximumImportance = importancesByColumnName.values.max() ?? 0
        guard maximumImportance > 0 else { return [] }

        var primitives: [DrawingPrimitive] = []
        for (columnName, importance) in importancesByColumnName {
            guard let columnIndex = table.columnIndex(named: columnName),
                  let headerBox = table.headerBox(forColumn: columnIndex) else { continue }
            // Column extent: widen the header box to the neighbouring cells so the
            // bar spans the column, not just the header text.
            let columnBoxes = table.rowCellBoxes.compactMap { $0[safe: columnIndex] ?? nil }
            let columnMinX = ([headerBox] + columnBoxes).map(\.minX).min() ?? headerBox.minX
            let columnMaxX = ([headerBox] + columnBoxes).map(\.maxX).max() ?? headerBox.maxX
            let fullWidth = max(columnMaxX - columnMinX, headerBox.width)
            let barHeight = max(4, headerBox.height * 0.32)
            let barWidth = max(3, fullWidth * CGFloat(importance / maximumImportance))
            let barRect = CGRect(x: columnMinX, y: headerBox.maxY + barHeight * 0.5, width: barWidth, height: barHeight)
            let isTopWeight = importance >= maximumImportance * 0.999
            primitives.append(.bar(id: "bar-\(columnIndex)", rectInCapturePixels: barRect, isTopWeight: isTopWeight))
            let percentText = "\(Int((importance * 100).rounded()))%"
            primitives.append(.badge(id: "bar-label-\(columnIndex)", anchorInCapturePixels: CGPoint(x: barRect.minX + barWidth + barHeight, y: barRect.midY), text: percentText))
        }
        return primitives
    }

    static func curve(fit: FitResult, chart: ChartRegion) -> [DrawingPrimitive] {
        let curvePoints = fit.points.compactMap { pair -> CGPoint? in
            guard pair.count == 2 else { return nil }
            return chart.capturePixel(forDataX: pair[0], dataY: pair[1])
        }
        let upperPoints = fit.band.compactMap { triple -> CGPoint? in
            guard triple.count == 3 else { return nil }
            return chart.capturePixel(forDataX: triple[0], dataY: triple[2])
        }
        let lowerPoints = fit.band.compactMap { triple -> CGPoint? in
            guard triple.count == 3 else { return nil }
            return chart.capturePixel(forDataX: triple[0], dataY: triple[1])
        }
        var primitives: [DrawingPrimitive] = []
        if upperPoints.count >= 2, lowerPoints.count >= 2 {
            primitives.append(.band(id: "fit-band", upperPointsInCapturePixels: upperPoints, lowerPointsInCapturePixels: lowerPoints, clipRectInCapturePixels: chart.boundingBoxInCapturePixels))
        }
        if curvePoints.count >= 2 {
            primitives.append(.polyline(id: "fit-curve", pointsInCapturePixels: curvePoints, clipRectInCapturePixels: chart.boundingBoxInCapturePixels))
            let labelAnchor = CGPoint(x: chart.boundingBoxInCapturePixels.minX + 8, y: chart.boundingBoxInCapturePixels.minY + 8)
            primitives.append(.badge(id: "fit-label", anchorInCapturePixels: labelAnchor, text: "\(fit.modelName) fit · R² \(String(format: "%.2f", fit.rSquared))"))
        }
        return primitives
    }

    static func highlightCells(rects: [CGRect]) -> [DrawingPrimitive] {
        rects.enumerated().map { index, rect in
            .highlight(id: "cell-\(index)", rectInCapturePixels: rect.insetBy(dx: -2, dy: -1), color: .yellow)
        }
    }

    static func highlightElements(_ elements: [ScreenElement]) -> [DrawingPrimitive] {
        elements.map { element in
            .highlight(id: "element-\(element.id)", rectInCapturePixels: element.boundingBoxInCapturePixels.insetBy(dx: -4, dy: -3), color: .blue)
        }
    }

    /// Thin outlines around every OCR line — the coordinate self-test.
    static func calibrationOutlines(_ elements: [ScreenElement]) -> [DrawingPrimitive] {
        elements.map { element in
            .circle(id: "calibration-\(element.id)", rectInCapturePixels: element.boundingBoxInCapturePixels, tagNumber: nil, color: .blue)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
