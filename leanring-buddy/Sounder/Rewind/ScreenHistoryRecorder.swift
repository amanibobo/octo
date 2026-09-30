//
//  ScreenHistoryRecorder.swift
//  leanring-buddy
//
//  Screen rewind. Keeps a rolling, in-memory buffer of low-res frames of the
//  display under the cursor (about 1 fps, only when something changed) with
//  on-device OCR text per frame, so "what did that error say five minutes ago?"
//  can scrub back and highlight it. Nothing is written to disk and nothing
//  leaves the Mac; the buffer is dropped when the app quits.
//

import AppKit
import Combine
import Foundation
import NaturalLanguage
import Vision

/// One remembered frame. Boxes are in thumbnail pixels.
struct ScreenHistoryFrame: Identifiable {
    let id: UUID
    let capturedAt: Date
    /// The last tick at which the screen still looked like this frame.
    var lastSeenAt: Date
    let thumbnailJPEG: Data
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let lines: [RecognizedTextLine]

    var text: String { lines.map(\.text).joined(separator: "\n") }

    func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(capturedAt) }

    static func describeAge(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 5 { return "just now" }
        if total < 60 { return "\(total)s ago" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m ago" : "\(minutes)m \(remainder)s ago" }
        return "\(minutes / 60)h \(minutes % 60)m ago"
    }
}

struct ScreenHistoryMatch {
    let frame: ScreenHistoryFrame
    /// Indices into `frame.lines` that matched the question.
    let matchedLineIndices: [Int]
    let score: Double
}

@MainActor
final class ScreenHistoryRecorder: ObservableObject {
    @Published private(set) var frames: [ScreenHistoryFrame] = []
    @Published private(set) var isEnabled = false

    /// Set by the owner while an interaction is capturing so the two never contend.
    var isPaused = false

    private static let tickInterval: TimeInterval = 1.0
    private static let retentionSeconds: TimeInterval = 15 * 60
    private static let maximumFrames = 600
    private static let thumbnailWidth = 800
    private static let ocrWidth = 1400
    /// Mean absolute luminance difference (0–255) below which a tick is "nothing changed".
    private static let changeThreshold = 4.0

