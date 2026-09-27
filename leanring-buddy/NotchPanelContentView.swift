//
//  NotchPanelContentView.swift
//  leanring-buddy
//
//  The card that unfurls from the notch. Deliberately sparse: one status line,
//  one mode control with a one-line description of the chosen mode, the last
//  run, and a footer with the hotkey hint and a settings button. Everything
//  else lives in NotchSettingsView.
//

import SwiftUI

struct NotchPanelContentView: View {
    @ObservedObject var companionManager: CompanionManager
    let onOpenSettings: () -> Void

    private let horizontalPadding: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 16)

            modeControl
                .padding(.horizontal, horizontalPadding)

            modeDescription
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)

            hairline
                .padding(.top, 16)

            lastRun
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)

            hairline

            footer
                .padding(.horizontal, horizontalPadding - 6)
                .padding(.vertical, 10)
        }
        .frame(width: NotchIslandState.expandedWidth)
    }

    // MARK: - Pieces

    private var statusLine: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                statusEye
                statusEye
            }
            Text("Octo")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            HStack(spacing: 6) {
                serviceDot(isHealthy: companionManager.isWorkerReachable, label: "Claude")
                serviceDot(isHealthy: companionManager.isAnalysisServiceReachable, label: "Clinical rules")
                serviceDot(isHealthy: true, label: "Voice · \(companionManager.buddyDictationManager.transcriptionProviderDisplayName)")
            }
            Text(statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private var statusEye: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: 7, height: 8)
    }

    private func serviceDot(isHealthy: Bool, label: String) -> some View {
        Circle()
            .fill(isHealthy ? DS.Colors.overlayCursorBlue : Color(red: 0.95, green: 0.35, blue: 0.3))
            .frame(width: 6, height: 6)
            .help(label + (isHealthy ? " · connected" : " · unreachable"))
    }

    private var modeControl: some View {
        HStack(spacing: 2) {
            ForEach(SounderMode.allCases) { mode in
                let isSelected = companionManager.selectedMode == mode
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        companionManager.setSelectedMode(mode)
                    }
                }) {
                    Text(mode.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isSelected ? DS.Colors.overlayCursorBlue : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(mode.explanation)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// One sentence on what the selected mode does, plus an example question.
    private var modeDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(companionManager.selectedMode.explanation)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Text("Try: \u{201C}\(companionManager.selectedMode.exampleQuestion)\u{201D}")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(companionManager.selectedMode)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    @ViewBuilder
    private var lastRun: some View {
        if let report = companionManager.lastInteractionReport {
            VStack(alignment: .leading, spacing: 5) {
                Text("\u{201C}\(report.transcript)\u{201D}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(report.modeUsed)
                    Text("·").opacity(0.4)
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
            Text("Nothing yet. Hold the hotkey and ask \u{201C}what's on my screen?\u{201D}")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(companionManager.pushToTalkShortcut.keyCapsuleLabels, id: \.self) { keyLabel in
                    Text(keyLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
                }
                Text("hold to talk · circle to focus")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 4)
            }
            .padding(.leading, 6)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings · hotkey, voice, buddy")
        }
    }

    private var statusText: String {
        if !companionManager.isOverlayVisible { return "Ready" }
        switch companionManager.voiceState {
        case .idle: return "Active"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }
}
