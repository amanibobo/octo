//
//  NotchPanelContentView.swift
//  leanring-buddy
//
//  The card that unfurls from the notch. Deliberately sparse: one status line,
//  one mode control, one hint, three status dots, the last run, a small row of
//  toggles. Everything secondary lives in tooltips.
//

import SwiftUI

struct NotchPanelContentView: View {
    @ObservedObject var companionManager: CompanionManager

    private let horizontalPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 16)

            modeControl
                .padding(.horizontal, horizontalPadding)

            Text("Hold ⌃ ⌥ and talk. Circle with the cursor to focus.")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.45))
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
        .frame(width: 340)
    }

    // MARK: - Pieces

    private var statusLine: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                statusEye
                statusEye
            }
            Text("Sounder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            HStack(spacing: 6) {
                serviceDot(isHealthy: companionManager.isWorkerReachable, label: "Claude")
                serviceDot(isHealthy: companionManager.isAnalysisServiceReachable, label: "Models")
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
                Button(action: { companionManager.setSelectedMode(mode) }) {
                    Text(mode.displayName)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
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
                    .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                if let error = report.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.4))
                        .lineLimit(2)
                }
            }
        } else {
            Text("Nothing yet. Try \u{201C}what's on my screen?\u{201D}")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerToggle(icon: "doc.on.clipboard", label: "Clipboard fallback", isOn: companionManager.isClipboardFallbackEnabled) {
                companionManager.setClipboardFallbackEnabled(!companionManager.isClipboardFallbackEnabled)
            }
            footerToggle(icon: "waveform", label: "On-device transcription", isOn: companionManager.isOfflineVoiceEnabled) {
                companionManager.setOfflineVoiceEnabled(!companionManager.isOfflineVoiceEnabled)
            }
            footerToggle(icon: "cursorarrow", label: "Show buddy", isOn: companionManager.isClickyCursorEnabled) {
                companionManager.setClickyCursorEnabled(!companionManager.isClickyCursorEnabled)
            }
            footerToggle(icon: "scope", label: "Calibrate overlay", isOn: false) {
                companionManager.runOverlayCalibration()
            }
            Spacer()
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Quit Sounder")
        }
    }

    /// Icon-only so the row never truncates; the label lives in the tooltip.
    private func footerToggle(icon: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isOn ? .white : .white.opacity(0.45))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Color.white.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(label + (isOn ? " · on" : ""))
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