    private var timer: Timer?
    private var isCapturing = false
    private var lastSignature: [UInt8]?
    private var consecutiveFailures = 0
    private var backOffUntil = Date.distantPast
    private lazy var sentenceEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.tick() }
            }
            print("⏪ screen rewind on (15 min, in memory)")
        } else {
            timer?.invalidate()
            timer = nil
            frames = []
            lastSignature = nil
            print("⏪ screen rewind off; buffer dropped")
        }
    }

    var oldestFrameAge: TimeInterval? {
        frames.first.map { $0.age() }
    }

    // MARK: - Capture

    private func tick() async {
        guard isEnabled, !isPaused, !isCapturing, Date() >= backOffUntil else { return }
        isCapturing = true
        defer { isCapturing = false }

        let capture: SounderScreenCapture
        do {
            capture = try await NativeScreenCaptureUtility.captureDisplayUnderCursor()
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                backOffUntil = Date().addingTimeInterval(30)
                consecutiveFailures = 0
            }
            return
        }

        let now = Date()
        let cgImage = capture.cgImage
        let signature = await Task.detached(priority: .utility) { Self.signature(of: cgImage) }.value
        if let lastSignature, Self.meanAbsoluteDifference(signature, lastSignature) < Self.changeThreshold {
            // Same screen: extend the previous frame instead of storing a copy.
            if !frames.isEmpty { frames[frames.count - 1].lastSeenAt = now }
            pruneOldFrames(now: now)
            return
        }
        self.lastSignature = signature

        // OCR at a modest width with the fast recognizer: enough to find an error
        // message later, cheap enough to run every second something changes.
        let thumbnailWidth = Self.thumbnailWidth
        let ocrWidth = Self.ocrWidth
        let result = await Task.detached(priority: .utility) { () -> (DownscaledJPEG, [RecognizedTextLine])? in
            guard let thumbnail = NativeScreenCaptureUtility.makeDownscaledJPEG(from: cgImage, maximumWidth: thumbnailWidth, compressionQuality: 0.6) else { return nil }
            let lines = (try? ScreenTextRecognizer.recognizeText(in: cgImage, recognitionLevel: .fast, maximumWidth: ocrWidth)) ?? []
            let scale = CGFloat(thumbnail.widthInPixels) / CGFloat(max(cgImage.width, 1))
            let scaledLines = lines.map { line in
                RecognizedTextLine(
                    text: line.text,
                    boundingBoxInCapturePixels: CGRect(x: line.boundingBoxInCapturePixels.minX * scale, y: line.boundingBoxInCapturePixels.minY * scale,
                                                       width: line.boundingBoxInCapturePixels.width * scale, height: line.boundingBoxInCapturePixels.height * scale),
                    confidence: line.confidence,
                    words: []
                )
            }
            return (thumbnail, scaledLines)
        }.value
        guard let (thumbnail, lines) = result else { return }

        frames.append(ScreenHistoryFrame(id: UUID(), capturedAt: now, lastSeenAt: now, thumbnailJPEG: thumbnail.data,
                                         thumbnailWidth: thumbnail.widthInPixels, thumbnailHeight: thumbnail.heightInPixels, lines: lines))
        pruneOldFrames(now: now)
    }

    private func pruneOldFrames(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        frames.removeAll { $0.lastSeenAt < cutoff }
        if frames.count > Self.maximumFrames {
            frames.removeFirst(frames.count - Self.maximumFrames)
        }
    }

    /// 32×18 grayscale fingerprint for cheap change detection.
    nonisolated static func signature(of image: CGImage) -> [UInt8] {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// Share of grid cells that changed clearly. A small window such as Spotlight
    /// moves only a few cells, which the screen-wide mean would miss.
    nonisolated static func changedCellFraction(_ a: [UInt8], _ b: [UInt8], threshold: Int = 16) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in 0..<a.count where abs(Int(a[index]) - Int(b[index])) >= threshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    nonisolated static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for index in 0..<a.count { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }

    // MARK: - Search

    /// Finds the frame (and lines) that best answer a question about the past.
    /// `targetAge` narrows the search around "five minutes ago"; nil means any time.
    func search(query: String, targetAge: TimeInterval?) -> ScreenHistoryMatch? {
        guard !frames.isEmpty else { return nil }
        let now = Date()
        let keywords = Self.keywords(in: query)

        // Frames closest to the requested time score higher; without a time, recent
        // frames edge out older ones so "that error" finds the latest occurrence.
        func timeWeight(for frame: ScreenHistoryFrame) -> Double {
            let age = frame.age(now: now)
            if let targetAge {
                let tolerance = max(45.0, targetAge * 0.5)
                let distance = abs(age - targetAge)
                return max(0.05, 1.0 - distance / (tolerance * 2))
            }
            return 0.7 + 0.3 * max(0, 1 - age / Self.retentionSeconds)
        }

        var best: ScreenHistoryMatch?
        for frame in frames {
            let weight = timeWeight(for: frame)
            if keywords.isEmpty {
                let score = weight
                if score > (best?.score ?? 0) { best = ScreenHistoryMatch(frame: frame, matchedLineIndices: [], score: score) }
                continue
            }
            var frameScore = 0.0
            var matchedIndices: [Int] = []
            for (index, line) in frame.lines.enumerated() {
                let lineScore = Self.keywordScore(keywords, in: line.text)
                if lineScore > 0 {
                    matchedIndices.append(index)
                    frameScore = max(frameScore, lineScore)
                }
            }
            guard frameScore > 0 else { continue }
            let score = frameScore * (0.5 + 0.5 * weight)
            if score > (best?.score ?? 0) {
                best = ScreenHistoryMatch(frame: frame, matchedLineIndices: Array(matchedIndices.prefix(6)), score: score)
            }
        }

        // No keyword hit anywhere: fall back to sentence similarity over the frames
        // nearest the requested time, so "the crash" can still find "Exception…".
        if best == nil || (best?.matchedLineIndices.isEmpty ?? true), !keywords.isEmpty, let embedding = sentenceEmbedding {
            let candidates = frames.sorted { timeWeight(for: $0) > timeWeight(for: $1) }.prefix(12)
            var semanticBest: ScreenHistoryMatch?
            for frame in candidates {
                for (index, line) in frame.lines.enumerated() where line.text.count >= 12 {
                    let distance = embedding.distance(between: query, and: line.text)
                    let score = max(0, 1.0 - distance) * (0.5 + 0.5 * timeWeight(for: frame))
                    if score > (semanticBest?.score ?? 0.35) {
                        semanticBest = ScreenHistoryMatch(frame: frame, matchedLineIndices: [index], score: score)
                    }
                }
            }
            if let semanticBest { best = semanticBest }
        }
        return best
    }

    /// Lines in a frame that contain any of the question's keywords (for scrubbing).
    func lineIndicesMatching(query: String, in frame: ScreenHistoryFrame) -> [Int] {
        let keywords = Self.keywords(in: query)
        guard !keywords.isEmpty else { return [] }
        return frame.lines.enumerated().compactMap { Self.keywordScore(keywords, in: $1.text) > 0 ? $0 : nil }
    }

    private static let stopWords: Set<String> = [
        "what", "did", "that", "the", "a", "an", "say", "said", "says", "was", "were", "is", "it", "on", "my", "screen", "show", "me",
        "again", "ago", "earlier", "before", "back", "go", "rewind", "scroll", "to", "of", "in", "there", "this", "those", "these",
        "i", "we", "you", "and", "or", "for", "with", "at", "from", "about", "then", "just", "like", "one", "two", "three", "four", "five",
        "ten", "fifteen", "twenty", "thirty", "few", "couple", "minute", "minutes", "second", "seconds", "hour", "hours", "half", "while",
        "please", "can", "could", "tell", "read", "look", "find", "pull", "up", "bring", "page", "thing", "stuff", "message", "text",
    ]

    nonisolated static func keywords(in query: String) -> [String] {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    nonisolated static func keywordScore(_ keywords: [String], in text: String) -> Double {
        guard !keywords.isEmpty else { return 0 }
        let lowered = text.lowercased()
        var hits = 0.0
        for keyword in keywords {
            if lowered.contains(keyword) {
                hits += 1
            } else if keyword.count >= 5, lowered.contains(String(keyword.prefix(keyword.count - 2))) {
                hits += 0.5 // "crashed" vs "crash", "errors" vs "error"
            }
        }
        return hits / Double(keywords.count)
    }
}
