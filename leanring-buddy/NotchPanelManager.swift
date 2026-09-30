//
//  NotchPanelManager.swift
//  leanring-buddy
//
//  Octo lives in the MacBook notch. Following DynamicNotch's recipe: one
//  large transparent canvas panel pinned to the top-centre of the notch screen,
//  the island drawn in SwiftUI inside it, expansion as an animated SwiftUI size
//  change (the window itself never resizes), and the window delegated to a
//  SkyLight space so it renders above the menu bar. Hovering the notch expands
//  the island; leaving it, or clicking anywhere else, collapses it. Macs without
//  a notch keep the menu bar dropdown (MenuBarPanelManager).
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let sounderToggleNotch = Notification.Name("sounderToggleNotch")
}

/// Can become key so toggles and buttons in the card take clicks, but is a
/// non-activating panel so the user's frontmost app keeps focus.
private final class NotchCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally clamps windows below the menu bar. The canvas must sit
    /// flush with the top edge, over the notch, so the clamp is disabled.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets the first click on a control land without a preceding activation click.
private final class NotchHostingView: NSHostingView<NotchIslandView> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchPanelManager {
    private let companionManager: CompanionManager
    private let islandState = NotchIslandState()
    private var panel: NotchCanvasPanel?
    private var hoverTimer: Timer?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Transparent canvas the island is drawn in; large enough for the expanded card.
    private static let canvasSize = CGSize(width: 640, height: 940)
    /// Brief dwell so sweeping the pointer across the top edge does not open the island.
    private static let hoverExpandDelay: TimeInterval = 0.10
    private static let hoverCollapseDelay: TimeInterval = 0.55

