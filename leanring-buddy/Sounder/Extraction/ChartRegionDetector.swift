//
//  ChartRegionDetector.swift
//  leanring-buddy
//
//  Finds a numeric chart on screen from its tick labels alone: a vertical stack
//  of right-aligned numbers that decrease downward is a y axis, a horizontal run
//  of numbers that increase rightward is an x axis. Both are fitted linearly so
//  data-space curve points from the analysis service can be drawn in place.
//  Limitation: categorical/date x axes are not calibrated (numeric ticks only).
//

import CoreGraphics
import Foundation

nonisolated enum ChartRegionDetector {
    /// Set SOUNDER_DEBUG_CHART=1 in the scheme's environment to trace axis detection.
    private static let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["SOUNDER_DEBUG_CHART"] == "1"


    private struct NumericWord {
        let value: Double
        let box: CGRect
    }

    private struct AxisCandidate {
        let words: [NumericWord]
        let calibration: AxisCalibration
        var minX: CGFloat { words.map { $0.box.minX }.min() ?? 0 }
        var maxX: CGFloat { words.map { $0.box.maxX }.max() ?? 0 }
        var minY: CGFloat { words.map { $0.box.minY }.min() ?? 0 }
        var maxY: CGFloat { words.map { $0.box.maxY }.max() ?? 0 }
    }

    static func detectChart(in lines: [RecognizedTextLine], imageSize: CGSize, excluding excludedRegion: CGRect?) -> ChartRegion? {
        let numericWords: [NumericWord] = lines.flatMap(\.words).compactMap { word in
            guard word.text.count <= 10, let value = CellValueParser.numericValue(word.text) else { return nil }
            let box = word.boundingBoxInCapturePixels
            if let excludedRegion, excludedRegion.insetBy(dx: -4, dy: -4).contains(CGPoint(x: box.midX, y: box.midY)) {
                return nil
            }
            return NumericWord(value: value, box: box)
        }
        guard numericWords.count >= 6 else { return nil }

        let medianHeight = TableExtractor.median(numericWords.map { $0.box.height })
        guard medianHeight > 0 else { return nil }
        let tolerance = medianHeight * 0.8

        let yAxisGroups = cluster(numericWords, key: { $0.box.maxX }, tolerance: tolerance)
        let xAxisGroups = cluster(numericWords, key: { $0.box.midY }, tolerance: tolerance)
        let yAxisCandidates = yAxisGroups.compactMap { makeYAxisCandidate($0, medianHeight: medianHeight) }
        let xAxisCandidates = xAxisGroups.compactMap { makeXAxisCandidate($0, medianHeight: medianHeight) }
        if isDebugLoggingEnabled {
            print("📈 chart debug: \(numericWords.count) numeric words, median height \(medianHeight)")
            for group in yAxisGroups { print("   y-group:", group.map { "\($0.value)@y\(Int($0.box.midY)) maxX\(Int($0.box.maxX))" }) }
            for group in xAxisGroups { print("   x-group:", group.map { "\($0.value)@x\(Int($0.box.midX)) y\(Int($0.box.midY))" }) }
            print("   candidates: \(yAxisCandidates.count) y, \(xAxisCandidates.count) x")
        }
        guard !yAxisCandidates.isEmpty, !xAxisCandidates.isEmpty else { return nil }

        var bestPair: (yAxis: AxisCandidate, xAxis: AxisCandidate, area: CGFloat)?
        for yAxis in yAxisCandidates {
            for xAxis in xAxisCandidates {
                // The x-axis labels sit below the y-axis labels and start near their right edge.
                let sitsBelow = xAxis.minY >= yAxis.maxY - medianHeight * 1.5
                let startsToTheRight = xAxis.minX >= yAxis.maxX - medianHeight * 2 && xAxis.minX <= yAxis.maxX + medianHeight * 10
                guard sitsBelow, startsToTheRight else { continue }
                let area = (xAxis.maxX - yAxis.maxX) * (xAxis.minY - yAxis.minY)
                if area > (bestPair?.area ?? 0) {
                    bestPair = (yAxis, xAxis, area)
                }
            }
        }
        guard let pair = bestPair else { return nil }

        let plotBox = CGRect(
            x: pair.yAxis.maxX + medianHeight * 0.3,
            y: pair.yAxis.minY,
            width: max(1, pair.xAxis.maxX - pair.yAxis.maxX - medianHeight * 0.3),
            height: max(1, pair.xAxis.minY - pair.yAxis.minY)
        )
        return ChartRegion(
            boundingBoxInCapturePixels: plotBox,
            xAxisCalibration: pair.xAxis.calibration,
            yAxisCalibration: pair.yAxis.calibration,
            xTickValues: pair.xAxis.words.map(\.value),
            yTickValues: pair.yAxis.words.map(\.value)
        )
    }

    private static func cluster(_ words: [NumericWord], key: (NumericWord) -> CGFloat, tolerance: CGFloat) -> [[NumericWord]] {
        let sorted = words.sorted { key($0) < key($1) }
        var groups: [[NumericWord]] = []
        for word in sorted {
            if let last = groups.last, let reference = last.last, abs(key(word) - key(reference)) <= tolerance {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.filter { $0.count >= 3 }
    }

    /// Tick labels are evenly spaced; a stray number that happens to share a row or
    /// column (a spreadsheet gutter number, a toolbar badge) sits far from the rest.
    /// Keep the longest run whose neighbour gaps stay near the median gap.
    private static func trimStrayWords(_ sortedWords: [NumericWord], position: (NumericWord) -> CGFloat) -> [NumericWord] {
        guard sortedWords.count >= 3 else { return sortedWords }
        let gaps = zip(sortedWords, sortedWords.dropFirst()).map { position($1) - position($0) }
        let medianGap = TableExtractor.median(gaps)
        guard medianGap > 0 else { return sortedWords }

        var bestRun: [NumericWord] = []
        var currentRun: [NumericWord] = [sortedWords[0]]
        for (index, gap) in gaps.enumerated() {
            let isRegularGap = gap <= medianGap * 2.5 && gap >= medianGap * 0.25
            if isRegularGap {
                currentRun.append(sortedWords[index + 1])
            } else {
                if currentRun.count > bestRun.count { bestRun = currentRun }
                currentRun = [sortedWords[index + 1]]
            }
        }
        if currentRun.count > bestRun.count { bestRun = currentRun }
        return bestRun
    }

    private static func makeYAxisCandidate(_ group: [NumericWord], medianHeight: CGFloat) -> AxisCandidate? {
        let sorted = trimStrayWords(group.sorted { $0.box.midY < $1.box.midY }, position: { $0.box.midY })
        guard sorted.count >= 3 else { return nil }
        // Top label has the largest value on a normal y axis.
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.value > $1.value }) else { return nil }
        guard (sorted.last!.box.midY - sorted.first!.box.midY) >= medianHeight * 5 else { return nil }
        guard let calibration = AxisCalibration.fit(values: sorted.map(\.value), pixels: sorted.map { $0.box.midY }),
              isLinear(sorted.map(\.value), sorted.map { $0.box.midY }, calibration: calibration, tolerance: medianHeight * 0.6) else {
            return nil
        }
        return AxisCandidate(words: sorted, calibration: calibration)
    }

    private static func makeXAxisCandidate(_ group: [NumericWord], medianHeight: CGFloat) -> AxisCandidate? {
        let sorted = trimStrayWords(group.sorted { $0.box.midX < $1.box.midX }, position: { $0.box.midX })
        guard sorted.count >= 3 else { return nil }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.value < $1.value }) else { return nil }
        guard (sorted.last!.box.midX - sorted.first!.box.midX) >= medianHeight * 6 else { return nil }
        guard let calibration = AxisCalibration.fit(values: sorted.map(\.value), pixels: sorted.map { $0.box.midX }),
              isLinear(sorted.map(\.value), sorted.map { $0.box.midX }, calibration: calibration, tolerance: medianHeight * 0.6) else {
            return nil
        }
        return AxisCandidate(words: sorted, calibration: calibration)
    }

    private static func isLinear(_ values: [Double], _ pixels: [CGFloat], calibration: AxisCalibration, tolerance: CGFloat) -> Bool {
        zip(values, pixels).allSatisfy { value, pixel in
            abs(calibration.pixel(forValue: value) - pixel) <= tolerance
        }
    }
}
