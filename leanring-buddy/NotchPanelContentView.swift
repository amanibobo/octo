//
//  NotchPanelContentView.swift
//  leanring-buddy
//
//  The card that unfolds from the notch. Compact: hero row, mode control with a
//  live vignette, last run, footer. Large (the expand button): the same, wider,
//  with a bigger vignette and a short history of recent runs. Small "i" tips
//  explain each area on hover.
//

import SwiftUI

struct NotchPanelContentView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var userContextStore: UserContextStore
    let isLarge: Bool
    let onOpenSettings: () -> Void
    let onOpenContext: () -> Void
    let onToggleLarge: () -> Void

    @Environment(\.notchCardWidth) private var cardWidth
    private let horizontalPadding: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroRow
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .zIndex(3)

            modeControl
                .padding(.horizontal, horizontalPadding)
                .zIndex(2)

            modeShowcase
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)

            hairline
                .padding(.top, 18)

            if isLarge {
                quickActions
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 14)
                hairline
                recentRuns
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 14)
            } else {
                lastRun
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 14)
            }

            hairline

            footer
                .padding(.horizontal, horizontalPadding - 6)
                .padding(.vertical, 12)
        }
        .frame(width: cardWidth)
    }

    // MARK: - Hero

    private var heroRow: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue.opacity(isBusy ? 0.28 : 0.14))
                    .frame(width: 46, height: 46)
                    .blur(radius: 8)
                BuddySquareSpriteView()
                    .scaleEffect(1.6)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Octo")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    NotchInfoTip(text: "Octo reads whatever is on your screen and answers out loud. Hold the hotkey, ask, let go. Circle something with the cursor while holding to ask about just that. Rest the cursor on something for a second to have it explained without speaking.")
                }
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            NotchIconButton(systemImage: isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            isActive: isLarge, help: isLarge ? "Compact card" : "Larger card", action: onToggleLarge)
        }
    }

    private var isBusy: Bool {
        companionManager.voiceState != .idle
    }

    private var statusLine: String {
        switch companionManager.voiceState {
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking"
        case .idle:
            if !companionManager.isWorkerReachable { return "Proxy unreachable · see Settings › Services" }
            if !companionManager.isOverlayVisible { return "Ready" }
            return "Watching your screen"
        }
    }

    // MARK: - Modes

    private var modeControl: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(SounderMode.allCases) { mode in
                    let isSelected = companionManager.selectedMode == mode
                    Button(action: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            companionManager.setSelectedMode(mode)
                        }
                    }) {
                        Text(mode.displayName)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .black : .white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                ZStack {
                                    if isSelected {
                                        Capsule()
                                            .fill(LinearGradient(colors: [DS.Colors.green400, DS.Colors.green500], startPoint: .top, endPoint: .bottom))
                                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.45), radius: 8, y: 2)
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(mode.explanation)
                }
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            NotchInfoTip(text: "Modes. Auto picks per question. General answers anything on screen and points. Rx reads a chart, checks interactions and dosing, and pulls evidence; only concept IDs leave the Mac. Agent does the task on this Mac, step by step.", width: 250)
        }
    }

    /// Vignette of the selected mode in action next to what it does.
    private var modeShowcase: some View {
        HStack(alignment: .top, spacing: 14) {
            NotchModeVignetteView(mode: companionManager.selectedMode)
                .scaleEffect(isLarge ? 1.35 : 1, anchor: .topLeading)
                .frame(width: isLarge ? 200 : 148, height: isLarge ? 124 : 92, alignment: .topLeading)
                .id(companionManager.selectedMode)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 5) {
                Text(companionManager.selectedMode.explanation)
                    .font(.system(size: isLarge ? 13 : 12.5))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Try: \u{201C}\(companionManager.selectedMode.exampleQuestion)\u{201D}")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if isLarge {
                    Text(Self.extras(for: companionManager.selectedMode))
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .id(companionManager.selectedMode)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func extras(for mode: SounderMode) -> String {
        switch mode {
        case .automatic: return "Also anywhere: \u{201C}translate this\u{201D}, \u{201C}read this to me\u{201D}, \u{201C}what did that error say five minutes ago?\u{201D}, circle a table and \u{201C}copy as csv\u{201D}."
        case .general: return "Circle text and say \u{201C}clearer\u{201D} to rewrite it, \u{201C}make this readable\u{201D} for structure, or ask how something works for a sketch."
        case .clinical: return "Circle two drugs and ask about them together. \u{201C}What's new for atrial fibrillation?\u{201D} pulls a paper card."
        case .agent: return "Say \u{201C}rehearse\u{201D} first to watch a ghost run through the plan before anything happens."
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: - Large-card extras

    private struct QuickAction: Identifiable {
        let id: String
        let title: String
        let command: String
    }

    private static let quickActionsList: [QuickAction] = [
        QuickAction(id: "read", title: "Read this to me", command: "read this to me"),
        QuickAction(id: "readable", title: "Make readable", command: "make this readable"),
        QuickAction(id: "translate", title: "Translate", command: "translate this to english"),
        QuickAction(id: "screen", title: "What's on screen", command: "what's on my screen?"),
        QuickAction(id: "camera", title: "Camera", command: "camera, what am i holding?"),
        QuickAction(id: "rewind", title: "Rewind a minute", command: "what was on my screen a minute ago?"),
    ]

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("QUICK ACTIONS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(0.8)
                NotchInfoTip(text: "One click runs the command on whatever is on screen right now, the same as saying it.", width: 200)
            }
            .zIndex(2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Self.quickActionsList) { action in
                    QuickActionButton(title: action.title, isEnabled: companionManager.voiceState == .idle) {
                        companionManager.askByText(action.command)
                    }
                }
            }
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var lastRun: some View {
        if let report = companionManager.lastInteractionReport {
            runRow(report, isFirst: true)
        } else {
            emptyRuns
        }
    }

    @ViewBuilder
    private var recentRuns: some View {
        if companionManager.recentInteractionReports.isEmpty {
            emptyRuns
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .tracking(0.8)
                    NotchInfoTip(text: "Your last few questions, which mode handled each, and how long it took. Timings are capture, reading the screen, and the model.", width: 210)
                }
                ForEach(Array(companionManager.recentInteractionReports.prefix(6).enumerated()), id: \.offset) { index, report in
                    runRow(report, isFirst: index == 0)
                }
            }
        }
    }

    private var emptyRuns: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.8))
            Text("Nothing yet. Hold the hotkey and ask \u{201C}what's on my screen?\u{201D}")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func runRow(_ report: SounderInteractionReport, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\u{201C}\(report.transcript)\u{201D}")
                .font(.system(size: isFirst ? 13 : 12, weight: .medium))
                .foregroundColor(.white.opacity(isFirst ? 0.88 : 0.7))
                .lineLimit(isLarge ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(report.modeUsed)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.overlayCursorBlue.opacity(0.14)))
                Text(String(format: "%.1fs", report.totalSeconds))
                if let metric = report.metricText {
                    Text("·").opacity(0.4)
                    Text(metric).lineLimit(1)
                }
                if isLarge {
                    Spacer()
                    Text(report.completedAt, style: .time)
                }
            }
            .font(.system(size: 11.5))
            .foregroundColor(.white.opacity(0.45))
            if let error = report.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.4))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(companionManager.pushToTalkChord.keyCapsuleLabels, id: \.self) { keyLabel in
                    Text(keyLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        )
                }
                Text(isLarge ? "hold to talk · circle to focus · rest to ask" : "hold to talk")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 4)
                    .lineLimit(1)
                NotchInfoTip(text: "Hold the keys and speak; release to send. While holding: draw a circle to scope the question to that area, or hold still over something for a second to have it explained. Change the keys under Settings › Hotkey.", width: 230)
            }
            .padding(.leading, 6)
            Spacer()
            Button(action: onOpenContext) {
                HStack(spacing: 5) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                    if !userContextStore.items.isEmpty {
                        Text("\(userContextStore.items.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundColor(userContextStore.items.isEmpty ? .white.opacity(0.65) : DS.Colors.overlayCursorBlue)
                .frame(height: 28)
                .padding(.horizontal, userContextStore.items.isEmpty ? 9 : 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Context · notes, links and images Octo keeps in mind")
            NotchIconButton(systemImage: "gearshape", help: "Settings", action: onOpenSettings)
        }
    }
}

/// A quiet capsule that brightens on hover and presses down slightly, in the
/// same glass language as the mode control.
private struct QuickActionButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(isEnabled ? .white.opacity(isHovering ? 1 : 0.85) : .white.opacity(0.35))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.white.opacity(isHovering && isEnabled ? 0.14 : 0.07))
                    .overlay(Capsule().stroke(isHovering && isEnabled ? DS.Colors.overlayCursorBlue.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1))
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(isHovering && isEnabled ? 0.25 : 0), radius: 8, y: 2)
            )
            .scaleEffect(isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .pointerCursor()
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if isEnabled { isPressed = true } }
                    .onEnded { _ in
                        isPressed = false
                        if isEnabled { action() }
                    }
            )
    }
}
