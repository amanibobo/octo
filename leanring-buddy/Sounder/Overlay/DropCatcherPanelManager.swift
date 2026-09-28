//
//  DropCatcherPanelManager.swift
//  leanring-buddy
//
//  Drop it on Octo. The cursor overlay is click-through, so it cannot take a
//  drop; instead, when a drag starts anywhere, a small catcher window pops up a
//  little away from where the drag began, showing Octo with two tentacles
//  reaching up. Drop text, a link, a file or an image on it and it grabs it
//  (tentacles curl, a bounce) and pins it as context. It disappears when the
//  drag ends.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DropCatcherModel: ObservableObject {
    enum Phase {
        case waiting
        case ready
        case grabbing
        case caught
    }
    @Published var phase: Phase = .waiting
    @Published var caughtTitle: String = ""
}

/// The hosting view itself is the drag destination, so the drop lands on it.
private final class DropCatcherHostingView: NSHostingView<DropCatcherView> {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    func registerDragTypes() {
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, NSPasteboard.PasteboardType(UTType.image.identifier)])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

private final class DropCatcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DropCatcherPanelManager {
    private let model = DropCatcherModel()
    private let userContextStore: UserContextStore
    /// Called with true while the catcher is up (the cursor buddy hides), false after.
    private let onActiveChange: (Bool) -> Void
    private let onCaught: (String) -> Void

    private var panel: DropCatcherPanel?
    private var hostingView: DropCatcherHostingView?
    private var monitors: [Any] = []
    private var dragStartPoint: CGPoint?
    private var dragStartedAt: Date?
    private var lastDragEventAt = Date.distantPast
    /// The system drag pasteboard changes only when a real drag-and-drop session
    /// starts, which separates "dragging a file" from "selecting text" or moving a window.
    private var idleDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    private var isShowing = false
    private var isHandlingDrop = false
    private var hideTask: Task<Void, Never>?

    private static let panelSize = CGSize(width: 132, height: 132)
    private static let showAfterDistance: CGFloat = 40
    private static let showAfterSeconds: TimeInterval = 0.2

    init(userContextStore: UserContextStore, onActiveChange: @escaping (Bool) -> Void, onCaught: @escaping (String) -> Void) {
        self.userContextStore = userContextStore
        self.onActiveChange = onActiveChange
        self.onCaught = onCaught
    }

    /// Watches for drags anywhere on the Mac (other apps included).
    func start() {
        guard monitors.isEmpty else { return }
        if let dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.dragMoved(to: NSEvent.mouseLocation) }
        }) { monitors.append(dragMonitor) }
        if let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.dragEnded() }
        }) { monitors.append(upMonitor) }
        if let localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.dragEnded() }
            return event
        }) { monitors.append(localUp) }
    }

    private func dragMoved(to point: CGPoint) {
        let now = Date()
        lastDragEventAt = now
        if dragStartPoint == nil {
            dragStartPoint = point
            dragStartedAt = now
        }
        guard !isShowing, let start = dragStartPoint, let startedAt = dragStartedAt else { return }
        let dragPasteboard = NSPasteboard(name: .drag)
        let isRealDragSession = dragPasteboard.changeCount != idleDragPasteboardChangeCount && !(dragPasteboard.types ?? []).isEmpty
        guard isRealDragSession else { return }
        let distance = hypot(point.x - start.x, point.y - start.y)
        if distance >= Self.showAfterDistance, now.timeIntervalSince(startedAt) >= Self.showAfterSeconds {
            show(near: start)
        }
        // A drag that stalls with no mouse-up (some apps swallow it) still goes away.
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, !self.isHandlingDrop else { return }
            self.dragEnded()
        }
    }

    private func dragEnded() {
        dragStartPoint = nil
        dragStartedAt = nil
        idleDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        guard isShowing, !isHandlingDrop else { return }
        hide(afterSeconds: 0.25)
    }

    private func show(near start: CGPoint) {
        if panel == nil { createPanel() }
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(start) }) ?? NSScreen.main else { return }
        // Octo waits a little to the right and above where the drag began, inside the screen.
        var origin = CGPoint(x: start.x + 110, y: start.y + 20)
        let visible = screen.visibleFrame
        if origin.x + Self.panelSize.width > visible.maxX - 12 { origin.x = start.x - 110 - Self.panelSize.width }
        origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - Self.panelSize.width - 12))
        origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - Self.panelSize.height - 12))
        model.phase = .waiting
        model.caughtTitle = ""
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        isShowing = true
        onActiveChange(true)
    }

    private func hide(afterSeconds delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.panel?.orderOut(nil)
                    self.isShowing = false
                    self.isHandlingDrop = false
                    self.model.phase = .waiting
                    self.onActiveChange(false)
                }
            })
        }
    }

    private func createPanel() {
        let hosting = DropCatcherHostingView(rootView: DropCatcherView(model: model))
        hosting.registerDragTypes()
        hosting.onDragEntered = { [weak self] in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { self?.model.phase = .ready }
        }
        hosting.onDragExited = { [weak self] in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { self?.model.phase = .waiting }
        }
        hosting.onDrop = { [weak self] pasteboard in
            guard let self else { return false }
            return self.handleDrop(pasteboard)
        }
        let catcherPanel = DropCatcherPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        catcherPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        catcherPanel.isOpaque = false
        catcherPanel.backgroundColor = .clear
        catcherPanel.hasShadow = false
        catcherPanel.hidesOnDeactivate = false
        catcherPanel.ignoresMouseEvents = false
        catcherPanel.isExcludedFromWindowsMenu = true
        catcherPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        catcherPanel.contentView = hosting
        panel = catcherPanel
        hostingView = hosting
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        isHandlingDrop = true
        let countBefore = userContextStore.items.count
        let added = userContextStore.add(from: pasteboard)
        let title = userContextStore.items.count > countBefore ? (userContextStore.items.last?.title ?? "") : ""
        guard added else {
            isHandlingDrop = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { model.phase = .waiting }
            hide(afterSeconds: 0.6)
            return false
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { model.phase = .grabbing }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard let self else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                self.model.phase = .caught
                self.model.caughtTitle = title
            }
            self.onCaught(title)
            self.hide(afterSeconds: 1.1)
        }
        print("🐙 drop caught: \(title)")
        return true
    }
}

