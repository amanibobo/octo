//
//  WhiteboardPanelManager.swift
//  leanring-buddy
//
//  Sketches a small diagram in the emptiest margin of the screen: a layered
//  left-to-right layout of the nodes, hand-drawn boxes and arrows that draw on
//  over a second. Its own click-through panel so it sits over any app and
//  wipes itself after a while or on the next hotkey press.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class WhiteboardModel: ObservableObject {
    @Published var diagram: WhiteboardDiagram?
    @Published var drawProgress: CGFloat = 0
    var layout: [String: CGRect] = [:]
    var size: CGSize = .zero
}

private final class WhiteboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WhiteboardPanelManager {
    private let model = WhiteboardModel()
    private var panel: WhiteboardPanel?
    private var hideTask: Task<Void, Never>?

    private static let nodeSize = CGSize(width: 132, height: 44)
    private static let columnGap: CGFloat = 92
    private static let rowGap: CGFloat = 22
    private static let padding: CGFloat = 22

    /// Shows the diagram in the largest empty margin around `occupiedRect` (global
    /// AppKit coords of what the screen's text covers), on that screen.
    func show(_ diagram: WhiteboardDiagram, avoiding occupiedRect: CGRect, on screen: NSScreen, autoHideAfterSeconds: TimeInterval = 50) {
        hideTask?.cancel()
        let (layout, size) = Self.layout(diagram)
        model.layout = layout
        model.size = size
        model.diagram = diagram
        model.drawProgress = 0
        if panel == nil { createPanel() }
        guard let panel else { return }

        let panelSize = CGSize(width: size.width + Self.padding * 2, height: size.height + Self.padding * 2 + 26)
        let visible = screen.visibleFrame
        // Candidate margins: right, left, bottom, top of the occupied area; pick the roomiest.
        let candidates: [CGRect] = [
            CGRect(x: occupiedRect.maxX, y: visible.minY, width: visible.maxX - occupiedRect.maxX, height: visible.height),
            CGRect(x: visible.minX, y: visible.minY, width: occupiedRect.minX - visible.minX, height: visible.height),
            CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: occupiedRect.minY - visible.minY),
            CGRect(x: visible.minX, y: occupiedRect.maxY, width: visible.width, height: visible.maxY - occupiedRect.maxY),
        ]
        let fitting = candidates.filter { $0.width >= panelSize.width + 12 && $0.height >= panelSize.height + 12 }
        let margin = fitting.max { $0.width * $0.height < $1.width * $1.height }
        let origin: CGPoint
        if let margin {
            origin = CGPoint(x: margin.midX - panelSize.width / 2, y: margin.maxY - panelSize.height - 24)
        } else {
            // Nothing free: bottom-right corner, over whatever is there.
            origin = CGPoint(x: visible.maxX - panelSize.width - 20, y: visible.minY + 20)
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        withAnimation(.easeInOut(duration: 1.4)) { model.drawProgress = 1 }
        print("🧑‍🏫 whiteboard: \(diagram.nodes.count) nodes, \(diagram.edges.count) edges in \(margin == nil ? "corner" : "margin")")

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoHideAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
                self?.model.diagram = nil
            }
        })
    }

    private func createPanel() {
        let hosting = NSHostingView(rootView: WhiteboardView(model: model, padding: Self.padding))
        let whiteboardPanel = WhiteboardPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        whiteboardPanel.level = .statusBar
        whiteboardPanel.isOpaque = false
        whiteboardPanel.backgroundColor = .clear
        whiteboardPanel.hasShadow = false
        whiteboardPanel.ignoresMouseEvents = true
        whiteboardPanel.hidesOnDeactivate = false
        whiteboardPanel.isExcludedFromWindowsMenu = true
        whiteboardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        whiteboardPanel.contentView = hosting
        panel = whiteboardPanel
    }

    // MARK: - Layout

    /// Layered layout: sources in column 0, each node one column past its furthest
    /// predecessor; nodes stack vertically within a column.
    private static func layout(_ diagram: WhiteboardDiagram) -> ([String: CGRect], CGSize) {
        var depth: [String: Int] = [:]
        let incoming = Dictionary(grouping: diagram.edges, by: \.to)
        func computeDepth(_ id: String, visiting: Set<String>) -> Int {
            if let known = depth[id] { return known }
            let parents = (incoming[id] ?? []).map(\.from).filter { !visiting.contains($0) }
            let value = parents.isEmpty ? 0 : (parents.map { computeDepth($0, visiting: visiting.union([id])) }.max() ?? 0) + 1
            depth[id] = value
            return value
        }
        for node in diagram.nodes { _ = computeDepth(node.id, visiting: [node.id]) }
        let columns = Dictionary(grouping: diagram.nodes, by: { depth[$0.id] ?? 0 })
        let columnCount = (columns.keys.max() ?? 0) + 1
        let tallest = columns.values.map(\.count).max() ?? 1
        let totalHeight = CGFloat(tallest) * nodeSize.height + CGFloat(tallest - 1) * rowGap
        var rects: [String: CGRect] = [:]
        for column in 0..<columnCount {
            let nodesInColumn = columns[column] ?? []
            let columnHeight = CGFloat(nodesInColumn.count) * nodeSize.height + CGFloat(max(0, nodesInColumn.count - 1)) * rowGap
            let top = (totalHeight - columnHeight) / 2
            for (row, node) in nodesInColumn.enumerated() {
                rects[node.id] = CGRect(x: CGFloat(column) * (nodeSize.width + columnGap), y: top + CGFloat(row) * (nodeSize.height + rowGap),
                                        width: nodeSize.width, height: nodeSize.height)
            }
        }
        let width = CGFloat(columnCount) * nodeSize.width + CGFloat(max(0, columnCount - 1)) * columnGap
        return (rects, CGSize(width: width, height: totalHeight))
    }
}

