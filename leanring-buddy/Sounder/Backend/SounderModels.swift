//
//  SounderModels.swift
//  leanring-buddy
//
//  Value types shared across capture, extraction, analysis and drawing.
//  Every box is expressed in *capture pixels* (top-left origin of the captured
//  display image) until the drawing layer converts it to overlay points, so the
//  same coordinate contract holds from OCR through to the pixels on screen.
//

import CoreGraphics
import Foundation

// MARK: - Capture geometry

/// Geometry of one display capture, needed to map capture pixels back onto the overlay.
nonisolated struct CaptureGeometry: Sendable, Equatable {
    let captureWidthInPixels: Int
    let captureHeightInPixels: Int
    /// AppKit frame (bottom-left origin, points) of the display that was captured.
    /// The overlay window for that display has exactly this frame.
    let displayFrame: CGRect

    var pointsPerCapturePixelHorizontally: CGFloat {
        displayFrame.width / CGFloat(max(captureWidthInPixels, 1))
    }

    var pointsPerCapturePixelVertically: CGFloat {
        displayFrame.height / CGFloat(max(captureHeightInPixels, 1))
    }

    /// Capture pixel (top-left origin) → overlay-local point (top-left origin).
    /// The overlay covers the whole display, so this is a pure scale.
    func overlayPoint(fromCapturePixel capturePixel: CGPoint) -> CGPoint {
        CGPoint(
            x: capturePixel.x * pointsPerCapturePixelHorizontally,
            y: capturePixel.y * pointsPerCapturePixelVertically
        )
    }

    func overlayRect(fromCapturePixelRect capturePixelRect: CGRect) -> CGRect {
        CGRect(
            x: capturePixelRect.minX * pointsPerCapturePixelHorizontally,
            y: capturePixelRect.minY * pointsPerCapturePixelVertically,
            width: capturePixelRect.width * pointsPerCapturePixelHorizontally,
            height: capturePixelRect.height * pointsPerCapturePixelVertically
        )
    }

    /// Capture pixel → global AppKit screen coordinate (bottom-left origin), the
    /// coordinate space BlueCursorView uses to fly the cursor to a target.
    func globalAppKitPoint(fromCapturePixel capturePixel: CGPoint) -> CGPoint {
        let overlayPoint = overlayPoint(fromCapturePixel: capturePixel)
        return CGPoint(
            x: displayFrame.origin.x + overlayPoint.x,
            y: displayFrame.origin.y + displayFrame.height - overlayPoint.y
        )
    }

    /// Overlay-local point → capture pixel. Used by the change watcher to crop regions.
    func capturePixelRect(fromDisplayPointRect displayPointRect: CGRect) -> CGRect {
        CGRect(
            x: displayPointRect.minX / pointsPerCapturePixelHorizontally,
            y: displayPointRect.minY / pointsPerCapturePixelVertically,
            width: displayPointRect.width / pointsPerCapturePixelHorizontally,
            height: displayPointRect.height / pointsPerCapturePixelVertically
        )
    }
}

// MARK: - Grounding elements (Set-of-Mark)

/// One thing on screen the language model may refer to by ID. The model never
/// sees pixel coordinates; it picks an ID and the renderer resolves the box.
nonisolated struct ScreenElement: Identifiable, Sendable, Codable {
    let id: Int
    /// "text" for OCR lines. Kept as a string so a UI-element detector can add
    /// "button", "icon", "input"... later without changing the contract.
    let kind: String
    let text: String
    let boundingBoxInCapturePixels: CGRect
    let confidence: Float

    var centerInCapturePixels: CGPoint {
        CGPoint(x: boundingBoxInCapturePixels.midX, y: boundingBoxInCapturePixels.midY)
    }
}

// MARK: - Extracted table

nonisolated enum TableColumnType: String, Codable, Sendable {
    case numeric
    case categorical
    case date
    case text
}

/// A table read off the screen (or copied from the clipboard and aligned with the
/// screen). Cell boxes are optional because clipboard rows may be scrolled out of view.
nonisolated struct ExtractedTable: Sendable {
    var headers: [String]
    var rows: [[String]]
    var columnTypes: [TableColumnType]
    var headerCellBoxes: [CGRect?]
    /// One entry per row, one per column. Nil when that cell is not visible on screen.
    var rowCellBoxes: [[CGRect?]]
    /// Spreadsheet row numbers from the row-number gutter when detected (e.g. "412").
    /// Parallel to `rows`; used so the buddy can say "row 412" like the user would.
    var rowLabels: [String?]
    var extractionConfidence: Double
    /// "ondevice-ocr", "clipboard+ocr" or "remote".
    var source: String
    var tableBoundingBoxInCapturePixels: CGRect?

    var rowCount: Int { rows.count }
    var columnCount: Int { headers.count }

    /// Union of the visible cell boxes in a row, or nil if no cell of that row is visible.
    func boundingBox(forRow rowIndex: Int) -> CGRect? {
        guard rowIndex >= 0, rowIndex < rowCellBoxes.count else { return nil }
        let visibleBoxes = rowCellBoxes[rowIndex].compactMap { $0 }
        guard let firstBox = visibleBoxes.first else { return nil }
        return visibleBoxes.dropFirst().reduce(firstBox) { $0.union($1) }
    }

    func headerBox(forColumn columnIndex: Int) -> CGRect? {
        guard columnIndex >= 0, columnIndex < headerCellBoxes.count else { return nil }
        return headerCellBoxes[columnIndex]
    }

    /// "row 412" when the spreadsheet gutter was read, otherwise "row 7" counting data rows from one.
    func spokenRowLabel(forRow rowIndex: Int) -> String {
        if rowIndex < rowLabels.count, let gutterLabel = rowLabels[rowIndex] {
            return "row \(gutterLabel)"
        }
        return "row \(rowIndex + 1)"
    }

    func columnIndex(named requestedName: String) -> Int? {
        let wanted = TableTextNormalizer.normalizeIdentifier(requestedName)
        guard !wanted.isEmpty else { return nil }
        if let exactIndex = headers.firstIndex(where: { TableTextNormalizer.normalizeIdentifier($0) == wanted }) {
            return exactIndex
        }
        return headers.firstIndex { header in
            let normalizedHeader = TableTextNormalizer.normalizeIdentifier(header)
            return normalizedHeader.contains(wanted) || wanted.contains(normalizedHeader) && !normalizedHeader.isEmpty
        }
    }

    /// JSON body fragment for the analysis service (`TablePayload` in schemas.py).
    func analysisPayload() -> [String: Any] {
        [
            "headers": headers,
            "rows": rows,
            "column_types": columnTypes.map(\.rawValue)
        ]
    }
}