// MARK: - View

private struct DropCatcherView: View {
    @ObservedObject var model: DropCatcherModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 6) {
                ZStack {
                    tentacles(time: time)
                    body_(time: time)
                }
                .frame(width: 96, height: 84)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .lineLimit(1)
            }
            .frame(width: 132, height: 132)
        }
    }

    private var label: String {
        switch model.phase {
        case .waiting: return "drop it on me"
        case .ready: return "yes, that!"
        case .grabbing: return "got it"
        case .caught: return model.caughtTitle.isEmpty ? "pinned" : "pinned: \(model.caughtTitle)"
        }
    }

    private func body_(time: TimeInterval) -> some View {
        let bob = sin(time * 2.4) * 2
        let scale: CGFloat = model.phase == .grabbing ? 1.18 : (model.phase == .ready ? 1.08 : 1)
        return ZStack {
            Circle()
                .fill(DS.Colors.overlayCursorBlue.opacity(model.phase == .ready ? 0.35 : 0.18))
                .frame(width: 60, height: 60)
                .blur(radius: 10)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 36, height: 36)
            HStack(spacing: 7) {
                eye
                eye
            }
            .offset(y: -2)
            if model.phase == .caught {
                Circle()
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.7), lineWidth: 2)
                    .frame(width: 70, height: 70)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .scaleEffect(scale)
        .offset(y: bob + (model.phase == .caught ? -4 : 0))
    }

    private var eye: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: model.phase == .caught ? 4 : 9) // happy squint once it has it
            .offset(y: model.phase == .caught ? -1 : 0)
    }

    /// Two arms that sway while waiting, spread when something hovers, and curl in on a grab.
    private func tentacles(time: TimeInterval) -> some View {
        let sway = CGFloat(sin(time * 3.1)) * 6
        let spread: CGFloat = model.phase == .ready ? 26 : (model.phase == .waiting ? 10 : -6)
        let lift: CGFloat = model.phase == .ready ? -30 : (model.phase == .waiting ? -18 : 4)
        return ZStack {
            tentacle(mirrored: false, sway: sway, spread: spread, lift: lift)
            tentacle(mirrored: true, sway: -sway, spread: spread, lift: lift)
        }
    }

    private func tentacle(mirrored: Bool, sway: CGFloat, spread: CGFloat, lift: CGFloat) -> some View {
        let direction: CGFloat = mirrored ? -1 : 1
        return Path { path in
            let base = CGPoint(x: 48 + direction * 14, y: 46)
            let tip = CGPoint(x: 48 + direction * (28 + spread) + sway, y: 40 + lift)
            let control1 = CGPoint(x: 48 + direction * 30, y: 52)
            let control2 = CGPoint(x: 48 + direction * (34 + spread * 0.5) + sway * 0.5, y: 44 + lift * 0.6)
            path.move(to: base)
            path.addCurve(to: tip, control1: control1, control2: control2)
        }
        .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .overlay(
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 8, height: 8)
                .position(x: 48 + direction * (28 + spread) + sway, y: 40 + lift)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: spread)
    }
}
