//
//  AgentTaskCardPanelManager.swift
//  leanring-buddy
//
//  The agent's task card: a glass card in the top-right corner of the screen
//  that names what the user asked for, lists the steps the agent plans to take,
//  and ticks them off as it works. Its own non-activating panel, because the
//  main overlay is click-through and lives on every screen.
//

import AppKit
import Combine
import SwiftUI

struct AgentTaskCardStep: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case active
        case done
        case failed
    }
    let id: Int
    var title: String
    var status: Status
}

@MainActor
final class AgentTaskCardModel: ObservableObject {
    @Published var task = ""
    @Published var steps: [AgentTaskCardStep] = []
    @Published var statusLine = "planning…"
    @Published var isFinished = false
    @Published var didSucceed = true
}

private final class AgentTaskCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentTaskCardPanelManager {
    private let model = AgentTaskCardModel()
    private var panel: AgentTaskCardPanel?
    private var hostingView: NSHostingView<AgentTaskCardView>?
    private var hideTask: Task<Void, Never>?
    /// Reported by the view; the panel is re-fitted whenever it changes.
    private var contentHeight: CGFloat = 120
    private static let cardWidth: CGFloat = 340
    private static let screenMargin: CGFloat = 14

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Opens the card for a new task (or reuses the visible one) with no steps yet.
    func show(task: String) {
        hideTask?.cancel()
        model.task = task
        model.steps = []
        model.statusLine = "planning…"
        model.isFinished = false
        model.didSucceed = true
        if panel == nil { createPanel() }
        guard let panel else { return }
        layoutPanel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                panel.animator().alphaValue = 1
            }
        }
    }

    /// The planned steps, all pending.
    func setPlan(_ stepTitles: [String]) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            model.steps = stepTitles.enumerated().map { AgentTaskCardStep(id: $0.offset, title: $0.element, status: .pending) }
            model.statusLine = stepTitles.isEmpty ? "working it out as i go" : "\(stepTitles.count) steps"
        }
    }

    func setStatus(_ text: String) {
        model.statusLine = text
    }

    /// Marks `index` as the step in progress; everything before it is done.
    func beginStep(at index: Int) {
        withAnimation(.easeOut(duration: 0.25)) {
            for position in model.steps.indices {
                if position < index, model.steps[position].status != .failed { model.steps[position].status = .done }
                if position == index { model.steps[position].status = .active }
                if position > index, model.steps[position].status == .active { model.steps[position].status = .pending }
            }
            model.statusLine = "working…"
        }
    }

    /// A step that was not in the plan: appended and made active.
    func addStep(_ title: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            for position in model.steps.indices where model.steps[position].status == .active {
                model.steps[position].status = .done
            }
            model.steps.append(AgentTaskCardStep(id: model.steps.count, title: title, status: .active))
            model.statusLine = "working…"
        }
    }

    /// Wraps up: the active step becomes done (or failed), the summary is the last line.
    func finish(summary: String, succeeded: Bool, hideAfterSeconds: TimeInterval = 9) {
        withAnimation(.easeOut(duration: 0.3)) {
            for position in model.steps.indices {
                if model.steps[position].status == .active { model.steps[position].status = succeeded ? .done : .failed }
                if succeeded, model.steps[position].status == .pending { model.steps[position].status = .done }
            }
            model.statusLine = summary
            model.isFinished = true
            model.didSucceed = succeeded
        }
        scheduleHide(afterSeconds: hideAfterSeconds)
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in self?.panel?.orderOut(nil) }
        })
    }

    private func scheduleHide(afterSeconds seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    // MARK: - Panel

    private func createPanel() {
        let hosting = NSHostingView(rootView: AgentTaskCardView(model: model, onContentHeightChange: { [weak self] height in
            guard let self, abs(height - self.contentHeight) > 0.5 else { return }
            self.contentHeight = height
            self.layoutPanel()
        }))
        hosting.sizingOptions = []
        let cardPanel = AgentTaskCardPanel(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cardPanel.level = .statusBar
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.hidesOnDeactivate = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.ignoresMouseEvents = true
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        cardPanel.contentView = hosting
        panel = cardPanel
        hostingView = hosting
    }

    /// Fits the panel to its content and pins it to the top-right of the screen under the pointer.
    private func layoutPanel() {
        guard let panel else { return }
        let height = max(80, min(contentHeight, 560))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(x: visible.maxX - Self.screenMargin - Self.cardWidth,
                           y: visible.maxY - Self.screenMargin - height,
                           width: Self.cardWidth, height: height)
        // Set instantly: the content animates its own rows, and an animated frame
        // would clip them mid-flight.
        panel.setFrame(frame, display: true)
    }
}

// MARK: - View

/// Styled like the notch card: black, hairlines, small-caps section labels, the
/// accent only where something is live.
struct AgentTaskCardView: View {
    @ObservedObject var model: AgentTaskCardModel
    let onContentHeightChange: (CGFloat) -> Void
    @ObservedObject private var octoAppearance = OctoAppearance.shared

    private let horizontalPadding: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            card
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { onContentHeightChange(proxy.size.height) }
                            .onChange(of: proxy.size.height) { _, newHeight in onContentHeightChange(newHeight) }
                    }
                )
            Spacer(minLength: 0)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 14)
            taskTitle
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 18)
            hairline
            stepsSection
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
            hairline
            footer
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .frame(width: 340, alignment: .leading)
        .background(cardBackground)
        .environment(\.colorScheme, .dark)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var taskTitle: some View {
        Text("\u{201C}\(model.task)\u{201D}")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.95))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STEPS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .tracking(0.8)
            if model.steps.isEmpty {
                Text(model.isFinished ? "no steps were needed" : "working out the steps…")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                stepRows
            }
        }
    }

    private var stepRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                AgentTaskCardStepRow(step: step, number: index + 1, isLast: index == model.steps.count - 1)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            BuddySquareSpriteView()
            Text("AGENT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .tracking(0.8)
            Spacer()
            statusPill
        }
    }

    /// Live: spinner + "working". Finished: a check (or a warning) + "done" / "stopped".
    private var statusPill: some View {
        HStack(spacing: 6) {
            if !model.isFinished {
                AgentTaskCardSpinner()
                Text(model.steps.isEmpty ? "planning" : "working")
            } else {
                Image(systemName: model.didSucceed ? "checkmark" : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(model.didSucceed ? DS.Colors.overlayCursorBlue : Color(red: 1, green: 0.7, blue: 0.4))
                Text(model.didSucceed ? "done" : "stopped")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundColor(.white.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.25), value: model.isFinished)
    }

    private var footer: some View {
        Text(model.statusLine)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(model.isFinished ? 0.75 : 0.5))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

private struct AgentTaskCardStepRow: View {
    @ObservedObject private var octoAppearance = OctoAppearance.shared
    let step: AgentTaskCardStep
    let number: Int
    let isLast: Bool
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                marker
                    .frame(width: 18, height: 18)
                Text(step.title)
                    .font(.system(size: 12.5, weight: step.status == .active ? .semibold : .regular))
                    .foregroundColor(.white.opacity(step.status == .pending ? 0.5 : (step.status == .active ? 0.95 : 0.78)))
                    .strikethrough(step.status == .failed, color: .white.opacity(0.4))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !isLast {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 44)
            }
        }
    }

    /// Pending: the step number in a ring. Active: the accent, breathing. Done: a check. Failed: a cross.
    @ViewBuilder
    private var marker: some View {
        switch step.status {
        case .pending:
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                Text("\(number)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
        case .active:
            ZStack {
                Circle().fill(DS.Colors.overlayCursorBlue.opacity(0.22))
                Circle().fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing ? 1.0 : 0.7)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.7), radius: 5)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isPulsing = true } }
        case .done:
            ZStack {
                Circle().fill(DS.Colors.overlayCursorBlue.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
            }
        case .failed:
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

private struct AgentTaskCardSpinner: View {
    @ObservedObject private var octoAppearance = OctoAppearance.shared
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { isSpinning = true } }
    }
}
