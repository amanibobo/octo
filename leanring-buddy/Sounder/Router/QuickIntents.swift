//
//  QuickIntents.swift
//  leanring-buddy
//
//  Small, deterministic intents that pair a circled region with a short spoken
//  command: copy what's inside as CSV/JSON/markdown, do arithmetic on a
//  circled number, or type a phrase into the circled field. No model call.
//

import CoreGraphics
import Foundation

struct GestureTrailPoint: Equatable {
    let position: CGPoint
    let time: TimeInterval
}

// MARK: - Lasso to extract

enum ExtractFormat: String {
    case csv
    case json
    case markdown
    case text
}

struct ExtractRequest {
    let format: ExtractFormat
}

enum ExtractIntent {
    private static let verbs = ["copy", "extract", "grab", "clipboard", "export", "pull out", "get me", "give me"]
    private static let objects = ["table", "this", "these", "those", "that", "text", "rows", "data", "chart", "numbers", "list", "cells", "csv", "json", "markdown"]

    static func detect(_ transcript: String, hasRegion: Bool) -> ExtractRequest? {
        let lowered = transcript.lowercased()
        let hasVerb = verbs.contains { lowered.contains($0) }
        let hasObject = objects.contains { lowered.contains($0) }
        let mentionsFormat = lowered.contains("csv") || lowered.contains("json") || lowered.contains("markdown") || lowered.contains("clipboard")
        guard hasVerb && (hasObject || mentionsFormat) else { return nil }
        // Without a circle, only an explicit table/format request counts, so "copy that" in
        // conversation does not hijack a General question.
        guard hasRegion || lowered.contains("table") || mentionsFormat else { return nil }
        let format: ExtractFormat
        if lowered.contains("json") { format = .json }
        else if lowered.contains("markdown") { format = .markdown }
        else if lowered.contains("csv") { format = .csv }
        else if lowered.contains("text") || lowered.contains("paragraph") { format = .text }
        else { format = .csv }
        return ExtractRequest(format: format)
    }

    /// Rows and columns straight from OCR word boxes (Vision lines span columns,
    /// words do not): words that share a baseline form a row; columns are the
    /// bands of x that words occupy, split wherever there is a gap wider than
    /// a word space. Good enough for a clean copy when the stricter table
    /// extractor is not confident.
    static func grid(from lines: [RecognizedTextLine]) -> (headers: [String], rows: [[String]]) {
        var words = lines.flatMap(\.words).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if words.isEmpty {
            // No word boxes (e.g. rewind frames): fall back to whole lines as single cells.
            words = lines.map { RecognizedWord(text: $0.text, boundingBoxInCapturePixels: $0.boundingBoxInCapturePixels, confidence: $0.confidence) }
        }
        guard !words.isEmpty else { return ([], []) }
        let heights = words.map(\.boundingBoxInCapturePixels.height).sorted()
        let medianHeight = max(heights[heights.count / 2], 4)

        // Column bands along x: a gap wider than ~a word space starts a new column.
        var bands: [(minX: CGFloat, maxX: CGFloat)] = []
        for word in words.sorted(by: { $0.boundingBoxInCapturePixels.minX < $1.boundingBoxInCapturePixels.minX }) {
            let box = word.boundingBoxInCapturePixels
            if let last = bands.last, box.minX <= last.maxX + medianHeight * 0.7 {
                bands[bands.count - 1].maxX = max(last.maxX, box.maxX)
            } else {
                bands.append((box.minX, box.maxX))
            }
        }
        func columnIndex(for word: RecognizedWord) -> Int {
            let midX = word.boundingBoxInCapturePixels.midX
            if let exact = bands.firstIndex(where: { midX >= $0.minX && midX <= $0.maxX }) { return exact }
            var best = 0
            for (index, band) in bands.enumerated() where abs((band.minX + band.maxX) / 2 - midX) < abs((bands[best].minX + bands[best].maxX) / 2 - midX) { best = index }
            return best
        }

        // Rows: cluster by vertical centre.
        let byY = words.sorted { $0.boundingBoxInCapturePixels.midY < $1.boundingBoxInCapturePixels.midY }
        var rows: [[RecognizedWord]] = []
        for word in byY {
            if let last = rows.last?.last, abs(word.boundingBoxInCapturePixels.midY - last.boundingBoxInCapturePixels.midY) < medianHeight * 0.65 {
                rows[rows.count - 1].append(word)
            } else {
                rows.append([word])
            }
        }
        var grid: [[String]] = []
        for row in rows {
            var cells = Array(repeating: "", count: bands.count)
            for word in row.sorted(by: { $0.boundingBoxInCapturePixels.minX < $1.boundingBoxInCapturePixels.minX }) {
                let column = columnIndex(for: word)
                cells[column] = cells[column].isEmpty ? word.text : cells[column] + " " + word.text
            }
            grid.append(cells)
        }
        // Wrapped cells: a row with an empty first cell continues the previous row.
        var merged: [[String]] = []
        for cells in grid {
            if let previous = merged.last, cells.first?.isEmpty == true, !previous[0].isEmpty {
                merged[merged.count - 1] = zip(previous, cells).map { $1.isEmpty ? $0 : ($0.isEmpty ? $1 : $0 + " " + $1) }
            } else {
                merged.append(cells)
            }
        }
        // Drop columns that are empty everywhere.
        let columnCount = merged.first?.count ?? 0
        let keptColumns = (0..<columnCount).filter { column in merged.contains { !$0[column].isEmpty } }
        let compacted = merged.map { row in keptColumns.map { row[$0] } }
        guard compacted.count >= 2 else { return ([], compacted) }
        let firstRowHasNumbers = compacted[0].contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        return firstRowHasNumbers ? ([], compacted) : (compacted[0], Array(compacted.dropFirst()))
    }

