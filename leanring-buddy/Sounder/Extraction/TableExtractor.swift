//
//  TableExtractor.swift
//  leanring-buddy
//
//  Rebuilds a spreadsheet grid from OCR word boxes with no network call.
//
//  Approach (classical, deterministic):
//    1. cluster words into text rows by vertical centre,
//    2. find the longest run of evenly pitched rows (that is the table body),
//    3. project the run's word boxes onto the x axis; x ranges almost no row
//       covers are column separators (this survives left-aligned text next to
//       right-aligned numbers, where edge clustering fails),
//    4. assign words to columns, merge words in the same cell, detect the
//       header row and the spreadsheet row-number gutter,
//    5. type each column and score confidence from fill ratio + OCR confidence.
//
//  The fine-tuned RF-DETR extractor (services/extractor) is a drop-in
//  replacement that produces the same ExtractedTable; this path is what runs
//  when that service is unavailable, and it is the P0 dev harness.
//

import CoreGraphics
import Foundation

nonisolated enum CellValueParser {
    private static let strippedCharacters = CharacterSet(charactersIn: "$€£¥,%\u{00A0} ")
    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$"#)

    static func numericValue(_ text: String) -> Double? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        var isAccountingNegative = false
        if candidate.hasPrefix("("), candidate.hasSuffix(")") {
            isAccountingNegative = true
            candidate = String(candidate.dropFirst().dropLast())
        }
        candidate = String(candidate.unicodeScalars.filter { !strippedCharacters.contains($0) })
        // OCR often reads the minus sign as an en dash.
        candidate = candidate.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        guard let value = Double(candidate), value.isFinite else { return nil }
        return isAccountingNegative ? -value : value
    }

    static func integerValue(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return Int(trimmed)
    }

    static func looksLikeDate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return datePattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }
}

