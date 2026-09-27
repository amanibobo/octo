//
//  NativeScreenCaptureUtility.swift
//  leanring-buddy
//
//  Full-resolution capture of the display under the cursor. OCR needs native
//  pixels (a 1280px downscale loses 9pt spreadsheet text), and the drawing
//  layer needs the exact pixel→point ratio, so this captures at backing scale
//  and records the geometry alongside the image.
//

import AppKit
import ScreenCaptureKit

struct SounderScreenCapture {
    let cgImage: CGImage
    let geometry: CaptureGeometry
    let backingScaleFactor: CGFloat

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }
}

struct DownscaledJPEG {
    let data: Data
    let widthInPixels: Int
    let heightInPixels: Int
}

@MainActor
enum NativeScreenCaptureUtility {

    /// Captures the display containing the mouse at native resolution, excluding
    /// this app's own windows (the overlay drawings must never feed back into OCR).
    static func captureDisplayUnderCursor() async throws -> SounderScreenCapture {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !shareableContent.displays.isEmpty else {
            throw NSError(domain: "NativeScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let targetDisplayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        let targetDisplay = shareableContent.displays.first { $0.displayID == targetDisplayID }
            ?? shareableContent.displays[0]

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let contentFilter = SCContentFilter(display: targetDisplay, excludingWindows: ownAppWindows)

        let backingScaleFactor = targetScreen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.width = Int(targetScreen.frame.width * backingScaleFactor)
        configuration.height = Int(targetScreen.frame.height * backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)

        let geometry = CaptureGeometry(
            captureWidthInPixels: cgImage.width,
            captureHeightInPixels: cgImage.height,
            displayFrame: targetScreen.frame
        )
        return SounderScreenCapture(cgImage: cgImage, geometry: geometry, backingScaleFactor: backingScaleFactor)
    }

    /// Captures only a region of a display (in that display's local points, top-left
    /// origin) at a small output size. Used by the change watcher to cheaply detect
    /// edits to the table region after a result was drawn.
    static func captureRegionThumbnail(
        displayFrame: CGRect,
        regionInDisplayPoints: CGRect,
        outputWidth: Int,
        outputHeight: Int
    ) async throws -> CGImage {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targetScreen = NSScreen.screens.first { $0.frame == displayFrame }
        let targetDisplayID = targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let targetDisplay = shareableContent.displays.first(where: { $0.displayID == targetDisplayID }) ?? shareableContent.displays.first else {
            throw NSError(domain: "NativeScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Display disappeared"])
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = shareableContent.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let contentFilter = SCContentFilter(display: targetDisplay, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = regionInDisplayPoints
        configuration.width = max(outputWidth, 8)
        configuration.height = max(outputHeight, 8)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        return try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
    }

    /// Downscales a capture for the vision model (Fireworks resizes anyway; sending
    /// a 5.6MP Retina PNG would only add upload time).
    nonisolated static func makeDownscaledJPEG(from cgImage: CGImage, maximumWidth: Int = 1568, compressionQuality: CGFloat = 0.82) -> DownscaledJPEG? {
        let scale = min(1.0, CGFloat(maximumWidth) / CGFloat(max(cgImage.width, 1)))
        let outputWidth = max(1, Int(CGFloat(cgImage.width) * scale))
        let outputHeight = max(1, Int(CGFloat(cgImage.height) * scale))

        guard let scaledImage = resize(cgImage, toWidth: outputWidth, height: outputHeight) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: scaledImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) else {
            return nil
        }
        return DownscaledJPEG(data: jpegData, widthInPixels: outputWidth, heightInPixels: outputHeight)
    }

    nonisolated static func resize(_ cgImage: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
