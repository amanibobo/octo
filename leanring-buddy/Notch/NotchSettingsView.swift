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
                ScrollView(.vertical, showsIndicators: false) {
                    sectionContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }
                .frame(maxHeight: 440)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 16)
        }
        .frame(width: cardWidth)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { item in
                let isSelected = section == item
                Button(action: { withAnimation(.easeOut(duration: 0.18)) { section = item } }) {
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? DS.Colors.overlayCursorBlue.opacity(0.18) : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? DS.Colors.overlayCursorBlue.opacity(0.35) : Color.clear, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
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

    private func sectionTitle(_ title: String, tip: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            if let tip { NotchInfoTip(text: tip) }
        }
        .zIndex(2)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Push to talk", tip: "The keys you hold while speaking. Record your own chord: modifiers alone, or modifiers plus one key.")
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
                     ? "Press the keys you want, then let go. Esc cancels."
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

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Voice", tip: "How Octo hears you and how it talks back. On-device transcription is instant and private; the cloud path is a fallback.")
            NotchToggleRow(title: "On-device transcription", detail: "Apple Speech, instant. Off uses Fireworks Whisper.",
                           isOn: companionManager.isOfflineVoiceEnabled) { companionManager.setOfflineVoiceEnabled($0) }
            NotchToggleRow(title: "Captions", detail: "Show what Octo says next to it, word by word.",
                           isOn: companionManager.isCaptionEnabled) { companionManager.setCaptionEnabled($0) }
            NotchInfoRow(title: "Speech", value: companionManager.speechOutputDisplayName)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Memory", tip: "What Octo keeps in mind. Screen rewind stays in memory and is dropped when the app quits; nothing is written to disk.")
            NotchToggleRow(title: "Screen rewind", detail: "Keeps the last 15 minutes as low-res frames in memory. Ask \u{201C}what did that error say five minutes ago?\u{201D}",
                           isOn: companionManager.isScreenRewindEnabled) { companionManager.setScreenRewindEnabled($0) }
            NotchToggleRow(title: "Dwell to ask", detail: "Hold the hotkey still over something for a second and Octo explains it, no need to speak.",
                           isOn: companionManager.isDwellEnabled) { companionManager.setDwellEnabled($0) }
            NotchInfoRow(title: "Pinned context", value: "\(companionManager.userContextStore.items.count) items")
        }
    }

    private var buddySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Buddy", tip: "The green companion on your cursor and how the Agent behaves.")
            NotchToggleRow(title: "Always visible", detail: "Off shows the buddy only while it works.",
                           isOn: companionManager.isClickyCursorEnabled) { companionManager.setClickyCursorEnabled($0) }
            NotchToggleRow(title: "Clipboard fallback", detail: "Copy a table when reading it off the screen is unsure.",
                           isOn: companionManager.isClipboardFallbackEnabled) { companionManager.setClipboardFallbackEnabled($0) }
            NotchToggleRow(title: "Rehearse before acting", detail: "Agent tasks are acted out by a ghost cursor first; say \u{201C}go\u{201D} to run. Off, say \u{201C}rehearse…\u{201D} for one task.",
                           isOn: companionManager.isAgentRehearsalEnabled) { companionManager.setAgentRehearsalEnabled($0) }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Services", tip: "Everything cloud-side goes through one proxy that holds the keys. Clinical rules run on their own service. Voice and screen reading are on-device.")
            NotchInfoRow(title: "Model", value: companionManager.chatModelDisplayName)
            NotchInfoRow(title: "Proxy", value: companionManager.isWorkerReachable ? "connected" : "unreachable", isBad: !companionManager.isWorkerReachable, showsStatusDot: true)
            NotchInfoRow(title: "Clinical rules", value: companionManager.isAnalysisServiceReachable ? "connected" : "unreachable", isBad: !companionManager.isAnalysisServiceReachable, showsStatusDot: true)
            NotchInfoRow(title: "Transcription", value: companionManager.buddyDictationManager.transcriptionProviderDisplayName)
            HStack(spacing: 8) {
                NotchPillButton(title: "Calibrate overlay", systemImage: "scope") { companionManager.runOverlayCalibration() }
                NotchInfoTip(text: "Draws a thin box around every line Octo can read for a few seconds. If the boxes sit on the text, the drawing is lined up.", width: 200)
                Spacer()
            }
            .padding(.top, 4)
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
            Text("A companion that lives in the notch and on your cursor. It reads the screen on-device, answers out loud, and draws where the data is. In Rx mode only concept IDs ever leave the Mac.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NotchPillButton(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(URL(string: "https://github.com/amanibobo/octo")!) }
                NotchPillButton(title: "Quit Octo", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
    }
}
