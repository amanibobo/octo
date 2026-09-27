//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows permissions,
//  the mode picker, backend status, the last-run readout and the coordinate
//  calibration self-test. Dark, rounded, minimal.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            introCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                permissionsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 14)
                modePickerRow
                    .padding(.horizontal, 16)

                Spacer().frame(height: 12)
                servicesSection
                    .padding(.horizontal, 16)

                Spacer().frame(height: 12)
                lastRunSection
                    .padding(.horizontal, 16)

                Spacer().frame(height: 12)
                optionsSection
                    .padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Sounder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Intro copy

    @ViewBuilder
    private var introCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option over a spreadsheet and ask: \"what's weird here?\", \"what drives churn?\", \"fit this\".")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Sounder.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Some permissions were revoked. Grant all four below to keep using Sounder.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, this is Sounder.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("A screen buddy that reads the table on your screen, trains a model on it in seconds, and draws the answer right on the screen.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing runs in the background. Sounder only takes a screenshot when you hold the hotkey, and the table never leaves your machine except as numbers sent to your own analysis backend.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button(action: {
            companionManager.triggerOnboarding()
        }) {
            Text("Start")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(spacing: 2) {
            sectionTitle("PERMISSIONS")
            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow
            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        permissionRow(
            label: "Accessibility",
            subtitle: "Global hotkey and the clipboard fallback",
            iconName: "hand.raised",
            isGranted: companionManager.hasAccessibilityPermission,
            grantAction: { WindowPositionManager.requestAccessibilityPermission() },
            secondaryActionTitle: "Find App",
            secondaryAction: {
                WindowPositionManager.revealAppInFinder()
                WindowPositionManager.openAccessibilitySettings()
            }
        )
    }

    private var screenRecordingPermissionRow: some View {
        permissionRow(
            label: "Screen Recording",
            subtitle: companionManager.hasScreenRecordingPermission
                ? "Only captures when you hold the hotkey"
                : "Quit and reopen after granting",
            iconName: "rectangle.dashed.badge.record",
            isGranted: companionManager.hasScreenRecordingPermission,
            grantAction: { WindowPositionManager.requestScreenRecordingPermission() },
            secondaryActionTitle: nil,
            secondaryAction: nil
        )
    }

    private var screenContentPermissionRow: some View {
        permissionRow(
            label: "Screen Content",
            subtitle: nil,
            iconName: "eye",
            isGranted: companionManager.hasScreenContentPermission,
            grantAction: { companionManager.requestScreenContentPermission() },
            secondaryActionTitle: nil,
            secondaryAction: nil
        )
    }

    private var microphonePermissionRow: some View {
        permissionRow(
            label: "Microphone",
            subtitle: nil,
            iconName: "mic",
            isGranted: companionManager.hasMicrophonePermission,
            grantAction: {
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            },
            secondaryActionTitle: nil,
            secondaryAction: nil
        )
    }

    private func permissionRow(
        label: String,
        subtitle: String?,
        iconName: String,
        isGranted: Bool,
        grantAction: @escaping () -> Void,
        secondaryActionTitle: String?,
        secondaryAction: (() -> Void)?
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle().fill(DS.Colors.success).frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    smallAccentButton("Grant", action: grantAction)
                    if let secondaryActionTitle, let secondaryAction {
                        smallOutlineButton(secondaryActionTitle, action: secondaryAction)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Mode picker

    private var modePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mode")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(SounderMode.allCases) { mode in
                        modeOptionButton(mode)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }

            Text(companionManager.selectedMode.explanation)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeOptionButton(_ mode: SounderMode) -> some View {
        let isSelected = companionManager.selectedMode == mode
        return Button(action: {
            companionManager.setSelectedMode(mode)
        }) {
            Text(mode.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(mode.explanation)
    }

    // MARK: - Services

    private var servicesSection: some View {
        VStack(spacing: 2) {
            sectionTitle("SERVICES")
            serviceRow(
                label: "Analysis service",
                detail: companionManager.isAnalysisServiceReachable ? "reachable" : "unreachable",
                isHealthy: companionManager.isAnalysisServiceReachable,
                iconName: "cpu"
            )
            serviceRow(
                label: "Fireworks proxy",
                detail: companionManager.isWorkerReachable ? "reachable" : "unreachable",
                isHealthy: companionManager.isWorkerReachable,
                iconName: "bolt.horizontal"
            )
            serviceRow(
                label: "Voice",
                detail: "\(companionManager.buddyDictationManager.transcriptionProviderDisplayName) → \(companionManager.speechOutputDisplayName)",
                isHealthy: nil,
                iconName: "waveform"
            )
        }
    }

    private func serviceRow(label: String, detail: String, isHealthy: Bool?, iconName: String) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if let isHealthy {
                    Circle()
                        .fill(isHealthy ? DS.Colors.success : DS.Colors.destructive)
                        .frame(width: 6, height: 6)
                }
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHealthy == false ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Last run

    private var lastRunSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("LAST RUN")
            if let report = companionManager.lastInteractionReport {
                Text("\"\(report.transcript)\"")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(lastRunSummaryLine(report))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(lastRunTimingLine(report))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)

                if let errorMessage = report.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No interaction yet.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastRunSummaryLine(_ report: SounderInteractionReport) -> String {
        var parts = [report.modeUsed]
        if let rows = report.tableRowCount, let columns = report.tableColumnCount {
            parts.append("table \(rows)×\(columns)")
        }
        if let confidence = report.extractionConfidence {
            parts.append("ocr \(Int((confidence * 100).rounded()))%")
        }
        if let source = report.extractionSource {
            parts.append(source)
        }
        if let task = report.analysisTask {
            parts.append(task)
        }
        if let metric = report.metricText {
            parts.append(metric)
        }
        return parts.joined(separator: " · ")
    }

    private func lastRunTimingLine(_ report: SounderInteractionReport) -> String {
        String(
            format: "cap %.2fs  ocr %.2fs  plan %.2fs  model %.2fs  total %.2fs",
            report.captureSeconds, report.ocrSeconds, report.planSeconds, report.analysisSeconds, report.totalSeconds
        )
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(spacing: 2) {
            sectionTitle("OPTIONS")

            toggleRow(
                label: "Clipboard fallback",
                subtitle: "Select-all + copy when OCR is under 90%",
                iconName: "doc.on.clipboard",
                isOn: companionManager.isClipboardFallbackEnabled,
                onChange: { companionManager.setClipboardFallbackEnabled($0) }
            )

            toggleRow(
                label: "On-device transcription",
                subtitle: "Apple Speech, instant. Off = Fireworks Whisper (cloud)",
                iconName: "wifi.slash",
                isOn: companionManager.isOfflineVoiceEnabled,
                onChange: { companionManager.setOfflineVoiceEnabled($0) }
            )

            toggleRow(
                label: "Show Sounder",
                subtitle: "Keep the cursor buddy visible between questions",
                iconName: "cursorarrow",
                isOn: companionManager.isClickyCursorEnabled,
                onChange: { companionManager.setClickyCursorEnabled($0) }
            )

            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Calibrate overlay")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text("Outlines every text line it can read for 5s")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                Spacer()
                smallOutlineButton(companionManager.isRunningCalibration ? "Running…" : "Run") {
                    companionManager.runOverlayCalibration()
                }
                .disabled(companionManager.isRunningCalibration)
            }
            .padding(.vertical, 4)
        }
    }

    private func toggleRow(label: String, subtitle: String, iconName: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Sounder")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            Button(action: {
                companionManager.refreshServiceHealth()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Recheck services")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Small controls

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    private func smallAccentButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func smallOutlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Visual helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle: return "Active"
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .responding: return "Responding"
        }
    }
}