    /// The built-in display with a notch, if the Mac has one.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    init?(companionManager: CompanionManager) {
        guard let screen = Self.notchScreen() else { return nil }
        self.companionManager = companionManager
        applyNotchMetrics(from: screen)
        createPanel()
        startHoverTracking()
        installOutsideClickMonitor()

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .sounderToggleNotch, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .clickyDismissPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setExpanded(false) }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.layoutPanel() }
        })
    }

    deinit {
        hoverTimer?.invalidate()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func toggle() {
        setExpanded(!islandState.isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard islandState.isExpanded != expanded else { return }
        print("🏝️ notch \(expanded ? "expand" : "collapse")")

        var withoutAnimation = Transaction()
        withoutAnimation.disablesAnimations = true

        if expanded {
            // Face off instantly, shape springs open, card content fades in as the
            // shape nears its final size.
            withTransaction(withoutAnimation) { islandState.isCollapsedFaceVisible = false }
            withAnimation(NotchIslandState.expandAnimation) { islandState.isExpanded = true }
            withAnimation(.easeOut(duration: 0.16).delay(0.14)) { islandState.isCardContentVisible = true }
            panel?.makeKey()
        } else {
            // Card content off instantly (no fade, no slide), then the shape shrinks,
            // then the face fades back in once the shrink has settled.
            withTransaction(withoutAnimation) {
                islandState.isCardContentVisible = false
                islandState.isShowingSettings = false
                islandState.isShowingContext = false
            }
            withAnimation(NotchIslandState.collapseAnimation) { islandState.isExpanded = false }
            withAnimation(.easeOut(duration: 0.14).delay(0.24)) { islandState.isCollapsedFaceVisible = true }
            panel?.resignKey()
        }
    }

    // MARK: - Panel

    /// Notch height is `safeAreaInsets.top`; its width is the gap between the two
    /// auxiliary top areas (the menu bar halves on either side of the camera).
    private func applyNotchMetrics(from screen: NSScreen) {
        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightArea = screen.auxiliaryTopRightArea ?? .zero
        islandState.notchWidth = max(120, rightArea.minX - leftArea.maxX)
        islandState.notchHeight = screen.safeAreaInsets.top
    }

    private func createPanel() {
        let rootView = NotchIslandView(companionManager: companionManager, state: islandState, onToggle: { [weak self] in self?.toggle() })
        let hosting = NotchHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        let canvas = NotchCanvasPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        canvas.isReleasedWhenClosed = false
        canvas.isFloatingPanel = true
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.hidesOnDeactivate = false
        canvas.isMovable = false
        canvas.isMovableByWindowBackground = false
        canvas.hasShadow = false
        canvas.animationBehavior = .none
        // Above the menu bar strip so the island can overlap the notch itself.
        canvas.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        canvas.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        canvas.acceptsMouseMovedEvents = true
        canvas.isExcludedFromWindowsMenu = true
        canvas.titleVisibility = .hidden
        canvas.titlebarAppearsTransparent = true
        canvas.contentView = hosting

        panel = canvas
        layoutPanel()
        canvas.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(canvas)
    }

    /// The canvas is pinned to the top-centre of the notch screen. SwiftUI lays
    /// the island out at the top of the canvas, so the window never moves or resizes.
    private func layoutPanel() {
        guard let panel, let screen = Self.notchScreen() else { return }
        applyNotchMetrics(from: screen)
        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let notchCenterX = leftArea.maxX + islandState.notchWidth / 2
        let frame = NSRect(
            x: floor(notchCenterX - Self.canvasSize.width / 2),
            y: screen.frame.maxY - Self.canvasSize.height + 1,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height
        )
        panel.setFrame(frame, display: true)
        print("🏝️ notch canvas \(frame.integral) · notch \(Int(islandState.notchWidth))×\(Int(islandState.notchHeight)) at x \(Int(leftArea.maxX)) · level \(panel.level.rawValue) · skylight \(SkyLightOperator.shared.isAvailable)")
    }

    /// Screen rect (global AppKit coordinates) the island currently occupies.
    private var islandScreenRect: CGRect {
        guard let panel, let screen = Self.notchScreen() else { return .zero }
        var islandSize = islandState.measuredIslandSize
        if islandSize.width < 1 || islandSize.height < 1 {
            islandSize = islandState.isExpanded
                ? CGSize(width: islandState.expandedWidth, height: 320)
                : islandState.collapsedSize
        }
        return CGRect(
            x: panel.frame.midX - islandSize.width / 2,
            y: screen.frame.maxY - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
    }

    // MARK: - Hover

    /// Expands when the pointer parks on the notch, collapses a moment after it leaves.
    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateHover() }
        }
    }

    private func updateHover() {
        let mouseLocation = NSEvent.mouseLocation
        let islandRect = islandScreenRect
        // Collapsed: the notch plus the menu-bar strip just around and below it, so
        // brushing the top of the screen near the notch opens it. Expanded: the card.
        let hoverZone = islandState.isExpanded
            ? islandRect.insetBy(dx: -10, dy: -10)
            : islandRect.insetBy(dx: -30, dy: 0).union(islandRect.offsetBy(dx: 0, dy: -16))
        let isInside = hoverZone.contains(mouseLocation)
        if isInside != islandState.isHovering {
            islandState.isHovering = isInside
        }

        if isInside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            if !islandState.isExpanded, expandWorkItem == nil {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.expandWorkItem = nil
                    if self.islandState.isHovering { self.setExpanded(true) }
                }
                expandWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: workItem)
            }
        } else {
            expandWorkItem?.cancel()
            expandWorkItem = nil
            // The settings and context pages stay open until the user clicks away or presses back.
            if islandState.isExpanded, collapseWorkItem == nil, !islandState.isShowingSettings, !islandState.isShowingContext {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.collapseWorkItem = nil
                    if !self.islandState.isHovering { self.setExpanded(false) }
                }
                collapseWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCollapseDelay, execute: workItem)
            }
        }
    }

    /// Clicking anywhere outside the island collapses it.
    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.islandState.isExpanded else { return }
                if !self.islandScreenRect.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
            }
        }
    }
}
