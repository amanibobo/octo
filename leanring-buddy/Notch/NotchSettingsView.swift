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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchPageHeader(title: "Settings", subtitle: "Hotkey, voice, memory and services", onBack: onBack)
                .padding(.top, 14)

            NotchSectionCard(title: "Hotkey", systemImage: "keyboard") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Hold to talk, release to send. Circle with the cursor to focus a question.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        ForEach(BuddyPushToTalkShortcut.ShortcutOption.allCases, id: \.self) { option in
                            NotchPillButton(title: option.displayText, isSelected: companionManager.pushToTalkShortcut == option) {
                                companionManager.setPushToTalkShortcut(option)
                            }
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
