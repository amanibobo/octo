//
//  NotchPanelContentView.swift
//  leanring-buddy
//
//  The card that unfolds from the notch. A hero row with the buddy and its
//  state, a mode control with a live vignette of what the chosen mode does,
//  the last run, and a footer with the hotkey and the context and settings
//  buttons. Everything else lives in the settings and context pages.
//

import SwiftUI

struct NotchPanelContentView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var userContextStore: UserContextStore
    let onOpenSettings: () -> Void
    let onOpenContext: () -> Void

    private let horizontalPadding: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroRow
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 18)

            modeControl
                .padding(.horizontal, horizontalPadding)

            modeShowcase
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)

            hairline
                .padding(.top, 18)

            lastRun
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)

            hairline

            footer
                .padding(.horizontal, horizontalPadding - 6)
                .padding(.vertical, 12)
        }
        .frame(width: NotchIslandState.expandedWidth)
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
                Text("Octo")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 7) {
                serviceDot(isHealthy: companionManager.isWorkerReachable, label: "Claude")
                serviceDot(isHealthy: companionManager.isAnalysisServiceReachable, label: "Clinical rules")
                serviceDot(isHealthy: true, label: "Voice · \(companionManager.buddyDictationManager.transcriptionProviderDisplayName)")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .help("Services")
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
            if !companionManager.isOverlayVisible { return "Ready · hold \(companionManager.pushToTalkShortcut.displayText)" }
            return "Watching your screen · hold \(companionManager.pushToTalkShortcut.displayText)"
        }
    }

    private func serviceDot(isHealthy: Bool, label: String) -> some View {
        Circle()
            .fill(isHealthy ? DS.Colors.overlayCursorBlue : Color(red: 0.95, green: 0.35, blue: 0.3))
            .frame(width: 6, height: 6)
            .shadow(color: (isHealthy ? DS.Colors.overlayCursorBlue : Color.red).opacity(0.7), radius: 3)
            .help(label + (isHealthy ? " · connected" : " · unreachable"))
    }

    // MARK: - Modes

    private var modeControl: some View {
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
    }

    /// Vignette of the selected mode in action next to what it does.
    private var modeShowcase: some View {
        HStack(alignment: .top, spacing: 14) {
            NotchModeVignetteView(mode: companionManager.selectedMode)
                .id(companionManager.selectedMode)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 5) {
                Text(companionManager.selectedMode.explanation)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Try: \u{201C}\(companionManager.selectedMode.exampleQuestion)\u{201D}")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(companionManager.selectedMode)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: - Last run

    @ViewBuilder
    private var lastRun: some View {
        if let report = companionManager.lastInteractionReport {
            VStack(alignment: .leading, spacing: 5) {
                Text("\u{201C}\(report.transcript)\u{201D}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(2)
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
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
                if let error = report.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.4))
                        .lineLimit(2)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.8))
                Text("Nothing yet. Hold the hotkey and ask \u{201C}what's on my screen?\u{201D}")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(companionManager.pushToTalkShortcut.keyCapsuleLabels, id: \.self) { keyLabel in
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
                Text("hold to talk · circle to focus · rest to ask")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 4)
                    .lineLimit(1)
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
                .background(footerButtonBackground)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Context · notes, links and images Octo keeps in mind")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 30, height: 28)
                    .background(footerButtonBackground)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings · hotkey, voice, memory, buddy")
        }
    }

    private var footerButtonBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
