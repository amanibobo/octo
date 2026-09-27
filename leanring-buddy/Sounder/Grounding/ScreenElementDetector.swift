//
//  ScreenElementDetector.swift
//  leanring-buddy
//
//  On-device OCR grounding. Apple's Vision framework reads every text line on the
//  captured display and returns word-level boxes in capture pixels. Those boxes
//  feed three consumers: Set-of-Mark elements for General mode, the table
//  extractor for Data mode, and the chart-axis detector for curve fitting.
//  No network is involved, which keeps grounding fast and expo-Wi-Fi-proof.
//

import CoreGraphics
import Foundation
import Vision

nonisolated struct RecognizedWord: Sendable {
    let text: String
    let boundingBoxInCapturePixels: CGRect
    let confidence: Float
}

nonisolated struct RecognizedTextLine: Sendable {
    let text: String
    let boundingBoxInCapturePixels: CGRect
    let confidence: Float
    let words: [RecognizedWord]
}

nonisolated enum ScreenTextRecognizer {
    /// Retina captures are ~2900px wide. OCR quality plateaus around this width and
    /// runtime roughly halves, so wider images are downscaled before recognition.
    static let maximumOCRImageWidth = 2600

    /// Vision loads its text models lazily; the first request can take several
    /// seconds. Run this once at launch (off the main actor) so the first hotkey is fast.
    static func warmUp() {
        guard let context = CGContext(data: nil, width: 96, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 32))
        guard let blankImage = context.makeImage() else { return }
        _ = try? recognizeText(in: blankImage)
    }

    /// Synchronous and CPU-heavy: call from a detached task, never on the main actor.
    static func recognizeText(
        in image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        maximumWidth: Int = maximumOCRImageWidth
    ) throws -> [RecognizedTextLine] {
        let ocrScale = min(1.0, CGFloat(maximumWidth) / CGFloat(max(image.width, 1)))
        let ocrImage: CGImage
        if ocrScale < 1.0,
           let scaled = NativeScreenCaptureUtility.resize(image, toWidth: Int(CGFloat(image.width) * ocrScale), height: Int(CGFloat(image.height) * ocrScale)) {
            ocrImage = scaled
        } else {
            ocrImage = image
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        // Spreadsheets are full of numbers and codes; language correction would
        // "fix" 7590-VHVEG into words.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.004

        let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
        try handler.perform([request])

        let captureWidth = CGFloat(image.width)
        let captureHeight = CGFloat(image.height)

        // Vision's per-word boxes are padded to roughly the line height, so a real
        // 16px gap between two spreadsheet cells can shrink to 3px. The grayscale
        // bitmap lets us re-split each line at the true ink gaps instead.
        let grayscaleBitmap = GrayscaleBitmap(image: ocrImage)

        var lines: [RecognizedTextLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let lineText = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty else { continue }

            let lineBox = convertNormalizedRect(observation.boundingBox, captureWidth: captureWidth, captureHeight: captureHeight)
            let visionWords = extractWords(from: candidate, lineBox: lineBox, captureWidth: captureWidth, captureHeight: captureHeight)
            let words: [RecognizedWord]
            if let grayscaleBitmap {
                words = InkSegmenter.refineWords(
                    visionWords,
                    lineBoxInCapturePixels: lineBox,
                    bitmap: grayscaleBitmap,
                    ocrScale: ocrScale,
                    confidence: candidate.confidence
                )
            } else {
                words = visionWords
            }

            lines.append(RecognizedTextLine(
                text: lineText,
                boundingBoxInCapturePixels: lineBox,
                confidence: candidate.confidence,
                words: words
            ))
        }

        // Reading order: top to bottom, then left to right.
        return lines.sorted { first, second in
            if abs(first.boundingBoxInCapturePixels.midY - second.boundingBoxInCapturePixels.midY) > first.boundingBoxInCapturePixels.height * 0.5 {
                return first.boundingBoxInCapturePixels.midY < second.boundingBoxInCapturePixels.midY
            }
            return first.boundingBoxInCapturePixels.minX < second.boundingBoxInCapturePixels.minX
        }
    }

    /// Vision reports boxes normalized with a bottom-left origin. The OCR image is a
    /// uniform downscale of the capture, so multiplying by the *capture* size maps
    /// straight back to capture pixels with a top-left origin.
    private static func convertNormalizedRect(_ normalizedRect: CGRect, captureWidth: CGFloat, captureHeight: CGFloat) -> CGRect {
        CGRect(
            x: normalizedRect.minX * captureWidth,
            y: (1.0 - normalizedRect.maxY) * captureHeight,
            width: normalizedRect.width * captureWidth,
            height: normalizedRect.height * captureHeight
        )
    }

    private static func extractWords(
        from candidate: VNRecognizedText,
        lineBox: CGRect,
        captureWidth: CGFloat,
        captureHeight: CGFloat
    ) -> [RecognizedWord] {
        let fullText = candidate.string
        var words: [RecognizedWord] = []
        var searchStart = fullText.startIndex

        while searchStart < fullText.endIndex {
            // Skip whitespace
            while searchStart < fullText.endIndex, fullText[searchStart].isWhitespace {
                searchStart = fullText.index(after: searchStart)
            }
            guard searchStart < fullText.endIndex else { break }

            var wordEnd = searchStart
            while wordEnd < fullText.endIndex, !fullText[wordEnd].isWhitespace {
                wordEnd = fullText.index(after: wordEnd)
            }

            let wordRange = searchStart..<wordEnd
            let wordText = String(fullText[wordRange])
            let wordBox: CGRect
            if let rectangleObservation = try? candidate.boundingBox(for: wordRange) {
                wordBox = convertNormalizedRect(rectangleObservation.boundingBox, captureWidth: captureWidth, captureHeight: captureHeight)
            } else {
                wordBox = lineBox
            }
            words.append(RecognizedWord(text: wordText, boundingBoxInCapturePixels: wordBox, confidence: candidate.confidence))
            searchStart = wordEnd
        }

        if words.isEmpty {
            words.append(RecognizedWord(text: fullText, boundingBoxInCapturePixels: lineBox, confidence: candidate.confidence))
        }
        return words
    }
}