nonisolated enum TableColumnTyping {
    static func inferColumnTypes(rows: [[String]], columnCount: Int) -> [TableColumnType] {
        (0..<columnCount).map { columnIndex in
            let values = rows.compactMap { row -> String? in
                guard columnIndex < row.count else { return nil }
                let value = row[columnIndex].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard !values.isEmpty else { return .text }

            let numericShare = Double(values.filter { CellValueParser.numericValue($0) != nil }.count) / Double(values.count)
            if numericShare >= 0.8 { return .numeric }

            let dateShare = Double(values.filter { CellValueParser.looksLikeDate($0) }.count) / Double(values.count)
            if dateShare >= 0.8 { return .date }

            let uniqueCount = Set(values.map { $0.lowercased() }).count
            if uniqueCount <= max(12, Int(0.05 * Double(values.count))) { return .categorical }
            return .text
        }
    }
}

nonisolated enum TableExtractor {
    static let minimumBodyRows = 3
    static let minimumColumns = 2

    private struct TextRow {
        var words: [RecognizedWord]
        var midY: CGFloat { words.map { $0.boundingBoxInCapturePixels.midY }.reduce(0, +) / CGFloat(words.count) }
        var minX: CGFloat { words.map { $0.boundingBoxInCapturePixels.minX }.min() ?? 0 }
        var maxX: CGFloat { words.map { $0.boundingBoxInCapturePixels.maxX }.max() ?? 0 }
        var medianHeight: CGFloat { TableExtractor.median(words.map { $0.boundingBoxInCapturePixels.height }) }
    }

    private struct GridCell {
        var text: String
        var box: CGRect
    }

    static func extractTable(from lines: [RecognizedTextLine], imageSize: CGSize) -> ExtractedTable? {
        let allWords = lines.flatMap(\.words).filter { word in
            let height = word.boundingBoxInCapturePixels.height
            return height > 0 && height < imageSize.height * 0.05 && !word.text.isEmpty
        }
        guard allWords.count >= 8 else { return nil }

        let medianWordHeight = median(allWords.map { $0.boundingBoxInCapturePixels.height })
        guard medianWordHeight > 0 else { return nil }

        let textRows = clusterIntoRows(allWords, verticalTolerance: medianWordHeight * 0.5)

        // Spreadsheet chrome: the column-letter strip (A B C D ...) sits right above the grid.
        let columnLetterRow = textRows.first { row in
            row.words.count >= 3 && row.words.allSatisfy { isColumnLetter($0.text) }
        }

        let candidateRows = textRows.filter { row in
            row.words.count >= 2 && !(columnLetterRow.map { $0.midY == row.midY } ?? false)
        }
        guard candidateRows.count >= minimumBodyRows + 1 else { return nil }

        guard var run = longestEvenlyPitchedRun(candidateRows, medianWordHeight: medianWordHeight),
              run.count >= minimumBodyRows + 1 else {
            return nil
        }

        // Column separators from the x-coverage profile of the run.
        let columnSpans = detectColumnSpans(rows: run, medianWordHeight: medianWordHeight)
        guard columnSpans.count >= minimumColumns else { return nil }

        var grid: [[GridCell?]] = run.map { row in assignWordsToColumns(row.words, columnSpans: columnSpans) }

        // Drop phantom columns (created by a single long number spilling into a gap).
        let keptColumnIndices = (0..<columnSpans.count).filter { columnIndex in
            let filledCount = grid.filter { $0[columnIndex] != nil }.count
            return Double(filledCount) / Double(grid.count) >= 0.3
        }
        guard keptColumnIndices.count >= minimumColumns else { return nil }
        grid = grid.map { row in keptColumnIndices.map { row[$0] } }
        var columnLetterHeaders = columnLetterRow.map { letterRow in
            keptColumnIndices.map { columnIndex -> String? in
                let span = columnSpans[columnIndex]
                return letterRow.words.first { span.contains($0.boundingBoxInCapturePixels.midX) }?.text
            }
        }

        // Trim sparse leading/trailing rows (toolbar or status-bar text caught in the run).
        let columnCount = keptColumnIndices.count
        while grid.count > minimumBodyRows + 1, filledCount(grid.first!) < max(2, columnCount / 2) {
            grid.removeFirst(); run.removeFirst()
        }
        while grid.count > minimumBodyRows + 1, filledCount(grid.last!) < max(2, columnCount / 2) {
            grid.removeLast(); run.removeLast()
        }
        guard grid.count >= minimumBodyRows + 1 else { return nil }

        // Row-number gutter: a column of consecutive integers → spreadsheet row labels.
        var rowLabels: [String?] = Array(repeating: nil, count: grid.count)
        if let gutterColumnIndex = detectRowNumberGutter(grid) {
            rowLabels = grid.map { $0[gutterColumnIndex]?.text }
            grid = grid.map { row in row.enumerated().filter { $0.offset != gutterColumnIndex }.map(\.element) }
            columnLetterHeaders = columnLetterHeaders.map { headers in
                headers.enumerated().filter { $0.offset != gutterColumnIndex }.map(\.element)
            }
        }
        let finalColumnCount = grid.first?.count ?? 0
        guard finalColumnCount >= minimumColumns else { return nil }

        // Header row detection: fewer numbers than a typical body row.
        let firstRowNumericCount = numericCellCount(grid[0])
        let firstRowFilledCount = filledCount(grid[0])
        let bodyNumericMedian = median(grid.dropFirst().map { CGFloat(numericCellCount($0)) })
        let hasHeaderRow = firstRowFilledCount > 0
            && (Double(firstRowNumericCount) <= Double(firstRowFilledCount) * 0.5)
            && (CGFloat(firstRowNumericCount) < bodyNumericMedian || bodyNumericMedian == 0)

        var headers: [String]
        var headerCellBoxes: [CGRect?]
        var bodyGrid: [[GridCell?]]
        var bodyRowLabels: [String?]
        if hasHeaderRow {
            headers = grid[0].enumerated().map { index, cell in
                cell?.text ?? columnLetterHeaders?[index] ?? "Column \(index + 1)"
            }
            headerCellBoxes = grid[0].map { $0?.box }
            bodyGrid = Array(grid.dropFirst())
            bodyRowLabels = Array(rowLabels.dropFirst())
        } else {
            headers = (0..<finalColumnCount).map { columnLetterHeaders?[$0] ?? "Column \($0 + 1)" }
            headerCellBoxes = Array(repeating: nil, count: finalColumnCount)
            bodyGrid = grid
            bodyRowLabels = rowLabels
        }
        guard bodyGrid.count >= minimumBodyRows else { return nil }

        let rows = bodyGrid.map { row in row.map { $0?.text ?? "" } }
        let rowCellBoxes = bodyGrid.map { row in row.map { $0?.box } }
        let columnTypes = TableColumnTyping.inferColumnTypes(rows: rows, columnCount: finalColumnCount)

        let totalCells = bodyGrid.count * finalColumnCount
        let filledCells = bodyGrid.reduce(0) { $0 + filledCount($1) }
        let fillRatio = Double(filledCells) / Double(max(totalCells, 1))
        let meanOCRConfidence = Double(run.flatMap(\.words).map(\.confidence).reduce(0, +)) / Double(max(run.flatMap(\.words).count, 1))
        let extractionConfidence = min(1.0, 0.55 * fillRatio + 0.45 * meanOCRConfidence)

        let allBoxes = headerCellBoxes.compactMap { $0 } + rowCellBoxes.flatMap { $0.compactMap { $0 } }
        let tableBoundingBox = allBoxes.dropFirst().reduce(allBoxes.first) { partial, box in partial?.union(box) }

        return ExtractedTable(
            headers: headers,
            rows: rows,
            columnTypes: columnTypes,
            headerCellBoxes: headerCellBoxes,
            rowCellBoxes: rowCellBoxes,
            rowLabels: bodyRowLabels,
            extractionConfidence: extractionConfidence,
            source: "ondevice-ocr",
            tableBoundingBoxInCapturePixels: tableBoundingBox
        )
    }

    // MARK: - Row clustering

    private static func clusterIntoRows(_ words: [RecognizedWord], verticalTolerance: CGFloat) -> [TextRow] {
        let sortedWords = words.sorted { $0.boundingBoxInCapturePixels.midY < $1.boundingBoxInCapturePixels.midY }
        var rows: [TextRow] = []
        for word in sortedWords {
            if var lastRow = rows.last, abs(word.boundingBoxInCapturePixels.midY - lastRow.midY) <= verticalTolerance {
                lastRow.words.append(word)
                rows[rows.count - 1] = lastRow
            } else {
                rows.append(TextRow(words: [word]))
            }
        }
        return rows.map { row in
            TextRow(words: row.words.sorted { $0.boundingBoxInCapturePixels.minX < $1.boundingBoxInCapturePixels.minX })
        }
    }

    /// The table body is the longest sequence of rows with a regular vertical pitch,
    /// similar text height and overlapping horizontal extent.
    private static func longestEvenlyPitchedRun(_ rows: [TextRow], medianWordHeight: CGFloat) -> [TextRow]? {
        let sortedRows = rows.sorted { $0.midY < $1.midY }
        var bestRun: [TextRow] = []
        var currentRun: [TextRow] = []
        var runMinX: CGFloat = 0
        var runMaxX: CGFloat = 0

        for row in sortedRows {
            if let previousRow = currentRun.last {
                let verticalGap = row.midY - previousRow.midY
                let heightRatio = row.medianHeight / max(previousRow.medianHeight, 0.001)
                let overlapWidth = min(row.maxX, runMaxX) - max(row.minX, runMinX)
                let overlapShare = overlapWidth / max(runMaxX - runMinX, 1)
                let continuesRun = verticalGap <= medianWordHeight * 2.8
                    && heightRatio >= 0.55 && heightRatio <= 1.8
                    && overlapShare >= 0.3
                if continuesRun {
                    currentRun.append(row)
                    runMinX = min(runMinX, row.minX)
                    runMaxX = max(runMaxX, row.maxX)
                    continue
                }
                if currentRun.count > bestRun.count { bestRun = currentRun }
            }
            currentRun = [row]
            runMinX = row.minX
            runMaxX = row.maxX
        }
        if currentRun.count > bestRun.count { bestRun = currentRun }
        return bestRun.isEmpty ? nil : bestRun
    }

    // MARK: - Columns

    /// X ranges covered by text in almost no row are separators; what lies between them is a column.
    private static func detectColumnSpans(rows: [TextRow], medianWordHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        let tableMinX = rows.map(\.minX).min() ?? 0
        let tableMaxX = rows.map(\.maxX).max() ?? 0
        let width = Int((tableMaxX - tableMinX).rounded(.up)) + 1
        guard width > 2 else { return [] }

        // Words arrive already split at real ink gaps (InkSegmenter), so only a
        // small expansion is needed to absorb anti-aliasing and box rounding.
        let horizontalExpansion = medianWordHeight * 0.1
        var coverage = [Int](repeating: 0, count: width)

        for row in rows {
            var rowCoverage = [Bool](repeating: false, count: width)
            for word in row.words {
                let box = word.boundingBoxInCapturePixels
                let start = max(0, Int((box.minX - horizontalExpansion - tableMinX).rounded(.down)))
                let end = min(width - 1, Int((box.maxX + horizontalExpansion - tableMinX).rounded(.up)))
                guard start <= end else { continue }
                for x in start...end { rowCoverage[x] = true }
            }
            for x in 0..<width where rowCoverage[x] { coverage[x] += 1 }
        }

        let separatorThreshold = max(1, Int(Double(rows.count) * 0.15))
        var spans: [ClosedRange<CGFloat>] = []
        var spanStart: Int?
        for x in 0..<width {
            let isCovered = coverage[x] > separatorThreshold
            if isCovered, spanStart == nil {
                spanStart = x
            } else if !isCovered, let start = spanStart {
                appendSpan(start: start, end: x - 1, tableMinX: tableMinX, minimumWidth: medianWordHeight * 0.3, into: &spans)
                spanStart = nil
            }
        }
        if let start = spanStart {
            appendSpan(start: start, end: width - 1, tableMinX: tableMinX, minimumWidth: medianWordHeight * 0.3, into: &spans)
        }
        return spans
    }

    private static func appendSpan(start: Int, end: Int, tableMinX: CGFloat, minimumWidth: CGFloat, into spans: inout [ClosedRange<CGFloat>]) {
        let spanMinX = tableMinX + CGFloat(start)
        let spanMaxX = tableMinX + CGFloat(end)
        guard spanMaxX - spanMinX >= minimumWidth else { return }
        spans.append(spanMinX...spanMaxX)
    }

    private static func assignWordsToColumns(_ words: [RecognizedWord], columnSpans: [ClosedRange<CGFloat>]) -> [GridCell?] {
        var cells = [GridCell?](repeating: nil, count: columnSpans.count)
        for word in words {
            let box = word.boundingBoxInCapturePixels
            let columnIndex = columnSpans.firstIndex { $0.contains(box.midX) }
                ?? nearestSpanIndex(to: box.midX, in: columnSpans)
            guard let columnIndex else { continue }
            if var existingCell = cells[columnIndex] {
                existingCell.text += " " + word.text
                existingCell.box = existingCell.box.union(box)
                cells[columnIndex] = existingCell
            } else {
                cells[columnIndex] = GridCell(text: word.text, box: box)
            }
        }
        return cells
    }

    private static func nearestSpanIndex(to x: CGFloat, in spans: [ClosedRange<CGFloat>]) -> Int? {
        spans.enumerated().min { first, second in
            distance(from: x, to: first.element) < distance(from: x, to: second.element)
        }?.offset
    }

    private static func distance(from x: CGFloat, to span: ClosedRange<CGFloat>) -> CGFloat {
        if span.contains(x) { return 0 }
        return x < span.lowerBound ? span.lowerBound - x : x - span.upperBound
    }

    // MARK: - Header / gutter helpers

    private static func detectRowNumberGutter(_ grid: [[GridCell?]]) -> Int? {
        guard let columnCount = grid.first?.count, columnCount > minimumColumns else { return nil }
        for columnIndex in 0..<columnCount {
            let integers = grid.compactMap { row -> Int? in
                guard let cell = row[columnIndex] else { return nil }
                return CellValueParser.integerValue(cell.text)
            }
            guard Double(integers.count) >= Double(grid.count) * 0.85, integers.count >= 3 else { continue }
            let consecutivePairs = zip(integers, integers.dropFirst()).filter { $1 - $0 == 1 }.count
            if Double(consecutivePairs) >= Double(integers.count - 1) * 0.8 {
                return columnIndex
            }
        }
        return nil
    }

    private static func isColumnLetter(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (1...3).contains(trimmed.count) && trimmed.allSatisfy { $0.isUppercase && $0.isLetter }
    }

    private static func filledCount(_ row: [GridCell?]) -> Int {
        row.filter { $0 != nil }.count
    }

    private static func numericCellCount(_ row: [GridCell?]) -> Int {
        row.filter { cell in
            guard let cell else { return false }
            return CellValueParser.numericValue(cell.text) != nil
        }.count
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
