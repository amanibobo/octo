//
//  NotchPanelManager.swift
//  leanring-buddy
//
//  Sounder lives in the MacBook notch. A borderless, non-activating panel sits
//  exactly over the notch (black, so it disappears into it) and shows the buddy's
//  face and voice state; hovering or clicking it unfurls the full control panel
//  beneath the notch, like a dynamic island. Macs without a notch keep the menu
//  bar dropdown (MenuBarPanelManager).
//
//  Geometry comes from NSScreen: `safeAreaInsets.top` is the notch height and the
//  gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` is its width.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let sounderToggleNotch = Notification.Name("sounderToggleNotch")
}

/// Panel that may become key so the panel's toggles and buttons take clicks,
/// but never activates the app (the user's frontmost app keeps focus).
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally clamps windows below the menu bar. The island must sit
    /// flush with the top edge, over the notch, so the clamp is disabled.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var isExpanded = false
    @Published var isHovering = false
}

@MainActor
final class NotchPanelManager {
    private let companionManager: CompanionManager
    private let notchState = NotchState()
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchRootView>?
    private var hoverTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var toggleObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?

    private static let expandedWidth: CGFloat = 400
    private static let collapsedExtraWidth: CGFloat = 28

    /// The built-in display with a notch, if the Mac has one.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    init?(companionManager: CompanionManager) {
        guard Self.notchScreen() != nil else { return nil }
        self.companionManager = companionManager
        createPanel()
        startHoverTracking()

        toggleObserver = NotificationCenter.default.addObserver(forName: .sounderToggleNotch, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
        }
        dismissObserver = NotificationCenter.default.addObserver(forName: .clickyDismissPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setExpanded(false) }
        }
        screenChangeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.layoutPanel(animated: false) }
        }
    }

    deinit {
        hoverTimer?.invalidate()
        for observer in [toggleObserver, dismissObserver, screenChangeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggle() {
        setExpanded(!notchState.isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard notchState.isExpanded != expanded else { return }
        collapseWorkItem?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            notchState.isExpanded = expanded
        }
        layoutPanel(animated: true)
        if expanded {
            panel?.makeKey()
        } else {
            panel?.resignKey()
        }
    }

    // MARK: - Panel

    private func createPanel() {
        let rootView = NotchRootView(companionManager: companionManager, notchState: notchState, onToggle: { [weak self] in self?.toggle() })
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        let notchPanel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar so the collapsed pill covers the notch area itself.
        notchPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.hidesOnDeactivate = false
        notchPanel.isFloatingPanel = true
        notchPanel.isExcludedFromWindowsMenu = true
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        notchPanel.contentView = hosting
        notchPanel.isMovableByWindowBackground = false

        panel = notchPanel
        hostingView = hosting
        layoutPanel(animated: false)
        notchPanel.orderFrontRegardless()
    }

    private func layoutPanel(animated: Bool) {
        guard let panel, let screen = Self.notchScreen() else { return }
        let notchHeight = screen.safeAreaInsets.top
        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightArea = screen.auxiliaryTopRightArea ?? .zero
        let notchWidth = max(120, rightArea.minX - leftArea.maxX)
        let notchCenterX = leftArea.maxX + notchWidth / 2

        let size: CGSize
        if notchState.isExpanded {
            let contentHeight = hostingView?.fittingSize.height ?? 420
            size = CGSize(width: Self.expandedWidth, height: max(contentHeight, notchHeight + 200))
        } else {
            size = CGSize(width: notchWidth + Self.collapsedExtraWidth, height: notchHeight + 8)
        }
        let frame = NSRect(x: notchCenterX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Hover

    /// Expands when the pointer parks on the notch, collapses a moment after it leaves.
    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateHover() }
        }
    }

    private func updateHover() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(mouse)
        if inside != notchState.isHovering {
            notchState.isHovering = inside
        }
        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            if !notchState.isExpanded {
                // A brief dwell, so passing the pointer across the top edge does not open it.
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.notchState.isHovering else { return }
                    self.setExpanded(true)
                }
                collapseWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
            }
        } else if notchState.isExpanded, collapseWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.notchState.isHovering else { return }
                self.setExpanded(false)
            }
            collapseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
        }
    }
}

// MARK: - SwiftUI

/// Black island hanging from the notch: collapsed shows the buddy's eyes and
/// voice state; expanded shows the full control panel.
struct NotchRootView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchState: NotchState
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if notchState.isExpanded {
                CompanionPanelView(companionManager: companionManager, isEmbeddedInNotch: true)
                    .padding(.top, notchHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedContent
                    .frame(height: notchHeight)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            NotchShape(cornerRadius: notchState.isExpanded ? 22 : 14)
                .fill(Color.black)
                .shadow(color: Color.black.opacity(notchState.isExpanded ? 0.45 : 0), radius: 18, x: 0, y: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: notchState.isExpanded)
    }

    private var notchHeight: CGFloat {
        NotchPanelManager.notchScreen()?.safeAreaInsets.top ?? 38
    }

    /// Eyes when idle, waveform while listening, a pulse while thinking, bouncing eyes while talking.
    private var collapsedContent: some View {
        HStack(spacing: 6) {
            switch companionManager.voiceState {
            case .listening:
                NotchWaveform(audioPowerLevel: companionManager.currentAudioPowerLevel)
            case .processing:
                NotchPulse()
            case .idle, .responding:
                NotchEyes(isTalking: companionManager.voiceState == .responding, isHovering: notchState.isHovering)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

/// Rounded-bottom rectangle that meets the screen edge flush at the top.
struct NotchShape: Shape {
    var cornerRadius: CGFloat
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NotchEyes: View {
    let isTalking: Bool
    let isHovering: Bool
    @State private var isBlinking = false

    var body: some View {
        HStack(spacing: 10) {
            eye
            eye
        }
        .scaleEffect(isHovering ? 1.15 : 1)
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
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: 9, height: isTalking ? 12 : 10)
            .scaleEffect(x: 1, y: isBlinking ? 0.12 : 1, anchor: .center)
            .animation(.easeInOut(duration: 0.07), value: isBlinking)
            .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: isTalking)
    }
}

private struct NotchWaveform: View {
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

private struct NotchPulse: View {
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
