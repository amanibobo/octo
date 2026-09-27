//
//  DrawingLayerView.swift
//  leanring-buddy
//
//  Renders drawing primitives on the full-screen overlay. Each screen has its
//  own overlay window; the layer only draws when the captured display matches
//  its screen. Coordinates: capture pixels → overlay points via CaptureGeometry.
//

import Combine
import SwiftUI

@MainActor
final class DrawingLayerModel: ObservableObject {
    @Published private(set) var primitives: [DrawingPrimitive] = []
    @Published private(set) var geometry: CaptureGeometry?
    @Published private(set) var layerOpacity: Double = 0

    private var autoClearTask: Task<Void, Never>?

    var hasDrawings: Bool { !primitives.isEmpty }

    /// Shows a new set of drawings with a 120ms fade-in, replacing any existing ones.
    func show(_ newPrimitives: [DrawingPrimitive], geometry newGeometry: CaptureGeometry, autoClearAfterSeconds: TimeInterval? = nil) {
        autoClearTask?.cancel()
        geometry = newGeometry
        primitives = newPrimitives
        withAnimation(.easeIn(duration: 0.12)) {
            layerOpacity = 1
        }
        if let autoClearAfterSeconds {
            autoClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoClearAfterSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        }
    }

    /// Fades out, then removes the drawings.
    func clear() {
        autoClearTask?.cancel()
        guard !primitives.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            layerOpacity = 0
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, self.layerOpacity == 0 else { return }
            self.primitives = []
        }
    }

    /// Removes drawings with no animation. Called right before a capture so the
    /// overlay can never feed back into OCR (belt and braces: capture already
    /// excludes our windows).
    func clearImmediately() {
        autoClearTask?.cancel()
        primitives = []
        layerOpacity = 0
    }
}

struct DrawingLayerView: View {
    @ObservedObject var model: DrawingLayerModel
    let screenFrame: CGRect

    var body: some View {
        if let geometry = model.geometry, geometry.displayFrame == screenFrame {
            ZStack(alignment: .topLeading) {
                ForEach(model.primitives) { primitive in
                    primitiveView(primitive, geometry: geometry)
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
            .opacity(model.layerOpacity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func primitiveView(_ primitive: DrawingPrimitive, geometry: CaptureGeometry) -> some View {
        switch primitive {
        case .circle(_, let rectInCapturePixels, let tagNumber, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            Path { path in
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
            }
            .stroke(swiftUIColor(color), lineWidth: 2)
            .shadow(color: swiftUIColor(color).opacity(0.45), radius: 4)
            if let tagNumber {
                Text("\(tagNumber)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(swiftUIColor(color)))
                    .position(x: rect.minX - 11, y: rect.midY)
            }

        case .bar(_, let rectInCapturePixels, let isTopWeight):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            Path { path in
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
            }
            .fill(isTopWeight ? DS.Colors.blue400 : DS.Colors.overlayCursorBlue.opacity(0.85))
            .shadow(color: isTopWeight ? DS.Colors.blue400.opacity(0.9) : .clear, radius: isTopWeight ? 6 : 0)

        case .polyline(_, let pointsInCapturePixels, let clipRectInCapturePixels):
            let points = pointsInCapturePixels.map { geometry.overlayPoint(fromCapturePixel: $0) }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .shadow(color: Color.orange.opacity(0.5), radius: 3)
            .clipShape(clipShape(clipRectInCapturePixels, geometry: geometry))

        case .band(_, let upperPointsInCapturePixels, let lowerPointsInCapturePixels, let clipRectInCapturePixels):
            let upperPoints = upperPointsInCapturePixels.map { geometry.overlayPoint(fromCapturePixel: $0) }
            let lowerPoints = lowerPointsInCapturePixels.map { geometry.overlayPoint(fromCapturePixel: $0) }
            Path { path in
                guard let firstUpper = upperPoints.first else { return }
                path.move(to: firstUpper)
                for point in upperPoints.dropFirst() { path.addLine(to: point) }
                for point in lowerPoints.reversed() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .fill(Color.orange.opacity(0.18))
            .clipShape(clipShape(clipRectInCapturePixels, geometry: geometry))

        case .highlight(_, let rectInCapturePixels, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            Path { path in
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
            }
            .fill(swiftUIColor(color).opacity(color == .yellow ? 0.25 : 0.18))
            .overlay(
                Path { path in
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
                }
                .stroke(swiftUIColor(color).opacity(0.7), lineWidth: 1.5)
            )

        case .badge(_, let anchorInCapturePixels, let text):
            let anchor = geometry.overlayPoint(fromCapturePixel: anchorInCapturePixels)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.75)))
                .fixedSize()
                .position(x: anchor.x + 18, y: anchor.y)
        }
    }

    /// Clips curves to the plot area; an unclipped rect covering the screen otherwise.
    private func clipShape(_ clipRectInCapturePixels: CGRect?, geometry: CaptureGeometry) -> some Shape {
        let clipRect = clipRectInCapturePixels.map { geometry.overlayRect(fromCapturePixelRect: $0) }
            ?? CGRect(origin: .zero, size: CGSize(width: screenFrame.width, height: screenFrame.height))
        return Rectangle().path(in: clipRect)
    }

    private func swiftUIColor(_ color: DrawingColor) -> Color {
        switch color {
        case .red: return Color(red: 0.93, green: 0.27, blue: 0.27)
        case .blue: return DS.Colors.overlayCursorBlue
        case .yellow: return Color(red: 1.0, green: 0.85, blue: 0.2)
        case .orange: return .orange
        }
    }
}