nonisolated enum TableTextNormalizer {
    /// Lowercase alphanumerics only, so "Monthly Charges", "monthlycharges" and
    /// "MonthlyCharges" all compare equal.
    static func normalizeIdentifier(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

// MARK: - Chart calibration

/// Linear map between axis values and capture pixels: pixel = intercept + slope × value.
nonisolated struct AxisCalibration: Sendable {
    let slope: CGFloat
    let intercept: CGFloat

    func pixel(forValue value: Double) -> CGFloat {
        intercept + slope * CGFloat(value)
    }

    /// Ordinary least squares over tick (value, pixel) pairs. Nil when degenerate.
    static func fit(values: [Double], pixels: [CGFloat]) -> AxisCalibration? {
        guard values.count >= 2, values.count == pixels.count else { return nil }
        let count = CGFloat(values.count)
        let meanValue = values.reduce(0, +) / Double(values.count)
        let meanPixel = pixels.reduce(0, +) / count
        var covariance: CGFloat = 0
        var variance: CGFloat = 0
        for (value, pixel) in zip(values, pixels) {
            let valueDelta = CGFloat(value - meanValue)
            covariance += valueDelta * (pixel - meanPixel)
            variance += valueDelta * valueDelta
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        guard slope.isFinite, slope != 0 else { return nil }
        return AxisCalibration(slope: slope, intercept: meanPixel - slope * CGFloat(meanValue))
    }
}

/// A chart found on screen, with both axes calibrated from their tick labels.
nonisolated struct ChartRegion: Sendable {
    let boundingBoxInCapturePixels: CGRect
    let xAxisCalibration: AxisCalibration
    let yAxisCalibration: AxisCalibration
    let xTickValues: [Double]
    let yTickValues: [Double]

    func capturePixel(forDataX dataX: Double, dataY: Double) -> CGPoint {
        CGPoint(x: xAxisCalibration.pixel(forValue: dataX), y: yAxisCalibration.pixel(forValue: dataY))
    }
}

// MARK: - Analysis service contract (mirrors services/analysis/schemas.py)

nonisolated enum AnalysisTask: String, Codable, Sendable {
    case anomaly
    case drivers
    case fit
}

nonisolated struct AnomalyReason: Codable, Sendable {
    let column: String
    let value: String
    let comparisonText: String
    let zScore: Double
}

nonisolated struct AnomalyRow: Codable, Sendable {
    let rowIndex: Int
    let score: Double
    let reasons: [AnomalyReason]
    let spokenReason: String
}

nonisolated struct AnomalyResult: Codable, Sendable {
    let rows: [AnomalyRow]
    let method: String
    let nRowsScored: Int
}

nonisolated struct DriverImportance: Codable, Sendable {
    let column: String
    let importance: Double
}

nonisolated struct DriversResult: Codable, Sendable {
    let targetCol: String
    let problemType: String
    let importances: [DriverImportance]
    let metricName: String
    let metricValue: Double
    let trainSeconds: Double
    let nRowsTrain: Int
    let nRowsHoldout: Int
    let modelName: String
    let droppedColumns: [String]
}

nonisolated struct FitResult: Codable, Sendable {
    let xCol: String
    let yCol: String
    let modelName: String
    let equationText: String
    let rSquared: Double
    /// [[x, y], ...] in data space.
    let points: [[Double]]
    /// [[x, lower, upper], ...] in data space.
    let band: [[Double]]
    let xRange: [Double]
    let yRange: [Double]
    let nPoints: Int
}

nonisolated struct AnalysisResponse: Codable, Sendable {
    let task: AnalysisTask
    let summaryText: String
    let elapsedSeconds: Double
    let warnings: [String]
    let anomaly: AnomalyResult?
    let drivers: DriversResult?
    let fit: FitResult?
}

// MARK: - Interaction report (shown in the panel)

/// What happened during the last push-to-talk interaction. Surfaced in the menu
/// bar panel so latency and confidence can be read off during the demo.
struct SounderInteractionReport {
    var transcript: String
    var modeUsed: String
    var completedAt: Date = Date()
    var extractionSource: String?
    var extractionConfidence: Double?
    var tableRowCount: Int?
    var tableColumnCount: Int?
    var analysisTask: String?
    var metricText: String?
    var captureSeconds: Double = 0
    var ocrSeconds: Double = 0
    var planSeconds: Double = 0
    var analysisSeconds: Double = 0
    var totalSeconds: Double = 0
    var errorMessage: String?
}
