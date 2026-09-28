//
//  RewindPanelManager.swift
//  leanring-buddy
//
//  The rewind card: a remembered frame with the matching lines highlighted and
//  a scrub bar across the whole buffer. Its own key-able, non-activating panel
//  (the overlay is click-through) so the slider can be dragged. Esc, the close
//  button, the next hotkey press, or a minute of inactivity dismisses it.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class RewindModel: ObservableObject {
    @Published var frames: [ScreenHistoryFrame] = []
    @Published var selectedIndex: Int = 0
    @Published var matchedFrameID: UUID?
    @Published var matchedLineIndices: [Int] = []
    @Published var query: String = ""
    /// Keyword hits on whatever frame is being scrubbed to (recomputed per frame).
    var lineIndicesForFrame: (ScreenHistoryFrame) -> [Int] = { _ in [] }

    var selectedFrame: ScreenHistoryFrame? {
        frames.indices.contains(selectedIndex) ? frames[selectedIndex] : nil
    }
}

private final class RewindPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class RewindPanelManager {
    private let model = RewindModel()
    private var panel: RewindPanel?
    private var hideTask: Task<Void, Never>?
    private static let panelWidth: CGFloat = 640

    func show(match: ScreenHistoryMatch, frames: [ScreenHistoryFrame], query: String,
              lineIndicesForFrame: @escaping (ScreenHistoryFrame) -> [Int], nearGlobalPoint anchor: CGPoint) {
        hideTask?.cancel()
        // Populate the model before the view exists so its first body pass sees real frames.
        model.frames = frames
        model.query = query
        model.matchedFrameID = match.frame.id
        model.matchedLineIndices = match.matchedLineIndices
        model.lineIndicesForFrame = lineIndicesForFrame
        model.selectedIndex = frames.firstIndex { $0.id == match.frame.id } ?? max(0, frames.count - 1)
        if panel == nil { createPanel() }
        guard let panel else { return }

        panel.layoutIfNeeded()
        let fittingHeight = max(panel.contentView?.fittingSize.height ?? 420, 240)
        var origin = CGPoint(x: anchor.x + 40, y: anchor.y - fittingHeight - 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            let visible = screen.visibleFrame
            if origin.x + Self.panelWidth > visible.maxX - 12 { origin.x = anchor.x - 40 - Self.panelWidth }
            if origin.y < visible.minY + 12 { origin.y = anchor.y + 40 }
            origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - Self.panelWidth - 12))
            origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - fittingHeight - 12))
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: Self.panelWidth, height: fittingHeight), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
        print("⏪ rewind card: frame \(ScreenHistoryFrame.describeAge(match.frame.age())) · \(match.matchedLineIndices.count) lines · \(frames.count) frames")

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
                self?.model.frames = []
            }
        })
    }

    private func createPanel() {
        let hosting = NSHostingView(rootView: RewindView(model: model, onClose: { [weak self] in self?.hide() }))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420)
        let rewindPanel = RewindPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        rewindPanel.level = .statusBar
        rewindPanel.isOpaque = false
        rewindPanel.backgroundColor = .clear
        rewindPanel.hasShadow = true
        rewindPanel.hidesOnDeactivate = false
        rewindPanel.isExcludedFromWindowsMenu = true
        rewindPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        rewindPanel.contentView = hosting
        rewindPanel.onEscape = { [weak self] in self?.hide() }
        panel = rewindPanel
    }
}

// MARK: - Glass

/// Liquid-glass card background: the system glass material on macOS 26, a
/// vibrant blur with a soft rim on earlier systems. No coloured outline.
struct GlassCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - View

private struct RewindView: View {
    @ObservedObject var model: RewindModel
    let onClose: () -> Void

    private let imageWidth: CGFloat = 616

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            frameImage
            scrubBar
            matchedText
        }
        .padding(14)
        .frame(width: 640, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "backward.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.overlayCursorBlue)
            Text("REWIND")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .tracking(0.8)
            if let frame = model.selectedFrame {
                Text(ScreenHistoryFrame.describeAge(frame.age()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(frame.capturedAt, style: .time)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var frameImage: some View {
        if let frame = model.selectedFrame, let nsImage = NSImage(data: frame.thumbnailJPEG) {
            let scale = imageWidth / CGFloat(max(frame.thumbnailWidth, 1))
            let imageHeight = CGFloat(frame.thumbnailHeight) * scale
            ZStack(alignment: .topLeading) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: imageWidth, height: imageHeight)
                ForEach(highlightedLineIndices(for: frame), id: \.self) { lineIndex in
                    let box = frame.lines[lineIndex].boundingBoxInCapturePixels
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(DS.Colors.overlayCursorBlue.opacity(0.7), lineWidth: 1.5))
                        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6)
                        .frame(width: box.width * scale + 6, height: box.height * scale + 6)
                        .offset(x: box.minX * scale - 3, y: box.minY * scale - 3)
                }
            }
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        } else {
            Text("nothing remembered yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: imageWidth, height: 120)
        }
    }

    private func highlightedLineIndices(for frame: ScreenHistoryFrame) -> [Int] {
        if frame.id == model.matchedFrameID, !model.matchedLineIndices.isEmpty { return model.matchedLineIndices }
        return Array(model.lineIndicesForFrame(frame).prefix(6))
    }

    private var scrubBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                stepButton(systemName: "chevron.left") { model.selectedIndex = max(0, model.selectedIndex - 1) }
                if model.frames.count > 1 {
                    // A Slider with a zero-width range traps, so a single frame gets a static bar.
                    Slider(value: Binding(get: { Double(model.selectedIndex) }, set: { model.selectedIndex = Int($0.rounded()) }),
                           in: 0...Double(model.frames.count - 1), step: 1)
                        .tint(DS.Colors.overlayCursorBlue)
                        .pointerCursor()
                } else {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 4).frame(maxWidth: .infinity)
                }
                stepButton(systemName: "chevron.right") { model.selectedIndex = min(max(model.frames.count - 1, 0), model.selectedIndex + 1) }
            }
            HStack {
                Text(model.frames.first.map { ScreenHistoryFrame.describeAge($0.age()) } ?? "")
                Spacer()
                Text("\(model.frames.count) frames · 15 min · in memory only")
                Spacer()
                Text("now")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.45))
        }
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var matchedText: some View {
        if let frame = model.selectedFrame {
            let indices = highlightedLineIndices(for: frame)
            if !indices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(indices.prefix(3), id: \.self) { index in
                        Text(frame.lines[index].text)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}