/// 8-bit luminance copy of the OCR image, used for ink-gap segmentation.
nonisolated struct GrayscaleBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Row 0 is the top of the image (CGContext draws flipped relative to memory
    /// order, but we only compare columns within one band, so orientation is irrelevant).
    @inline(__always) func luminance(x: Int, y: Int) -> Int {
        Int(pixels[y * width + x])
    }
}

/// Splits an OCR line into cells by scanning the bitmap for vertical whitespace
/// gaps wider than a space character but narrower than nothing: the gap between
/// two spreadsheet cells is padding + gridline, always wider than a space.
nonisolated enum InkSegmenter {
    /// Luminance difference from the band's background that counts as ink.
    /// Light gridlines (~30-45) stay below it; text and selection borders exceed it.
    private static let inkContrastThreshold = 64
    /// Gap (as a fraction of line height) that separates two cells. A space in
    /// 10pt Arial is ~0.27 × line height; cell padding is ≥ 0.5 × line height.
    private static let cellGapFractionOfHeight: CGFloat = 0.36

    static func refineWords(
        _ visionWords: [RecognizedWord],
        lineBoxInCapturePixels lineBox: CGRect,
        bitmap: GrayscaleBitmap,
        ocrScale: CGFloat,
        confidence: Float
    ) -> [RecognizedWord] {
        // The bitmap is the OCR image (capture × ocrScale), stored top-down.
        let bandMinX = max(0, Int((lineBox.minX * ocrScale).rounded(.down)) - 2)
        let bandMaxX = min(bitmap.width - 1, Int((lineBox.maxX * ocrScale).rounded(.up)) + 2)
        let bandMinY = max(0, Int((lineBox.minY * ocrScale).rounded(.down)))
        let bandMaxY = min(bitmap.height - 1, Int((lineBox.maxY * ocrScale).rounded(.up)))
        guard bandMaxX - bandMinX >= 4, bandMaxY - bandMinY >= 3 else { return visionWords }

        // Background = median luminance of the band (works for light and dark themes
        // and for alternating row shading, since it is computed per line).
        var histogram = [Int](repeating: 0, count: 256)
        for y in bandMinY...bandMaxY {
            for x in bandMinX...bandMaxX {
                histogram[bitmap.luminance(x: x, y: y)] += 1
            }
        }
        let totalPixels = (bandMaxX - bandMinX + 1) * (bandMaxY - bandMinY + 1)
        var cumulative = 0
        var backgroundLuminance = 255
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative * 2 >= totalPixels { backgroundLuminance = value; break }
        }

        // A column is inked when enough rows differ from the background. A 1-2px
        // horizontal rule (chart axis, underline, dark gridline) crossing the band
        // must not count, or every column would look inked and no gap would survive.
        let bandHeight = bandMaxY - bandMinY + 1
        let minimumInkRowsPerColumn = max(3, bandHeight / 5)
        var isColumnInked = [Bool](repeating: false, count: bandMaxX - bandMinX + 1)
        for x in bandMinX...bandMaxX {
            var inkRows = 0
            for y in bandMinY...bandMaxY where abs(bitmap.luminance(x: x, y: y) - backgroundLuminance) > inkContrastThreshold {
                inkRows += 1
                if inkRows >= minimumInkRowsPerColumn { break }
            }
            isColumnInked[x - bandMinX] = inkRows >= minimumInkRowsPerColumn
        }

        // Runs of ink, merging runs separated by gaps narrower than a cell gap.
        let minimumCellGap = max(3, Int((CGFloat(bandHeight) * cellGapFractionOfHeight).rounded()))
        var segments: [(start: Int, end: Int)] = []
        var runStart: Int?
        for (offset, isInked) in isColumnInked.enumerated() {
            if isInked {
                if runStart == nil { runStart = offset }
            } else if let start = runStart {
                appendOrMerge(start: start, end: offset - 1, minimumGap: minimumCellGap, into: &segments)
                runStart = nil
            }
        }
        if let start = runStart {
            appendOrMerge(start: start, end: isColumnInked.count - 1, minimumGap: minimumCellGap, into: &segments)
        }
        // Keep even 2px-wide segments: a "1" or "l" at 10pt is that thin.
        segments = segments.filter { $0.end - $0.start >= 1 }
        guard segments.count >= 1 else { return visionWords }

        // Assign Vision words to segments by centre; words sharing a segment are one cell.
        var textsPerSegment = [[String]](repeating: [], count: segments.count)
        for word in visionWords {
            let centerX = Int(word.boundingBoxInCapturePixels.midX * ocrScale) - bandMinX
            let segmentIndex = segments.firstIndex { centerX >= $0.start && centerX <= $0.end }
                ?? segments.enumerated().min { first, second in
                    distance(centerX, to: first.element) < distance(centerX, to: second.element)
                }!.offset
            textsPerSegment[segmentIndex].append(word.text)
        }

        var refinedWords: [RecognizedWord] = []
        for (index, segment) in segments.enumerated() where !textsPerSegment[index].isEmpty {
            let segmentMinX = CGFloat(bandMinX + segment.start) / ocrScale
            let segmentMaxX = CGFloat(bandMinX + segment.end + 1) / ocrScale
            refinedWords.append(RecognizedWord(
                text: textsPerSegment[index].joined(separator: " "),
                boundingBoxInCapturePixels: CGRect(x: segmentMinX, y: lineBox.minY, width: segmentMaxX - segmentMinX, height: lineBox.height),
                confidence: confidence
            ))
        }
        return refinedWords.isEmpty ? visionWords : refinedWords
    }

    private static func appendOrMerge(start: Int, end: Int, minimumGap: Int, into segments: inout [(start: Int, end: Int)]) {
        if let last = segments.last, start - last.end - 1 < minimumGap {
            segments[segments.count - 1] = (last.start, end)
        } else {
            segments.append((start, end))
        }
    }

    private static func distance(_ x: Int, to segment: (start: Int, end: Int)) -> Int {
        if x < segment.start { return segment.start - x }
        if x > segment.end { return x - segment.end }
        return 0
    }
}

nonisolated enum ScreenElementDetector {
    /// Turns OCR lines into numbered Set-of-Mark elements. Capped so the prompt
    /// stays small; lines are kept in reading order so IDs are predictable.
    static func makeElements(from lines: [RecognizedTextLine], maximumCount: Int = 160) -> [ScreenElement] {
        var elements: [ScreenElement] = []
        for line in lines.prefix(maximumCount) {
            elements.append(ScreenElement(
                id: elements.count + 1,
                kind: "text",
                text: line.text,
                boundingBoxInCapturePixels: line.boundingBoxInCapturePixels,
                confidence: line.confidence
            ))
        }
        return elements
    }
}
