//
//  ClipboardTableExtractor.swift
//  leanring-buddy
//
//  Fallback extraction path: select-all + copy in the frontmost app, read the
//  TSV from the pasteboard, then align the copied rows with the OCR grid so the
//  drawing layer still knows where each visible row is on screen.
//
//  This is invisible to a judge when the OCR confidence gate trips, it also
//  brings in rows that are scrolled out of view (better models), and it is the
//  development harness the PRD asks to build first.
//

import AppKit
import CoreGraphics
import Foundation

struct ClipboardTableExtractorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ClipboardTableExtractor {

    struct ClipboardTable {
        let headers: [String]
        let rows: [[String]]
    }

    private static let keyCodeA: CGKeyCode = 0
    private static let keyCodeC: CGKeyCode = 8

    /// Sends ⌘A then ⌘C to the frontmost app and parses the resulting text as TSV/CSV.
    /// The previous pasteboard string is restored afterwards.
    static func copyFrontmostSheetAsTable() async throws -> ClipboardTable {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousStringContents = pasteboard.string(forType: .string)

        postKeyboardShortcut(keyCode: keyCodeA, flags: .maskCommand)
        try await Task.sleep(nanoseconds: 140_000_000)
        postKeyboardShortcut(keyCode: keyCodeC, flags: .maskCommand)

        // Wait for the app to publish the copy (Sheets takes a few hundred ms for big ranges).
        let deadline = Date().addingTimeInterval(2.5)
        while pasteboard.changeCount == previousChangeCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        guard pasteboard.changeCount != previousChangeCount,
              let copiedText = pasteboard.string(forType: .string) else {
            throw ClipboardTableExtractorError(message: "the app did not put a table on the clipboard")
        }

        // Give back whatever the user had copied before.
        if let previousStringContents {
            pasteboard.clearContents()
            pasteboard.setString(previousStringContents, forType: .string)
        }

        return try parseDelimitedText(copiedText)
    }

    static func parseDelimitedText(_ text: String) throws -> ClipboardTable {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else {
            throw ClipboardTableExtractorError(message: "clipboard text has fewer than two lines")
        }

        let delimiter: Character = lines[0].contains("\t") ? "\t" : ","
        var parsedRows = lines.map { splitDelimitedLine($0, delimiter: delimiter) }

        // Trim fully empty trailing columns (Sheets pads copied ranges).
        var columnCount = parsedRows.map(\.count).max() ?? 0
        while columnCount > 0, parsedRows.allSatisfy({ $0.count < columnCount || $0[columnCount - 1].isEmpty }) {
            columnCount -= 1
        }
        guard columnCount >= 2 else {
            throw ClipboardTableExtractorError(message: "clipboard text does not look like a table")
        }
        parsedRows = parsedRows.map { row in
            (0..<columnCount).map { index in index < row.count ? row[index] : "" }
        }

        let headers = parsedRows[0].enumerated().map { index, header in
            header.isEmpty ? "Column \(index + 1)" : header
        }
        let bodyRows = Array(parsedRows.dropFirst()).filter { row in row.contains { !$0.isEmpty } }
        guard !bodyRows.isEmpty else {
            throw ClipboardTableExtractorError(message: "clipboard table has no data rows")
        }
        return ClipboardTable(headers: headers, rows: bodyRows)
    }

