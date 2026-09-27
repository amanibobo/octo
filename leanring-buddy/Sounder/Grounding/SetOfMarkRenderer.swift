//
//  SetOfMarkRenderer.swift
//  leanring-buddy
//
//  Draws numbered tags on a downscaled copy of the capture so the vision model
//  can refer to elements by ID instead of guessing pixel coordinates.
//

import AppKit
import CoreGraphics

enum SetOfMarkRenderer {

    static func renderMarkedScreenshot(
        capture: CGImage,
        elements: [ScreenElement],
        maximumWidth: Int = 1568
    ) -> DownscaledJPEG? {
        let scale = min(1.0, CGFloat(maximumWidth) / CGFloat(max(capture.width, 1)))
        let outputWidth = max(1, Int(CGFloat(capture.width) * scale))
        let outputHeight = max(1, Int(CGFloat(capture.height) * scale))

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputWidth,
            pixelsHigh: outputHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }
        bitmapRep.size = NSSize(width: outputWidth, height: outputHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let cgContext = graphicsContext.cgContext

        // Flip so the coordinate system is top-left like the capture pixels.
        cgContext.translateBy(x: 0, y: CGFloat(outputHeight))
        cgContext.scaleBy(x: 1, y: -1)

        cgContext.interpolationQuality = .high
        cgContext.draw(capture, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        let tagFont = NSFont.boldSystemFont(ofSize: 11)
        let tagAttributes: [NSAttributedString.Key: Any] = [
            .font: tagFont,
            .foregroundColor: NSColor.white
        ]

        for element in elements {
            let scaledBox = CGRect(
                x: element.boundingBoxInCapturePixels.minX * scale,
                y: element.boundingBoxInCapturePixels.minY * scale,
                width: element.boundingBoxInCapturePixels.width * scale,
                height: element.boundingBoxInCapturePixels.height * scale
            )

            cgContext.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
            cgContext.setLineWidth(1)
            cgContext.stroke(scaledBox.insetBy(dx: -1, dy: -1))

            let tagText = "\(element.id)" as NSString
            let tagSize = tagText.size(withAttributes: tagAttributes)
            let tagRect = CGRect(
                x: max(0, scaledBox.minX - tagSize.width - 6),
                y: max(0, scaledBox.minY - 1),
                width: tagSize.width + 5,
                height: tagSize.height + 1
            )
            cgContext.setFillColor(NSColor.systemRed.cgColor)
            cgContext.fill(tagRect)

            // Text drawing uses a non-flipped context; flip back temporarily.
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: CGFloat(outputHeight))
            cgContext.scaleBy(x: 1, y: -1)
            let textOrigin = CGPoint(x: tagRect.minX + 2.5, y: CGFloat(outputHeight) - tagRect.maxY)
            tagText.draw(at: textOrigin, withAttributes: tagAttributes)
            cgContext.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return DownscaledJPEG(data: jpegData, widthInPixels: outputWidth, heightInPixels: outputHeight)
    }
}
