//
//  NotchIslandView.swift
//  leanring-buddy
//
//  The island itself, drawn inside a large transparent canvas window (see
//  NotchPanelManager). Its shape is the notch silhouette: top corners flare
//  outward into the screen edge, bottom corners are rounded. Collapsed it is
//  the notch plus a few points; expanded it grows into the control card with a
//  spring, all as a SwiftUI size change (no window resizing), which is what
//  gives DynamicNotch-style morphing.
//

import Combine
import SwiftUI

/// Notch silhouette (ported from DynamicNotch's NotchShape).
struct NotchSilhouetteShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

@MainActor
final class NotchIslandState: ObservableObject {
    @Published var isExpanded = false
    @Published var isHovering = false
    @Published var isPressed = false
    @Published var isShowingSettings = false

    /// Physical notch metrics, set once from the screen.
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 38
    /// The island's current rendered size (follows the spring), reported by the
    /// view so the hover zone and outside-click test match what is on screen.
    /// Not published: it changes every animation frame and nothing renders from it.
    var measuredIslandSize: CGSize = .zero

    static let expandedWidth: CGFloat = 440
    static let springAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.75, blendDuration: 1)

    var collapsedSize: CGSize {
        // Notch + 6pt each side, so the flared top corners hide the physical notch edge.
        CGSize(width: notchWidth + 12, height: notchHeight + 1)
    }
}

struct NotchIslandView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var state: NotchIslandState
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        let topRadius: CGFloat = state.isExpanded ? 14 : 6
        let bottomRadius: CGFloat = state.isExpanded ? 22 : state.notchHeight / 3
        let shape = NotchSilhouetteShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)

        return ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .overlay(shape.stroke(Color.white.opacity(state.isExpanded ? 0.12 : 0.0), lineWidth: 1))
                .shadow(color: .black.opacity(state.isExpanded ? 0.35 : 0), radius: 22, x: 0, y: 10)

            content
                .mask(shape.padding(.horizontal, 4).padding(.bottom, 3))
        }
        .frame(width: state.isExpanded ? NotchIslandState.expandedWidth : state.collapsedSize.width,
               height: state.isExpanded ? nil : state.collapsedSize.height)
        .fixedSize(horizontal: false, vertical: state.isExpanded)
        .background(
            GeometryReader { islandGeometry in
                Color.clear
                    .onAppear { state.measuredIslandSize = islandGeometry.size }
                    .onChange(of: islandGeometry.size) { _, newSize in state.measuredIslandSize = newSize }
            }
        )
        .scaleEffect(state.isPressed ? 0.975 : 1, anchor: .top)
        .contentShape(shape)
        .onTapGesture { onToggle() }
        .animation(NotchIslandState.springAnimation, value: state.isExpanded)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.isPressed)
    }

    @ViewBuilder
    private var content: some View {
        if state.isExpanded {
            VStack(spacing: 0) {
                if state.isShowingSettings {
                    NotchSettingsView(companionManager: companionManager, onBack: {
                        withAnimation(NotchIslandState.springAnimation) { state.isShowingSettings = false }
                    })
                } else if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                    NotchPanelContentView(companionManager: companionManager, onOpenSettings: {
                        withAnimation(NotchIslandState.springAnimation) { state.isShowingSettings = true }
                    })
                } else {
                    CompanionPanelView(companionManager: companionManager, isEmbeddedInNotch: true)
                }
            }
            .padding(.top, state.notchHeight)
            .frame(width: NotchIslandState.expandedWidth)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        } else {
            collapsedContent
                .frame(width: state.collapsedSize.width, height: state.collapsedSize.height)
                .transition(.opacity)
        }
    }

    /// Eyes when idle, waveform while listening, a pulse while thinking, bouncing eyes while talking.
    private var collapsedContent: some View {
        HStack(spacing: 6) {
            switch companionManager.voiceState {
            case .listening:
                NotchWaveformIndicator(audioPowerLevel: companionManager.currentAudioPowerLevel)
            case .processing:
                NotchPulseIndicator()
            case .idle, .responding:
                NotchEyesIndicator(isTalking: companionManager.voiceState == .responding, isHovering: state.isHovering)
            }
        }
        .padding(.top, 3)
    }
}

// MARK: - Collapsed indicators

private struct NotchEyesIndicator: View {
    let isTalking: Bool
    let isHovering: Bool
    @State private var isBlinking = false

    var body: some View {
        HStack(spacing: 9) {
            eye
            eye
        }
        .scaleEffect(isHovering ? 1.12 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_400_000_000...4_800_000_000))
                isBlinking = true
                try? await Task.sleep(nanoseconds: 130_000_000)
                isBlinking = false
            }
        }
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: 7, height: isTalking ? 10 : 8)
            .scaleEffect(x: 1, y: isBlinking ? 0.12 : 1, anchor: .center)
            .animation(.easeInOut(duration: 0.07), value: isBlinking)
            .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: isTalking)
    }
}

private struct NotchWaveformIndicator: View {
    let audioPowerLevel: CGFloat
    private let profile: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(width: 3, height: barHeight(index: index, date: context.date))
                }
            }
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 4) + CGFloat(index) * 0.5
        let reactive = min(audioPowerLevel * 2.8, 1) * 14 * profile[index]
        return 4 + reactive + (sin(phase) + 1) * 1.5
    }
}

private struct NotchPulseIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.35 : 0.8)
            .opacity(isPulsing ? 0.6 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isPulsing = true }
            }
    }
}
