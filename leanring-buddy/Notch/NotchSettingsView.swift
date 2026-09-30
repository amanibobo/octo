//
//  NotchSettingsView.swift
//  leanring-buddy
//
//  Settings page inside the island: vertical tabs on the left (Hotkey, Voice,
//  Memory, Buddy, Services, About), the chosen section on the right.
//

import AppKit
import SwiftUI

struct NotchSettingsView: View {
    @ObservedObject private var octoAppearance = OctoAppearance.shared
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case hotkey = "Hotkey"
        case voice = "Voice"
        case memory = "Memory"
        case buddy = "Buddy"
        case services = "Services"
        case about = "About"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .hotkey: return "keyboard"
            case .voice: return "waveform"
            case .memory: return "clock.arrow.circlepath"
            case .buddy: return "face.smiling"
            case .services: return "network"
            case .about: return "info.circle"
            }
        }
    }

    @Environment(\.notchCardWidth) private var cardWidth
    @State private var section: Section = .hotkey
    @State private var isRecordingPulseOn = false
    private let horizontalPadding: CGFloat = 22
    private let sidebarWidth: CGFloat = 122

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchPageHeader(title: "Settings", subtitle: section.rawValue, onBack: onBack)
                .padding(.top, 14)
                .padding(.horizontal, horizontalPadding)

            HStack(alignment: .top, spacing: 14) {
                sidebar
                    .frame(width: sidebarWidth)
                    .frame(minHeight: 300)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    )
                ScrollView(.vertical, showsIndicators: false) {
                    sectionContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                        .id(section)
                        .transition(.opacity)
                }
                .frame(maxHeight: 460)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 16)
        }
        .frame(width: cardWidth)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases.filter { $0 != .about }) { item in
                sidebarItem(item)
            }
            Spacer(minLength: 8)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 6)
            sidebarItem(.about)
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarItem(_ item: Section) -> some View {
        let isSelected = section == item
        return Button(action: { withAnimation(.easeOut(duration: 0.18)) { section = item } }) {
            HStack(spacing: 9) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.overlayCursorBlue : .white.opacity(0.5))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.62))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .hotkey: hotkeySection
        case .voice: voiceSection
        case .memory: memorySection
        case .buddy: buddySection
        case .services: servicesSection
        case .about: aboutSection
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Hotkey", subtitle: "The keys you hold while speaking.",
                                  tip: "Record your own chord: modifiers alone, or modifiers plus one key. Esc cancels a recording.")
            SettingsGroup {
                SettingsRow {
                    HStack(spacing: 10) {
                        hotkeyDisplay
                        Spacer()
                        if companionManager.isRecordingHotkey {
                            NotchPillButton(title: "Cancel", systemImage: "xmark") { companionManager.cancelRecordingHotkey() }
                        } else {
                            NotchPillButton(title: "Record", systemImage: "record.circle", isProminent: true) { companionManager.beginRecordingHotkey() }
                        }
                    }
                }
                SettingsRow(isLast: true) {
                    HStack(spacing: 8) {
                        Text(companionManager.isRecordingHotkey
                             ? "Press the keys you want, then let go."
                             : "Hold to talk, release to send.")
                            .font(.system(size: 11.5))
                            .foregroundColor(companionManager.isRecordingHotkey ? DS.Colors.overlayCursorBlue.opacity(0.9) : .white.opacity(0.45))
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
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Voice", subtitle: "How Octo hears you and talks back.",
                                  tip: "On-device transcription is instant and private; the cloud path is a fallback. Speech out is ElevenLabs.")
            SettingsGroup {
                SettingsRow {
                    NotchToggleRow(title: "On-device transcription", detail: "Apple Speech, instant. Off uses Fireworks Whisper.",
                                   isOn: companionManager.isOfflineVoiceEnabled) { companionManager.setOfflineVoiceEnabled($0) }
                }
                SettingsRow {
                    NotchToggleRow(title: "Captions", detail: "Show what Octo says next to it, word by word.",
                                   isOn: companionManager.isCaptionEnabled) { companionManager.setCaptionEnabled($0) }
                }
                SettingsRow(isLast: true) {
                    NotchInfoRow(title: "Speech", value: companionManager.speechOutputDisplayName)
                }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Memory", subtitle: "What Octo keeps in mind.",
                                  tip: "Screen rewind stays in memory and is dropped when the app quits; nothing is written to disk. Pinned context lives in the paperclip page.")
            SettingsGroup {
                SettingsRow {
                    NotchToggleRow(title: "Screen rewind", detail: "Keeps the last 15 minutes as low-res frames in memory. Ask \u{201C}what did that error say five minutes ago?\u{201D}",
                                   isOn: companionManager.isScreenRewindEnabled) { companionManager.setScreenRewindEnabled($0) }
                }
                SettingsRow {
                    NotchToggleRow(title: "Dwell to ask", detail: "Hold the hotkey still over something for a second and Octo explains it.",
                                   isOn: companionManager.isDwellEnabled) { companionManager.setDwellEnabled($0) }
                }
                SettingsRow(isLast: true) {
                    NotchInfoRow(title: "Pinned context", value: "\(companionManager.userContextStore.items.count) items")
                }
            }
        }
    }

    private var buddySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Buddy", subtitle: "The companion on your cursor, and how the Agent behaves.")
            SettingsGroup {
                SettingsRow {
                    OctoColorRow()
                }
                SettingsRow {
                    NotchToggleRow(title: "Always visible", detail: "Off shows the buddy only while it works.",
                                   isOn: companionManager.isClickyCursorEnabled) { companionManager.setClickyCursorEnabled($0) }
                }
                SettingsRow {
                    NotchToggleRow(title: "Clipboard fallback", detail: "Copy a table when reading it off the screen is unsure.",
                                   isOn: companionManager.isClipboardFallbackEnabled) { companionManager.setClipboardFallbackEnabled($0) }
                }
                SettingsRow(isLast: true) {
                    NotchToggleRow(title: "Rehearse before acting", detail: "Agent tasks are acted out by a ghost cursor first; say \u{201C}go\u{201D} to run.",
                                   isOn: companionManager.isAgentRehearsalEnabled) { companionManager.setAgentRehearsalEnabled($0) }
                }
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Services", subtitle: "Everything cloud-side goes through one proxy that holds the keys.",
                                  tip: "Voice and screen reading are on-device. The proxy talks to the language model; clinical rules run on their own service.")
            SettingsGroup {
                SettingsRow { NotchInfoRow(title: "Model", value: companionManager.chatModelDisplayName) }
                SettingsRow { NotchInfoRow(title: "Proxy", value: companionManager.isWorkerReachable ? "Connected" : "Unreachable", isBad: !companionManager.isWorkerReachable, showsStatusDot: true) }
                SettingsRow { NotchInfoRow(title: "Clinical rules", value: companionManager.isAnalysisServiceReachable ? "Connected" : "Unreachable", isBad: !companionManager.isAnalysisServiceReachable, showsStatusDot: true) }
                SettingsRow { NotchInfoRow(title: "Decisions (Jev)", value: companionManager.isJevConfigured ? "Connected" : "Not configured", isBad: false, showsStatusDot: companionManager.isJevConfigured) }
                SettingsRow(isLast: true) { NotchInfoRow(title: "Transcription", value: companionManager.buddyDictationManager.transcriptionProviderDisplayName) }
            }
            HStack(spacing: 8) {
                NotchPillButton(title: "Calibrate overlay", systemImage: "scope") { companionManager.runOverlayCalibration() }
                NotchInfoTip(text: "Draws a thin box around every line Octo can read for a few seconds. If the boxes sit on the text, the drawing is lined up.", width: 200)
                Spacer()
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BuddySquareSpriteView()
                    .scaleEffect(1.8)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Octo")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · built at HackGT 13")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            SettingsGroup {
                SettingsRow(isLast: true) {
                    Text("A companion that lives in the notch and on your cursor. It reads the screen on-device, answers out loud, and draws where the data is. In Rx mode only concept IDs ever leave the Mac.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                NotchPillButton(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(URL(string: "https://github.com/amanibobo/octo")!) }
                NotchPillButton(title: "Quit Octo", systemImage: "power") { NSApp.terminate(nil) }
            }
        }
    }

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

}


// MARK: - Grouped form pieces

/// A macOS-settings-style group: rounded panel, rows separated by inset hairlines.
/// Octo's colour: a row of swatches; the picked one wears a ring and everything repaints at once.
private struct OctoColorRow: View {
    @ObservedObject private var octoAppearance = OctoAppearance.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Colour")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Text("Octo's body, the notch, and every drawing.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                ForEach(OctoAccent.allCases) { accent in
                    OctoColorSwatch(accent: accent, isSelected: octoAppearance.accent == accent) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { octoAppearance.accent = accent }
                    }
                }
            }
        }
    }
}

private struct OctoColorSwatch: View {
    let accent: OctoAccent
    let isSelected: Bool
    let onPick: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            Circle()
                .fill(accent.color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.95 : (isHovering ? 0.4 : 0)), lineWidth: 2)
                        .frame(width: 20, height: 20)
                )
                .scaleEffect(isSelected || isHovering ? 1.12 : 1)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovering)
        .help(accent.displayName)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
        )
    }
}

private struct SettingsRow<Content: View>: View {
    var isLast: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            if !isLast {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String
    var tip: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let tip { NotchInfoTip(text: tip) }
            }
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .zIndex(2)
    }
}
