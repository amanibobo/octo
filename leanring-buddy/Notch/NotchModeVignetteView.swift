//
//  NotchModeVignetteView.swift
//  leanring-buddy
//
//  A tiny animated "Octo in use" scene for each mode, drawn in SwiftUI so the
//  card stays self-contained (no GIFs, no screenshots of anyone's screen). A
//  miniature screen with faint text lines; the sprite does what the mode does:
//  General flies to a line and highlights it, Rx checks a med list and links two
//  rows, Agent clicks through three steps, Auto cycles through all three.
//

import SwiftUI

struct NotchModeVignetteView: View {
    let mode: SounderMode

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphicsContext, size in
                Self.draw(mode: mode, time: time, in: &graphicsContext, size: size)
            }
        }
        .frame(width: 148, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Drawing

    private static let green = Color(red: 0x22/255, green: 0xC5/255, blue: 0x5E/255)
    private static let red = Color(red: 0.96, green: 0.36, blue: 0.33)
    private static let yellow = Color(red: 0.98, green: 0.78, blue: 0.25)

    private static func draw(mode: SounderMode, time: TimeInterval, in context: inout GraphicsContext, size: CGSize) {
        // Auto cycles the three scenes so the card shows all of them.
        let scene: SounderMode
        let sceneTime: TimeInterval
        if mode == .automatic {
            let cycle = 5.0
            let slot = Int(time / cycle) % 3
            scene = [SounderMode.general, .clinical, .agent][slot]
            sceneTime = time.truncatingRemainder(dividingBy: cycle)
        } else {
            scene = mode
            sceneTime = time.truncatingRemainder(dividingBy: 5.0)
        }
        switch scene {
        case .general: drawGeneral(progress: sceneTime / 5.0, in: &context, size: size)
        case .clinical: drawClinical(progress: sceneTime / 5.0, in: &context, size: size)
        case .agent: drawAgent(progress: sceneTime / 5.0, in: &context, size: size)
        case .automatic: break
        }
    }

    /// Faint text lines like a document; returns the rects so scenes can target them.
    @discardableResult
    private static func drawLines(count: Int, in context: inout GraphicsContext, size: CGSize, startY: CGFloat = 16, gap: CGFloat = 13, widths: [CGFloat]? = nil) -> [CGRect] {
        var rects: [CGRect] = []
        for index in 0..<count {
            let width = widths.map { $0[index % $0.count] } ?? [0.72, 0.55, 0.64, 0.4, 0.6][index % 5]
            let rect = CGRect(x: 14, y: startY + CGFloat(index) * gap, width: (size.width - 28) * width, height: 5)
            context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(.white.opacity(0.14)))
            rects.append(rect)
        }
        return rects
    }

    private static func drawSprite(at center: CGPoint, in context: inout GraphicsContext, glow: Bool = true) {
        let body = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
        if glow {
            var glowContext = context
            glowContext.addFilter(.blur(radius: 5))
            glowContext.fill(Path(roundedRect: body.insetBy(dx: -2, dy: -2), cornerRadius: 6), with: .color(green.opacity(0.55)))
        }
        context.fill(Path(roundedRect: body, cornerRadius: 4), with: .color(green))
        for offsetX: CGFloat in [-3.2, 3.2] {
            context.fill(Path(ellipseIn: CGRect(x: center.x + offsetX - 1.9, y: center.y - 2.8, width: 3.8, height: 3.8)), with: .color(.white))
        }
    }

    private static func ease(_ value: Double) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return CGFloat(clamped < 0.5 ? 2 * clamped * clamped : 1 - pow(-2 * clamped + 2, 2) / 2)
    }

    // General: sprite flies from the corner to the third line and highlights it.
    private static func drawGeneral(progress: Double, in context: inout GraphicsContext, size: CGSize) {
        let lines = drawLines(count: 5, in: &context, size: size)
        let target = lines[2]
        let flight = ease((progress - 0.15) / 0.35)
        let start = CGPoint(x: size.width - 22, y: size.height - 18)
        let end = CGPoint(x: target.maxX + 14, y: target.midY)
        // Bezier arc like the real cursor flight.
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 30)
        let oneMinus = 1 - flight
        let position = CGPoint(x: oneMinus * oneMinus * start.x + 2 * oneMinus * flight * control.x + flight * flight * end.x,
                               y: oneMinus * oneMinus * start.y + 2 * oneMinus * flight * control.y + flight * flight * end.y)
        if progress > 0.5 {
            let reveal = ease((progress - 0.5) / 0.2)
            var highlight = target.insetBy(dx: -4, dy: -4)
            highlight.size.width *= reveal
            context.stroke(Path(roundedRect: highlight, cornerRadius: 4), with: .color(green), lineWidth: 1.5)
            context.fill(Path(roundedRect: highlight, cornerRadius: 4), with: .color(green.opacity(0.18)))
        }
        drawSprite(at: position, in: &context)
    }

    // Rx: a med list; two rows get linked in red and one dose underlined in yellow.
    private static func drawClinical(progress: Double, in context: inout GraphicsContext, size: CGSize) {
        let rows = drawLines(count: 5, in: &context, size: size, startY: 14, gap: 14, widths: [0.5, 0.42, 0.55, 0.38, 0.48])
        // dose column
        for row in rows {
            let dose = CGRect(x: size.width - 44, y: row.minY, width: 22, height: 5)
            context.fill(Path(roundedRect: dose, cornerRadius: 2.5), with: .color(.white.opacity(0.12)))
        }
        let scan = ease((progress - 0.1) / 0.4)
        if progress > 0.1, progress < 0.55 {
            let scanY = 10 + (size.height - 20) * scan
            context.fill(Path(CGRect(x: 8, y: scanY, width: size.width - 16, height: 1)), with: .color(green.opacity(0.6)))
        }
        if progress > 0.5 {
            let reveal = ease((progress - 0.5) / 0.25)
            let from = CGPoint(x: rows[0].maxX + 6, y: rows[0].midY)
            let to = CGPoint(x: rows[3].maxX + 6, y: rows[3].midY)
            var link = Path()
            link.move(to: from)
            link.addQuadCurve(to: CGPoint(x: from.x + (to.x - from.x) * reveal, y: from.y + (to.y - from.y) * reveal),
                              control: CGPoint(x: max(from.x, to.x) + 22, y: (from.y + to.y) / 2))
            context.stroke(link, with: .color(red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: from.x - 2.5, y: from.y - 2.5, width: 5, height: 5)), with: .color(red))
            if reveal >= 1 {
                context.fill(Path(ellipseIn: CGRect(x: to.x - 2.5, y: to.y - 2.5, width: 5, height: 5)), with: .color(red))
                let underline = CGRect(x: size.width - 44, y: rows[2].maxY + 2, width: 22 * ease((progress - 0.75) / 0.15), height: 1.5)
                context.fill(Path(underline), with: .color(yellow))
            }
        }
        drawSprite(at: CGPoint(x: size.width - 18, y: size.height - 16), in: &context)
    }

    // Agent: three targets; the sprite hops to each and "clicks" with a ripple.
    private static func drawAgent(progress: Double, in context: inout GraphicsContext, size: CGSize) {
        drawLines(count: 2, in: &context, size: size, startY: 14, gap: 12, widths: [0.35, 0.25])
        let buttons = [CGRect(x: 20, y: 46, width: 30, height: 12), CGRect(x: 62, y: 62, width: 34, height: 12), CGRect(x: 104, y: 44, width: 28, height: 12)]
        for button in buttons {
            context.fill(Path(roundedRect: button, cornerRadius: 4), with: .color(.white.opacity(0.12)))
        }
        let step = min(2, Int(progress * 3.2))
        let stepProgress = (progress * 3.2) - Double(step)
        let previous = step == 0 ? CGPoint(x: size.width - 20, y: size.height - 16) : CGPoint(x: buttons[step - 1].midX, y: buttons[step - 1].midY - 12)
        let target = CGPoint(x: buttons[step].midX, y: buttons[step].midY - 12)
        let hop = ease(stepProgress / 0.5)
        let position = CGPoint(x: previous.x + (target.x - previous.x) * hop, y: previous.y + (target.y - previous.y) * hop - sin(Double(hop) * .pi) * 10)
        // Trail of visited buttons.
        for index in 0..<step {
            context.stroke(Path(roundedRect: buttons[index].insetBy(dx: -2, dy: -2), cornerRadius: 5), with: .color(green.opacity(0.6)), lineWidth: 1)
        }
        if stepProgress > 0.55 {
            let ripple = ease((stepProgress - 0.55) / 0.4)
            let radius = 4 + 10 * ripple
            context.stroke(Path(ellipseIn: CGRect(x: buttons[step].midX - radius, y: buttons[step].midY - radius, width: radius * 2, height: radius * 2)),
                           with: .color(green.opacity(Double(1 - ripple))), lineWidth: 1.5)
            context.stroke(Path(roundedRect: buttons[step].insetBy(dx: -2, dy: -2), cornerRadius: 5), with: .color(green), lineWidth: 1)
        }
        drawSprite(at: position, in: &context)
    }
}
