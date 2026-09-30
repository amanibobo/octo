//
//  NotchSettingsView.swift
//  leanring-buddy
//
//  Settings page inside the island: hotkey, voice, memory, buddy, services.
//

import SwiftUI

struct NotchSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void

    private let horizontalPadding: CGFloat = 22
    @State private var isRecordingPulseOn = false

    /// Key caps of the current chord; pulses while a new one is being recorded.
    private var hotkeyDisplay: some View {
        HStack(spacing: 5) {
            if companionManager.isRecordingHotkey {
                Text("listening…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                    .opacity(isRecordingPulseOn ? 1 : 0.45)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isRecordingPulseOn = true }
                    }
                    .onDisappear { isRecordingPulseOn = false }
            } else {
                ForEach(Array(companionManager.pushToTalkChord.keyCapsuleLabels.enumerated()), id: \.offset) { index, keyLabel in
                    if index > 0 {
                        Text("+").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.35))
                    }
                    Text(keyLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        )
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchPageHeader(title: "Settings", subtitle: "Hotkey, voice, memory and services", onBack: onBack)
                .padding(.top, 14)

            NotchSectionCard(title: "Hotkey", systemImage: "keyboard") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        hotkeyDisplay
                        Spacer()
                        if companionManager.isRecordingHotkey {
                            NotchPillButton(title: "Cancel", systemImage: "xmark") { companionManager.cancelRecordingHotkey() }
                        } else {
                            NotchPillButton(title: "Record", systemImage: "record.circle", isProminent: true) { companionManager.beginRecordingHotkey() }
                        }
                    }
                    HStack(spacing: 8) {
                        Text(companionManager.isRecordingHotkey
                             ? "Press the keys you want, then let go. Modifiers alone, or modifiers plus one key. Esc cancels."
                             : "Hold to talk, release to send.")
                            .font(.system(size: 11))
                            .foregroundColor(companionManager.isRecordingHotkey ? DS.Colors.overlayCursorBlue.opacity(0.9) : .white.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !companionManager.isRecordingHotkey, companionManager.pushToTalkChord != .controlOption {
                            Button("Reset to ctrl + option") { companionManager.setPushToTalkChord(.controlOption) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.9))
                                .pointerCursor()
                        }
                    }
                }
            }

            NotchSectionCard(title: "Voice", systemImage: "waveform") {
                VStack(spacing: 10) {
                    NotchToggleRow(title: "On-device transcription", detail: "Apple Speech, instant. Off uses Fireworks Whisper.",
                                   isOn: companionManager.isOfflineVoiceEnabled) { companionManager.setOfflineVoiceEnabled($0) }
                    NotchToggleRow(title: "Captions", detail: "Show what Octo says next to it.",
                                   isOn: companionManager.isCaptionEnabled) { companionManager.setCaptionEnabled($0) }
                    NotchInfoRow(title: "Speech", value: companionManager.speechOutputDisplayName)
                }
            }

            NotchSectionCard(title: "Memory", systemImage: "clock.arrow.circlepath") {
                VStack(spacing: 10) {
                    NotchToggleRow(title: "Screen rewind", detail: "Keeps the last 15 minutes as low-res frames in memory, never on disk. Ask \u{201C}what did that error say five minutes ago?\u{201D}",
                                   isOn: companionManager.isScreenRewindEnabled) { companionManager.setScreenRewindEnabled($0) }
                    NotchToggleRow(title: "Dwell to ask", detail: "Hold the hotkey still over something for a second and Octo explains it, no need to speak.",
                                   isOn: companionManager.isDwellEnabled) { companionManager.setDwellEnabled($0) }
                }
            }

            NotchSectionCard(title: "Buddy", systemImage: "face.smiling") {
                VStack(spacing: 10) {
                    NotchToggleRow(title: "Always visible", detail: "Off shows the buddy only while it works.",
                                   isOn: companionManager.isClickyCursorEnabled) { companionManager.setClickyCursorEnabled($0) }
                    NotchToggleRow(title: "Clipboard fallback", detail: "Copy a table when reading it off the screen is unsure.",
                                   isOn: companionManager.isClipboardFallbackEnabled) { companionManager.setClipboardFallbackEnabled($0) }
                    NotchToggleRow(title: "Rehearse before acting", detail: "Off by default. On, agent tasks are acted out by a ghost cursor first; say \u{201C}go\u{201D} to run. Or say \u{201C}rehearse…\u{201D} for one task.",
                                   isOn: companionManager.isAgentRehearsalEnabled) { companionManager.setAgentRehearsalEnabled($0) }
                }
            }

            NotchSectionCard(title: "Services", systemImage: "network") {
                VStack(spacing: 8) {
                    NotchInfoRow(title: "Model", value: companionManager.chatModelDisplayName)
                    NotchInfoRow(title: "Proxy", value: companionManager.isWorkerReachable ? "connected" : "unreachable", isBad: !companionManager.isWorkerReachable, showsStatusDot: true)
                    NotchInfoRow(title: "Clinical rules", value: companionManager.isAnalysisServiceReachable ? "connected" : "unreachable", isBad: !companionManager.isAnalysisServiceReachable, showsStatusDot: true)
                    HStack(spacing: 8) {
                        NotchPillButton(title: "Calibrate overlay", systemImage: "scope") { companionManager.runOverlayCalibration() }
                        Spacer()
                        NotchPillButton(title: "Quit Octo", systemImage: "power") { NSApp.terminate(nil) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(width: NotchIslandState.expandedWidth)
    }
}
