//
//  SpeechOutputClient.swift
//  leanring-buddy
//
//  Text-to-speech abstraction. The default is the on-device system voice
//  (AVSpeechSynthesizer) so speech works with no network and no API key;
//  ElevenLabs remains available through the Worker when a key is configured.
//

import AVFoundation
import Foundation

@MainActor
protocol SpeechOutputClient: AnyObject {
    var displayName: String { get }
    var isPlaying: Bool { get }
    /// Starts speaking and returns once playback has begun (not when it ends).
    func speakText(_ text: String) async throws
    func stopPlayback()
}

extension ElevenLabsTTSClient: SpeechOutputClient {
    var displayName: String { "ElevenLabs" }
}

/// On-device speech via AVSpeechSynthesizer. Utterances queue, so a short filler
/// ("looking...") followed by the real answer plays back to back naturally.
final class SystemSpeechOutputClient: NSObject, SpeechOutputClient, AVSpeechSynthesizerDelegate {
    let displayName = "System voice"

    private let synthesizer = AVSpeechSynthesizer()
    private var queuedUtteranceCount = 0
    /// Resolved once, off the main thread: enumerating installed voices takes
    /// seconds the first time and would freeze the UI on the first answer.
    private var cachedPreferredVoice: AVSpeechSynthesisVoice?

    var isPlaying: Bool {
        synthesizer.isSpeaking || queuedUtteranceCount > 0
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        Task.detached(priority: .utility) { [weak self] in
            let startedAt = Date()
            let voice = Self.preferredEnglishVoice()
            print("🔊 System voice ready: \(voice?.name ?? "default") in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
            let weakClient = self
            await MainActor.run { weakClient?.cachedPreferredVoice = voice }
        }
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmedText)
        // Nil voice = system default; never block here waiting for the lookup.
        utterance.voice = cachedPreferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05

        queuedUtteranceCount += 1
        synthesizer.speak(utterance)
    }

    func stopPlayback() {
        synthesizer.stopSpeaking(at: .immediate)
        queuedUtteranceCount = 0
    }

    /// Prefers an installed premium/enhanced US-English voice; falls back to the default.
    /// Slow on first call (voice enumeration), so only ever called off the main thread.
    nonisolated private static func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let qualityRank: (AVSpeechSynthesisVoice) -> Int = { voice in
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }
        let usVoices = englishVoices.filter { $0.language == "en-US" }
        let candidates = usVoices.isEmpty ? englishVoices : usVoices
        return candidates.max { qualityRank($0) < qualityRank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // The synthesizer does not promise which thread it calls back on, so these
    // stay nonisolated and hop to the main actor explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.noteUtteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.noteUtteranceEnded() }
    }

    private func noteUtteranceEnded() {
        queuedUtteranceCount = max(0, queuedUtteranceCount - 1)
    }
}
