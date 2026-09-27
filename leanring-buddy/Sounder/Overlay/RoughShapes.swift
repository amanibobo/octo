//
//  RoughShapes.swift
//  leanring-buddy
//
//  Hand-drawn looking outlines for the overlay: a rectangle traced as slightly
//  wobbly strokes with overshooting corners, like a marker circling something
//  on a whiteboard. Jitter is seeded from the primitive id so a shape looks the
//  same on every redraw instead of shimmering.
//

import SwiftUI

/// Small deterministic generator (xorshift) so the wobble is stable per shape.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: String) {
        // FNV-1a over the id string; stable across launches (unlike hashValue).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        state = hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 10_000) / 10_000.0
    }

    /// Uniform in -amplitude ... +amplitude
    mutating func wobble(_ amplitude: CGFloat) -> CGFloat {
        CGFloat(next() * 2 - 1) * amplitude
    }
}

/// A rectangle drawn as two overlapping imperfect passes, the way a person
/// circles something quickly. Works with `.trim` so it can animate on.
struct RoughRectangleShape: Shape {
    let seed: String
    var wobbleAmplitude: CGFloat = 2.2
    var cornerOvershoot: CGFloat = 4
    var passes: Int = 2

    func path(in rect: CGRect) -> Path {
        var random = SeededRandom(seed: seed)
        var path = Path()

        for pass in 0..<passes {
            let passOffset = CGFloat(pass) * 1.4
            let corners = [
                CGPoint(x: rect.minX - passOffset, y: rect.minY - passOffset),
                CGPoint(x: rect.maxX + passOffset, y: rect.minY - passOffset),
                CGPoint(x: rect.maxX + passOffset, y: rect.maxY + passOffset),
                CGPoint(x: rect.minX - passOffset, y: rect.maxY + passOffset),
            ]
            // Start a little before the first corner so the loop visibly overlaps itself.
            let start = CGPoint(x: corners[0].x + cornerOvershoot * 2 + random.wobble(2), y: corners[0].y + random.wobble(wobbleAmplitude))
            path.move(to: start)

            for cornerIndex in 0..<4 {
                let from = corners[cornerIndex]
                let to = corners[(cornerIndex + 1) % 4]
                let segmentCount = max(3, Int(hypot(to.x - from.x, to.y - from.y) / 60))
                // Overshoot each corner slightly in the direction of travel.
                let direction = CGPoint(x: (to.x - from.x).sign == .minus ? -1 : (to.x == from.x ? 0 : 1),
                                        y: (to.y - from.y).sign == .minus ? -1 : (to.y == from.y ? 0 : 1))
                let overshotEnd = CGPoint(x: to.x + direction.x * cornerOvershoot + random.wobble(1.5),
                                          y: to.y + direction.y * cornerOvershoot + random.wobble(1.5))
                for segment in 1...segmentCount {
                    let t = CGFloat(segment) / CGFloat(segmentCount)
                    let base = CGPoint(x: from.x + (overshotEnd.x - from.x) * t, y: from.y + (overshotEnd.y - from.y) * t)
                    let point = CGPoint(x: base.x + random.wobble(wobbleAmplitude), y: base.y + random.wobble(wobbleAmplitude))
                    let previous = path.currentPoint ?? base
                    let control = CGPoint(x: (previous.x + point.x) / 2 + random.wobble(wobbleAmplitude),
                                          y: (previous.y + point.y) / 2 + random.wobble(wobbleAmplitude))
                    path.addQuadCurve(to: point, control: control)
                }
            }
        }
        return path
    }
}

/// A single wobbly stroke between two points (underlines, connectors).
struct RoughLineShape: Shape {
    let seed: String
    let from: CGPoint
    let to: CGPoint
    var wobbleAmplitude: CGFloat = 1.6

    func path(in rect: CGRect) -> Path {
        var random = SeededRandom(seed: seed)
        var path = Path()
        path.move(to: CGPoint(x: from.x + random.wobble(1), y: from.y + random.wobble(1)))
        let segmentCount = max(3, Int(hypot(to.x - from.x, to.y - from.y) / 40))
        for segment in 1...segmentCount {
            let t = CGFloat(segment) / CGFloat(segmentCount)
            let base = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            let point = CGPoint(x: base.x + random.wobble(wobbleAmplitude), y: base.y + random.wobble(wobbleAmplitude))
            let previous = path.currentPoint ?? base
            path.addQuadCurve(to: point, control: CGPoint(x: (previous.x + point.x) / 2 + random.wobble(wobbleAmplitude),
                                                          y: (previous.y + point.y) / 2 + random.wobble(wobbleAmplitude)))
        }
        return path
    }
}
