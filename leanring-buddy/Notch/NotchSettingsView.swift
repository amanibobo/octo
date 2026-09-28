//
//  NotchSettingsView.swift
//  leanring-buddy
//
//  Settings page inside the island: hotkey, voice, buddy and drawing options.
//

import SwiftUI

struct NotchSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void

    private let horizontalPadding: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 14)

            settingsGroup("Hotkey") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold to talk. Release to send.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.45))
                    HStack(spacing: 4) {
                        ForEach(BuddyPushToTalkShortcut.ShortcutOption.allCases, id: \.self) { option in
                            let isSelected = companionManager.pushToTalkShortcut == option
                            Button(action: { companionManager.setPushToTalkShortcut(option) }) {
                                Text(option.displayText)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? .black : .white.opacity(0.75))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(isSelected ? DS.Colors.overlayCursorBlue : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            settingsGroup("Voice") {
                toggleRow("On-device transcription", detail: "Apple Speech, instant. Off uses Fireworks Whisper.",
                          isOn: companionManager.isOfflineVoiceEnabled) { companionManager.setOfflineVoiceEnabled($0) }
                toggleRow("Captions", detail: "Show what the buddy says next to it.",
                          isOn: companionManager.isCaptionEnabled) { companionManager.setCaptionEnabled($0) }
                infoRow("Speech", value: companionManager.speechOutputDisplayName)
            }

            settingsGroup("Buddy") {
                toggleRow("Always visible", detail: "Off shows the buddy only while it works.",
                          isOn: companionManager.isClickyCursorEnabled) { companionManager.setClickyCursorEnabled($0) }
                toggleRow("Clipboard fallback", detail: "Copy a table when reading it off the screen is unsure.",
                          isOn: companionManager.isClipboardFallbackEnabled) { companionManager.setClipboardFallbackEnabled($0) }
            }

            settingsGroup("Memory") {
                toggleRow("Screen rewind", detail: "Keeps the last 15 minutes as low-res frames in memory, never on disk. Ask \u{201C}what did that error say five minutes ago?\u{201D}",
                          isOn: companionManager.isScreenRewindEnabled) { companionManager.setScreenRewindEnabled($0) }
                toggleRow("Dwell to ask", detail: "Hold the hotkey still over something for a second and Octo explains it, no need to speak.",
                          isOn: companionManager.isDwellEnabled) { companionManager.setDwellEnabled($0) }
            }

            settingsGroup("Services") {
                infoRow("Model", value: companionManager.chatModelDisplayName)
                infoRow("Proxy", value: companionManager.isWorkerReachable ? "connected" : "unreachable", isBad: !companionManager.isWorkerReachable)
                infoRow("Clinical rules", value: companionManager.isAnalysisServiceReachable ? "connected" : "unreachable", isBad: !companionManager.isAnalysisServiceReachable)
                HStack {
                    Spacer()
                    Button("Calibrate overlay") { companionManager.runOverlayCalibration() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.overlayCursorBlue)
                        .pointerCursor()
                    Button("Quit Octo") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .pointerCursor()
                        .padding(.leading, 14)
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 16)
        }
        .frame(width: NotchIslandState.expandedWidth)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
                .tracking(0.8)
            content()
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 16)
    }

    private func toggleRow(_ title: String, detail: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.overlayCursorBlue)
                .scaleEffect(0.8)
                .pointerCursor()
        }
    }

    private func infoRow(_ title: String, value: String, isBad: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Text(value)
                .font(.system(size: 11.5))
                .foregroundColor(isBad ? Color(red: 0.95, green: 0.45, blue: 0.4) : .white.opacity(0.5))
                .lineLimit(1)
        }
    }
}