// MARK: - View

private struct WhiteboardView: View {
    @ObservedObject var model: WhiteboardModel
    let padding: CGFloat

    var body: some View {
        if let diagram = model.diagram {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 10, weight: .bold))
                    Text(diagram.title.isEmpty ? "sketch" : diagram.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(DS.Colors.overlayCursorBlue)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(diagram.edges.enumerated()), id: \.offset) { index, edge in
                        if let from = model.layout[edge.from], let to = model.layout[edge.to] {
                            edgeView(index: index, from: from, to: to, label: edge.label)
                        }
                    }
                    ForEach(diagram.nodes) { node in
                        if let rect = model.layout[node.id] {
                            ZStack {
                                RoughRectangleShape(seed: "wb-" + node.id)
                                    .trim(from: 0, to: model.drawProgress)
                                    .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.78)))
                                Text(node.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.horizontal, 8)
                                    .opacity(Double(min(1, max(0, (model.drawProgress - 0.4) / 0.4))))
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
                .frame(width: model.size.width, height: model.size.height)
            }
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
    }

    private func edgeView(index: Int, from: CGRect, to: CGRect, label: String?) -> some View {
        let start = CGPoint(x: from.maxX, y: from.midY)
        let end = CGPoint(x: to.minX - 2, y: to.midY)
        let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y)
        let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: end.y)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
            }
            .trim(from: 0, to: model.drawProgress)
            .stroke(DS.Colors.overlayCursorBlue.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if model.drawProgress > 0.95 {
                Path { path in
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - 9, y: end.y - 5))
                    path.addLine(to: CGPoint(x: end.x - 9, y: end.y + 5))
                    path.closeSubpath()
                }
                .fill(DS.Colors.overlayCursorBlue)
            }
            if let label, model.drawProgress > 0.7 {
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .fixedSize()
                    .position(x: mid.x, y: mid.y - 10)
            }
        }
    }
}