    static func csv(headers: [String], rows: [[String]]) -> String {
        func escape(_ cell: String) -> String {
            let needsQuotes = cell.contains(",") || cell.contains("\"") || cell.contains("\n")
            return needsQuotes ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
        }
        var lines: [String] = []
        if !headers.isEmpty { lines.append(headers.map(escape).joined(separator: ",")) }
        for row in rows { lines.append(row.map(escape).joined(separator: ",")) }
        return lines.joined(separator: "\n")
    }

    static func markdown(headers: [String], rows: [[String]]) -> String {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        let headerCells = (0..<columnCount).map { $0 < headers.count && !headers[$0].isEmpty ? headers[$0] : "col \($0 + 1)" }
        var lines = ["| " + headerCells.joined(separator: " | ") + " |", "|" + String(repeating: " --- |", count: columnCount)]
        for row in rows {
            let cells = (0..<columnCount).map { $0 < row.count ? row[$0].replacingOccurrences(of: "|", with: "\\|") : "" }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func json(headers: [String], rows: [[String]]) -> String {
        let keys = headers.enumerated().map { $0.element.isEmpty ? "col_\($0.offset + 1)" : $0.element }
        let objects: [[String: String]] = rows.map { row in
            var object: [String: String] = [:]
            for (index, cell) in row.enumerated() {
                let key = index < keys.count ? keys[index] : "col_\(index + 1)"
                object[key] = cell
            }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

// MARK: - Ink math (spoken form)

struct InkMathRequest {
    enum Operation {
        case multiply(Double)
        case divide(Double)
        case add(Double)
        case subtract(Double)
        case percentOf(Double)          // "20 percent of"
        case increasePercent(Double)    // "plus 20 percent", "up 20 percent"
        case decreasePercent(Double)    // "minus 20 percent", "20 percent off"
        case sum
        case average
        case maximum
        case minimum
    }
    let operation: Operation
    let spokenOperation: String
}

enum InkMathIntent {
    private static let numberPattern = try! NSRegularExpression(pattern: #"(-?\d[\d,]*(?:\.\d+)?)"#)

    /// Only fires with a circled region: "times 1.2", "plus 15 percent", "sum these".
    static func detect(_ transcript: String) -> InkMathRequest? {
        let lowered = transcript.lowercased()
            .replacingOccurrences(of: "×", with: " times ")
            .replacingOccurrences(of: "percent", with: "%")
            .replacingOccurrences(of: " per cent", with: "%")
        let numbers = numberPattern.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered))
            .compactMap { Range($0.range(at: 1), in: lowered) }
            .compactMap { Double(lowered[$0].replacingOccurrences(of: ",", with: "")) }
        let hasPercent = lowered.contains("%")
        let aggregates: [(String, InkMathRequest.Operation, String)] = [
            ("average", .average, "the average"), ("mean", .average, "the average"),
            ("sum", .sum, "the sum"), ("total", .sum, "the total"), ("add these", .sum, "the total"), ("add them", .sum, "the total"), ("add up", .sum, "the total"),
            ("max", .maximum, "the largest"), ("largest", .maximum, "the largest"), ("highest", .maximum, "the largest"),
            ("min", .minimum, "the smallest"), ("smallest", .minimum, "the smallest"), ("lowest", .minimum, "the smallest"),
        ]
        if numbers.isEmpty {
            for (keyword, operation, spoken) in aggregates where lowered.contains(keyword) {
                return InkMathRequest(operation: operation, spokenOperation: spoken)
            }
            return nil
        }
        guard let value = numbers.first else { return nil }
        if hasPercent {
            if lowered.contains("off") || lowered.contains("minus") || lowered.contains("less") || lowered.contains("down") || lowered.contains("decrease") || lowered.contains("discount") {
                return InkMathRequest(operation: .decreasePercent(value), spokenOperation: "minus \(format(value)) percent")
            }
            if lowered.contains(" of") && !lowered.contains("plus") && !lowered.contains("up") && !lowered.contains("increase") {
                return InkMathRequest(operation: .percentOf(value), spokenOperation: "\(format(value)) percent of")
            }
            return InkMathRequest(operation: .increasePercent(value), spokenOperation: "plus \(format(value)) percent")
        }
        if lowered.contains("times") || lowered.contains("multipl") || lowered.contains(" x ") || lowered.hasPrefix("x ") {
            return InkMathRequest(operation: .multiply(value), spokenOperation: "times \(format(value))")
        }
        if lowered.contains("divided") || lowered.contains("divide") || lowered.contains(" over ") {
            return InkMathRequest(operation: .divide(value), spokenOperation: "divided by \(format(value))")
        }
        if lowered.contains("plus") || lowered.contains("add ") || lowered.contains("added") {
            return InkMathRequest(operation: .add(value), spokenOperation: "plus \(format(value))")
        }
        if lowered.contains("minus") || lowered.contains("subtract") || lowered.contains("less ") || lowered.contains("take away") {
            return InkMathRequest(operation: .subtract(value), spokenOperation: "minus \(format(value))")
        }
        return nil
    }

    /// Numbers found in OCR text, in reading order, with their prefix ($) and suffix (%) kept.
    static func numbers(in text: String) -> [(value: Double, prefix: String, suffix: String)] {
        let pattern = try! NSRegularExpression(pattern: #"([$€£]?)\s?(-?\d[\d,]*(?:\.\d+)?)\s?(%?)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let numberRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange].replacingOccurrences(of: ",", with: "")) else { return nil }
            let prefix = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let suffix = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            return (value, prefix, suffix)
        }
    }

    static func apply(_ operation: InkMathRequest.Operation, to values: [Double]) -> Double? {
        guard let first = values.first else { return nil }
        switch operation {
        case .multiply(let by): return first * by
        case .divide(let by): return by == 0 ? nil : first / by
        case .add(let amount): return first + amount
        case .subtract(let amount): return first - amount
        case .percentOf(let percent): return first * percent / 100
        case .increasePercent(let percent): return first * (1 + percent / 100)
        case .decreasePercent(let percent): return first * (1 - percent / 100)
        case .sum: return values.reduce(0, +)
        case .average: return values.reduce(0, +) / Double(values.count)
        case .maximum: return values.max()
        case .minimum: return values.min()
        }
    }

    static func format(_ value: Double, decimals: Int? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        let wanted = decimals ?? (value == value.rounded() ? 0 : 2)
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = wanted
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Dictate into a circled field

enum DictateIntent {
    private static let starters = ["type ", "write ", "enter ", "put ", "fill in ", "fill this with ", "input "]

    /// "type hello world" → "hello world". Only used when a region was circled.
    static func text(from transcript: String) -> String? {
        let lowered = transcript.lowercased()
        for starter in starters where lowered.hasPrefix(starter) {
            var payload = String(transcript.dropFirst(starter.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            for filler in ["in here", "in there", "here", "there", "into this field", "in this field", "into this", "in this"] {
                if payload.lowercased().hasSuffix(" " + filler) { payload = String(payload.dropLast(filler.count + 1)) }
            }
            payload = payload.trimmingCharacters(in: CharacterSet(charactersIn: " .\"“”"))
            return payload.isEmpty ? nil : payload
        }
        return nil
    }
}
