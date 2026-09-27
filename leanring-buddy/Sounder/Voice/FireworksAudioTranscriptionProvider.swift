//
//  FireworksAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  Upload-based transcription provider backed by Fireworks Whisper (whisper-v3-turbo)
//  through the Worker's /transcribe route. Push-to-talk audio is buffered as PCM16
//  while the hotkey is held and uploaded as one WAV on release.
//

import AVFoundation
import Foundation

struct FireworksAudioTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FireworksAudioTranscriptionProvider: BuddyTranscriptionProvider {
    private let transcribeURL: URL

    let displayName = "Fireworks Whisper"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    init(workerBaseURL: String) {
        self.transcribeURL = URL(string: workerBaseURL)!.appendingPathComponent("transcribe")
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        FireworksAudioTranscriptionSession(
            transcribeURL: transcribeURL,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class FireworksAudioTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 10.0

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private static let targetSampleRate = 16_000

    private let transcribeURL: URL
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.sounder.fireworks.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        transcribeURL: URL,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.transcribeURL = transcribeURL
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let isEmptyOrCancelled = stateQueue.sync { isCancelled || bufferedPCM16AudioData.isEmpty }
        if isEmptyOrCancelled {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let startedAt = Date()
            let transcriptText = try await requestTranscription(for: wavAudioData)
            print("🎙️ Fireworks Whisper: \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s for \(wavAudioData.count / 1024)KB → \"\(transcriptText)\"")
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("❌ Fireworks Whisper upload failed (\(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        var formBuilder = MultipartFormDataBuilder()
        formBuilder.appendField(name: "model", value: "whisper-v3-turbo")
        formBuilder.appendField(name: "language", value: "en")
        formBuilder.appendField(name: "response_format", value: "json")
        formBuilder.appendField(name: "temperature", value: "0")
        if let promptText = transcriptionPromptText() {
            formBuilder.appendField(name: "prompt", value: promptText)
        }
        formBuilder.appendFile(name: "file", filename: "voice-input.wav", mimeType: "audio/wav", fileData: wavAudioData)

        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"
        request.setValue(formBuilder.contentTypeHeaderValue, forHTTPHeaderField: "Content-Type")
        request.httpBody = formBuilder.finalizedBody()

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FireworksAudioTranscriptionProviderError(message: "transcription returned an invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw FireworksAudioTranscriptionProviderError(message: "transcription failed: \(responseText)")
        }

        if let transcriptionResponse = try? JSONDecoder().decode(TranscriptionResponse.self, from: responseData) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fallbackText = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackText.isEmpty {
            return fallbackText
        }
        throw FireworksAudioTranscriptionProviderError(message: "transcription returned an empty transcript")
    }

    /// Whisper accepts a short text prompt that biases vocabulary. Column names
    /// from the table on screen are passed in as keyterms so "tenure" is not
    /// heard as "tenor".
    private func transcriptionPromptText() -> String? {
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedKeyterms.isEmpty else { return nil }
        return "Questions about a spreadsheet. Vocabulary: \(normalizedKeyterms.prefix(40).joined(separator: ", "))."
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
