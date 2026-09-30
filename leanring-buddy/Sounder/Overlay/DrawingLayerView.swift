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
    /// 0 → 1 while strokes "draw on"; shapes trim themselves to this value.
    @Published private(set) var drawProgress: CGFloat = 0

    private var autoClearTask: Task<Void, Never>?

    var hasDrawings: Bool { !primitives.isEmpty }

    /// Shows a new set of drawings with a 120ms fade-in, replacing any existing ones.
    func show(_ newPrimitives: [DrawingPrimitive], geometry newGeometry: CaptureGeometry, autoClearAfterSeconds: TimeInterval? = nil) {
        autoClearTask?.cancel()
        geometry = newGeometry
        primitives = newPrimitives
        drawProgress = 0
        withAnimation(.easeIn(duration: 0.12)) {
            layerOpacity = 1
        }
        // Marker-style draw-on: strokes appear over ~0.6s in stroke order.
        withAnimation(.easeInOut(duration: 0.65)) {
            drawProgress = 1
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
        case .circle(let id, let rectInCapturePixels, let tagNumber, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            RoughRectangleShape(seed: id)
                .trim(from: 0, to: model.drawProgress)
                .stroke(swiftUIColor(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
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
            .fill(isTopWeight ? DS.Colors.green400 : DS.Colors.overlayCursorBlue.opacity(0.85))
            .shadow(color: isTopWeight ? DS.Colors.green400.opacity(0.9) : .clear, radius: isTopWeight ? 6 : 0)

        case .polyline(_, let pointsInCapturePixels, let clipRectInCapturePixels):
            let points = pointsInCapturePixels.map { geometry.overlayPoint(fromCapturePixel: $0) }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .trim(from: 0, to: model.drawProgress)
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

        case .highlight(let id, let rectInCapturePixels, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            // Marker fill fades in while a wobbly outline draws around it.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(swiftUIColor(color).opacity((color == .yellow ? 0.25 : 0.16) * Double(model.drawProgress)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            RoughRectangleShape(seed: id, wobbleAmplitude: 1.8, cornerOvershoot: 3, passes: 1)
                .trim(from: 0, to: model.drawProgress)
                .stroke(swiftUIColor(color).opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

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

        case .link(_, let fromRectInCapturePixels, let toRectInCapturePixels, let color, let label):
            let fromRect = geometry.overlayRect(fromCapturePixelRect: fromRectInCapturePixels)
            let toRect = geometry.overlayRect(fromCapturePixelRect: toRectInCapturePixels)
            let start = CGPoint(x: fromRect.minX - 6, y: fromRect.midY)
            let end = CGPoint(x: toRect.minX - 6, y: toRect.midY)
            let bulge = max(28, abs(end.y - start.y) * 0.35)
            let control = CGPoint(x: min(start.x, end.x) - bulge, y: (start.y + end.y) / 2)
            let apex = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x, y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
            Path { path in
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }
            .trim(from: 0, to: model.drawProgress)
            .stroke(swiftUIColor(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .shadow(color: swiftUIColor(color).opacity(0.5), radius: 4)
            Path { path in
                path.addEllipse(in: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8))
                path.addEllipse(in: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8))
            }
            .fill(swiftUIColor(color))
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(swiftUIColor(color)))
                    .fixedSize()
                    .position(x: apex.x, y: apex.y)
            }

        case .arrow(let id, let fromRectInCapturePixels, let toRectInCapturePixels, _, let label, let color, let emphasis):
            let fromRect = geometry.overlayRect(fromCapturePixelRect: fromRectInCapturePixels)
            let toRect = geometry.overlayRect(fromCapturePixelRect: toRectInCapturePixels)
            let start = Self.edgePoint(of: fromRect.insetBy(dx: -6, dy: -4), toward: CGPoint(x: toRect.midX, y: toRect.midY))
            let end = Self.edgePoint(of: toRect.insetBy(dx: -8, dy: -6), toward: CGPoint(x: fromRect.midX, y: fromRect.midY))
            let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = max(1, hypot(delta.x, delta.y))
            // Bow the arrow a little to one side so a chain of hops reads as a path, not a line.
            let normal = CGPoint(x: -delta.y / length, y: delta.x / length)
            let bulge = min(60, length * 0.18)
            let control = CGPoint(x: (start.x + end.x) / 2 + normal.x * bulge, y: (start.y + end.y) / 2 + normal.y * bulge)
            let apex = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x, y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
            let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
            let tangentLength = max(1, hypot(tangent.x, tangent.y))
            let direction = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
            let arrowSize: CGFloat = emphasis == 2 ? 13 : 10
            let strokeOpacity = emphasis == 0 ? 0.45 : (emphasis == 2 ? 1.0 : 0.8)
            let lineWidth: CGFloat = emphasis == 2 ? 3.5 : 2.5
            RoughLineShape(seed: id, from: start, to: end)
                .trim(from: 0, to: model.drawProgress)
                .stroke(swiftUIColor(color).opacity(0.001), lineWidth: 0.1) // keeps the seed stable; real stroke below
            Path { path in
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }
            .trim(from: 0, to: model.drawProgress)
            .stroke(swiftUIColor(color).opacity(strokeOpacity), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .shadow(color: swiftUIColor(color).opacity(emphasis == 2 ? 0.7 : 0.35), radius: emphasis == 2 ? 6 : 3)
            if model.drawProgress > 0.95 {
                Path { path in
                    let tip = end
                    let base = CGPoint(x: tip.x - direction.x * arrowSize, y: tip.y - direction.y * arrowSize)
                    let side = CGPoint(x: -direction.y * arrowSize * 0.55, y: direction.x * arrowSize * 0.55)
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: base.x + side.x, y: base.y + side.y))
                    path.addLine(to: CGPoint(x: base.x - side.x, y: base.y - side.y))
                    path.closeSubpath()
                }
                .fill(swiftUIColor(color).opacity(strokeOpacity))
            }
            if let label, !label.isEmpty, model.drawProgress > 0.6 {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.8)).overlay(Capsule().stroke(swiftUIColor(color).opacity(0.8), lineWidth: 1)))
                    .fixedSize()
                    .position(x: apex.x, y: apex.y)
            }

        case .textPatch(_, let rectInCapturePixels, let text, let red, let green, let blue, let usesDarkText):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            let patch = rect.insetBy(dx: -3, dy: -2)
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: red, green: green, blue: blue))
                Text(text)
                    .font(.system(size: max(9, rect.height * 0.74), weight: .regular))
                    .foregroundColor(usesDarkText ? Color(white: 0.1) : Color(white: 0.97))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .padding(.horizontal, 2)
                    .frame(width: patch.width, height: patch.height, alignment: .leading)
            }
            .frame(width: patch.width, height: patch.height)
            .position(x: patch.midX, y: patch.midY)
            .opacity(Double(model.drawProgress))

        case .textBlock(_, let rectInCapturePixels, let segments, let lineHeightInCapturePixels, let red, let green, let blue, let usesDarkText):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            let patch = rect.insetBy(dx: -8, dy: -6)
            let fontSize = max(10, geometry.overlayRect(fromCapturePixelRect: CGRect(x: 0, y: 0, width: 1, height: lineHeightInCapturePixels)).height * 0.72)
            let textColor = usesDarkText ? Color(white: 0.1) : Color(white: 0.97)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: red, green: green, blue: blue))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.overlayCursorBlue.opacity(0.6), lineWidth: 1))
                Text(Self.attributedText(for: segments, fontSize: fontSize, textColor: textColor))
                    .lineSpacing(fontSize * 0.28)
                    .frame(width: patch.width - 16, alignment: .topLeading)
                    .padding(8)
            }
            .frame(width: patch.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .position(x: patch.midX, y: patch.minY + max(patch.height, 10) / 2)
            .opacity(Double(model.drawProgress))

        case .marginBar(_, let rectInCapturePixels, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swiftUIColor(color))
                .frame(width: 4, height: rect.height + 6)
                .position(x: rect.minX - 10, y: rect.midY)
                .opacity(Double(model.drawProgress))

        case .underline(let id, let rectInCapturePixels, let color):
            let rect = geometry.overlayRect(fromCapturePixelRect: rectInCapturePixels)
            RoughLineShape(seed: id, from: CGPoint(x: rect.minX - 3, y: rect.maxY + 2), to: CGPoint(x: rect.maxX + 3, y: rect.maxY + 2))
                .trim(from: 0, to: model.drawProgress)
                .stroke(swiftUIColor(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: swiftUIColor(color).opacity(0.6), radius: 3)

        case .footnoteDrawer(_, let lines):
            VStack(alignment: .leading, spacing: 4) {
                Text("References")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.82)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.8))
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .bottomTrailing)
            .padding(.trailing, 24)
            .padding(.bottom, 36)
        }
    }

    /// Clips curves to the plot area; an unclipped rect covering the screen otherwise.
    private func clipShape(_ clipRectInCapturePixels: CGRect?, geometry: CaptureGeometry) -> some Shape {
        let clipRect = clipRectInCapturePixels.map { geometry.overlayRect(fromCapturePixelRect: $0) }
            ?? CGRect(origin: .zero, size: CGSize(width: screenFrame.width, height: screenFrame.height))
        return Rectangle().path(in: clipRect)
    }

    /// Rewritten paragraph with the changed runs marked in green.
    private static func attributedText(for segments: [TextBlockSegment], fontSize: CGFloat, textColor: Color) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            piece.font = .system(size: fontSize, weight: segment.isChanged ? .semibold : .regular)
            piece.foregroundColor = textColor
            if segment.isChanged {
                piece.backgroundColor = DS.Colors.overlayCursorBlue.opacity(0.28)
                piece.underlineStyle = .single
            }
            result += piece
        }
        return result
    }

    /// Where a line from the rect's centre toward `target` leaves the rect.
    private static func edgePoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfWidth = rect.width / 2, halfHeight = rect.height / 2
        let scale = min(halfWidth / max(abs(dx), 0.001), halfHeight / max(abs(dy), 0.001))
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    private func swiftUIColor(_ color: DrawingColor) -> Color {
        switch color {
        case .red: return Color(red: 0.93, green: 0.27, blue: 0.27)
        case .blue: return DS.Colors.overlayCursorBlue
        case .yellow: return Color(red: 1.0, green: 0.85, blue: 0.2)
        case .orange: return .orange
        case .green: return DS.Colors.overlayCursorBlue
        }
    }
}