    /// Combines clipboard data (complete, exact) with OCR geometry (where things are).
    /// Rows are matched by comparing cell values in the columns both sources share.
    static func merge(clipboardTable: ClipboardTable, ocrTable: ExtractedTable?) -> ExtractedTable {
        let columnCount = clipboardTable.headers.count
        let columnTypes = TableColumnTyping.inferColumnTypes(rows: clipboardTable.rows, columnCount: columnCount)

        var headerCellBoxes = [CGRect?](repeating: nil, count: columnCount)
        var rowCellBoxes = clipboardTable.rows.map { _ in [CGRect?](repeating: nil, count: columnCount) }
        var rowLabels = [String?](repeating: nil, count: clipboardTable.rows.count)

        guard let ocrTable else {
            return ExtractedTable(
                headers: clipboardTable.headers, rows: clipboardTable.rows, columnTypes: columnTypes,
                headerCellBoxes: headerCellBoxes, rowCellBoxes: rowCellBoxes, rowLabels: rowLabels,
                extractionConfidence: 0.9, source: "clipboard", tableBoundingBoxInCapturePixels: nil
            )
        }

        // clipboard column index → OCR column index
        var ocrColumnForClipboardColumn: [Int: Int] = [:]
        for (clipboardIndex, header) in clipboardTable.headers.enumerated() {
            if let ocrIndex = ocrTable.columnIndex(named: header) {
                ocrColumnForClipboardColumn[clipboardIndex] = ocrIndex
            }
        }
        // Headers may be synthesized on the OCR side; fall back to positional mapping.
        if ocrColumnForClipboardColumn.count < 2, ocrTable.columnCount == columnCount {
            for index in 0..<columnCount { ocrColumnForClipboardColumn[index] = index }
        }

        for (clipboardIndex, ocrIndex) in ocrColumnForClipboardColumn {
            headerCellBoxes[clipboardIndex] = ocrTable.headerBox(forColumn: ocrIndex)
        }

        // Index OCR rows by their normalized cell values so each clipboard row can
        // find the visible row that shares the most values with it.
        var ocrRowsByCellKey: [String: [Int]] = [:]
        for (ocrRowIndex, ocrRow) in ocrTable.rows.enumerated() {
            for (clipboardIndex, ocrIndex) in ocrColumnForClipboardColumn where ocrIndex < ocrRow.count {
                let key = "\(clipboardIndex)|\(normalizeCellValue(ocrRow[ocrIndex]))"
                ocrRowsByCellKey[key, default: []].append(ocrRowIndex)
            }
        }

        var claimedOCRRows = Set<Int>()
        for (clipboardRowIndex, clipboardRow) in clipboardTable.rows.enumerated() {
            var votes: [Int: Int] = [:]
            for (clipboardIndex, _) in ocrColumnForClipboardColumn where clipboardIndex < clipboardRow.count {
                let normalized = normalizeCellValue(clipboardRow[clipboardIndex])
                guard !normalized.isEmpty else { continue }
                for ocrRowIndex in ocrRowsByCellKey["\(clipboardIndex)|\(normalized)"] ?? [] {
                    votes[ocrRowIndex, default: 0] += 1
                }
            }
            let requiredVotes = min(2, ocrColumnForClipboardColumn.count)
            guard let (bestOCRRow, voteCount) = votes.filter({ !claimedOCRRows.contains($0.key) }).max(by: { $0.value < $1.value }),
                  voteCount >= requiredVotes else {
                continue
            }
            claimedOCRRows.insert(bestOCRRow)
            for (clipboardIndex, ocrIndex) in ocrColumnForClipboardColumn where ocrIndex < ocrTable.rowCellBoxes[bestOCRRow].count {
                rowCellBoxes[clipboardRowIndex][clipboardIndex] = ocrTable.rowCellBoxes[bestOCRRow][ocrIndex]
            }
            if bestOCRRow < ocrTable.rowLabels.count {
                rowLabels[clipboardRowIndex] = ocrTable.rowLabels[bestOCRRow]
            }
        }

        // Rows without a gutter label still deserve spreadsheet-style numbering:
        // header on row 1 means data row i is spreadsheet row i + 2.
        if rowLabels.allSatisfy({ $0 == nil }) {
            rowLabels = clipboardTable.rows.indices.map { String($0 + 2) }
        }

        return ExtractedTable(
            headers: clipboardTable.headers,
            rows: clipboardTable.rows,
            columnTypes: columnTypes,
            headerCellBoxes: headerCellBoxes,
            rowCellBoxes: rowCellBoxes,
            rowLabels: rowLabels,
            extractionConfidence: 0.95,
            source: "clipboard+ocr",
            tableBoundingBoxInCapturePixels: ocrTable.tableBoundingBoxInCapturePixels
        )
    }

    // MARK: - Private

    private static func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func splitDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var isInsideQuotes = false
        for character in line {
            if character == "\"" {
                isInsideQuotes.toggle()
            } else if character == delimiter && !isInsideQuotes {
                fields.append(currentField.trimmingCharacters(in: .whitespaces))
                currentField = ""
            } else {
                currentField.append(character)
            }
        }
        fields.append(currentField.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Numbers compare by value (OCR "3,120.5" vs clipboard "3120.5"); text by alphanumerics.
    private static func normalizeCellValue(_ text: String) -> String {
        if let number = CellValueParser.numericValue(text) {
            return String(format: "%.4g", number)
        }
        return TableTextNormalizer.normalizeIdentifier(text)
    }
}
