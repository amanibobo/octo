//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  Neural text-to-speech via the Kokoro-82M service on Modal (services/modal_tts.py).
//  No API key involved. Kokoro on CPU renders about three seconds of audio per
//  second, so long answers are split into sentences and played as each one
//  arrives; a few fixed filler phrases are synthesized once at launch so the
//  first thing the user hears is instant.
//

import AVFoundation
import Foundation

struct KokoroTTSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class KokoroTTSClient: NSObject, SpeechOutputClient, AVAudioPlayerDelegate {
    let displayName = "Kokoro (Modal)"

    private let ttsURL: URL
    private let urlSession: URLSession

    /// Synthesized WAV data by normalized phrase, for fillers and repeated sentences.
    private var audioCache: [String: Data] = [:]
    private var playbackQueue: [Data] = []
    private var currentPlayer: AVAudioPlayer?
    private var sentenceFetchTask: Task<Void, Never>?
    private var pendingSentenceCount = 0

    var isPlaying: Bool {
        (currentPlayer?.isPlaying ?? false) || !playbackQueue.isEmpty || pendingSentenceCount > 0
    }

    init(ttsBaseURL: String) {
        self.ttsURL = URL(string: ttsBaseURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
        super.init()
    }

    /// Synthesizes phrases ahead of time (fillers) so they play with zero latency.
    func prefetch(_ phrases: [String]) {
        Task { [weak self] in
            for phrase in phrases {
                guard let self else { return }
                _ = try? await self.fetchAudio(for: phrase)
            }
            print("🔊 Kokoro: \(phrases.count) filler phrases cached")
        }
    }

    /// Appends to the playback queue (a filler keeps playing until the answer's
    /// first sentence is ready). Returns once the first sentence is queued.
    /// A new push-to-talk press calls stopPlayback() explicitly.
    func speakText(_ text: String) async throws {
        let sentences = SpeechChunker.splitIntoSpeakableChunks(text)
        guard let firstSentence = sentences.first else { return }

        sentenceFetchTask?.cancel()
        pendingSentenceCount = sentences.count

        let firstAudio: Data
        do {
            firstAudio = try await fetchAudio(for: firstSentence)
        } catch {
            pendingSentenceCount = 0
            throw error
        }
        pendingSentenceCount -= 1
        enqueue(firstAudio)

        let remainingSentences = Array(sentences.dropFirst())
        guard !remainingSentences.isEmpty else { return }
        sentenceFetchTask = Task { [weak self] in
            for sentence in remainingSentences {
                guard let self, !Task.isCancelled else { return }
                if let audio = try? await self.fetchAudio(for: sentence), !Task.isCancelled {
                    self.enqueue(audio)
                } else {
                    print("⚠️ Kokoro: dropped a sentence (\(sentence.prefix(40))...)")
                }
                self.pendingSentenceCount = max(0, self.pendingSentenceCount - 1)
            }
        }
    }

    func stopPlayback() {
        sentenceFetchTask?.cancel()
        sentenceFetchTask = nil
        pendingSentenceCount = 0
        playbackQueue.removeAll()
        currentPlayer?.stop()
        currentPlayer = nil
    }

    // MARK: - Private

    private func fetchAudio(for text: String) async throws -> Data {
        let cacheKey = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = audioCache[cacheKey] { return cached }

        var request = URLRequest(url: ttsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "speed": 1.05])

        let startedAt = Date()
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KokoroTTSError(message: "tts service returned an invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode), !data.isEmpty else {
            throw KokoroTTSError(message: "tts failed (HTTP \(httpResponse.statusCode))")
        }
        print("🔊 Kokoro: \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s for \(text.count) chars")

        // Keep the cache bounded; fillers are short and get re-added on demand.
        if audioCache.count > 40 { audioCache.removeAll() }
        audioCache[cacheKey] = data
        return data
    }

    private func enqueue(_ audioData: Data) {
        playbackQueue.append(audioData)
        if currentPlayer == nil || currentPlayer?.isPlaying == false {
            playNextQueuedAudio()
        }
    }

    private func playNextQueuedAudio() {
        guard !playbackQueue.isEmpty else {
            currentPlayer = nil
            return
        }
        let audioData = playbackQueue.removeFirst()
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            currentPlayer = player
            player.play()
        } catch {
            print("⚠️ Kokoro: could not play audio: \(error)")
            playNextQueuedAudio()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.playNextQueuedAudio() }
    }
}
