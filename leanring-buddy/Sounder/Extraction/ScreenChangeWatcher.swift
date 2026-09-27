//
//  ScreenChangeWatcher.swift
//  leanring-buddy
//
//  After a Data-mode result is drawn, watches the table region for a short
//  window. When the pixels change and then settle (the user edited a cell),
//  it fires once so the pipeline can re-extract and redraw.
//

import CoreGraphics
import Foundation

@MainActor
final class ScreenChangeWatcher {
    private var pollingTask: Task<Void, Never>?

    private static let thumbnailSide = 24
    private static let pollIntervalNanoseconds: UInt64 = 700_000_000
    private static let changeThreshold = 0.02
    private static let settledThreshold = 0.004

    var isWatching: Bool { pollingTask != nil }

    func start(
        regionInCapturePixels: CGRect,
        geometry: CaptureGeometry,
        durationSeconds: TimeInterval = 12,
        onStableChange: @escaping @MainActor () -> Void
    ) {
        stop()

        let regionInDisplayPoints = geometry.overlayRect(fromCapturePixelRect: regionInCapturePixels)
        let displayFrame = geometry.displayFrame
        let deadline = Date().addingTimeInterval(durationSeconds)

        pollingTask = Task { [weak self] in
            guard let baseline = await Self.sampleSignature(displayFrame: displayFrame, region: regionInDisplayPoints) else {
                self?.pollingTask = nil
                return
            }
            var previousSignature = baseline
            var hasSeenChange = false

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard !Task.isCancelled,
                      let currentSignature = await Self.sampleSignature(displayFrame: displayFrame, region: regionInDisplayPoints) else {
                    continue
                }
                let differenceFromBaseline = Self.meanAbsoluteDifference(currentSignature, baseline)
                let differenceFromPrevious = Self.meanAbsoluteDifference(currentSignature, previousSignature)
                previousSignature = currentSignature

                if differenceFromBaseline > Self.changeThreshold {
                    hasSeenChange = true
                }
                // Fire only once typing has stopped: the region changed vs. the
                // baseline but is now identical to the previous sample.
                if hasSeenChange, differenceFromPrevious < Self.settledThreshold {
                    self?.pollingTask = nil
                    onStableChange()
                    return
                }
            }
            self?.pollingTask = nil
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Signature

    private static func sampleSignature(displayFrame: CGRect, region: CGRect) async -> [UInt8]? {
        guard let thumbnail = try? await NativeScreenCaptureUtility.captureRegionThumbnail(
            displayFrame: displayFrame,
            regionInDisplayPoints: region,
            outputWidth: thumbnailSide,
            outputHeight: thumbnailSide
        ) else {
            return nil
        }
        return grayscaleBytes(thumbnail)
    }

    private static func grayscaleBytes(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: thumbnailSide * thumbnailSide)
        guard let context = CGContext(
            data: &pixels,
            width: thumbnailSide,
            height: thumbnailSide,
            bitsPerComponent: 8,
            bytesPerRow: thumbnailSide,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSide, height: thumbnailSide))
        return pixels
    }

    private static func meanAbsoluteDifference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total = 0
        for index in first.indices {
            total += abs(Int(first[index]) - Int(second[index]))
        }
        return Double(total) / Double(first.count) / 255.0
    }
}
