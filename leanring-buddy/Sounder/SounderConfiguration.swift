//
//  SounderConfiguration.swift
//  leanring-buddy
//
//  Runtime configuration for the Sounder-specific pieces of the app. Everything is
//  read from Info.plist so the demo laptop can point at a local Worker and analysis
//  backend during development, or at deployed ones, without a code change.
//

import Foundation

enum SounderConfiguration {
    /// Base URL of the Cloudflare Worker proxy that holds the Fireworks key.
    /// During development this is `npx wrangler dev` on localhost.
    static var workerBaseURL: String {
        AppBundleConfiguration.stringValue(forKey: "SounderWorkerBaseURL") ?? "http://127.0.0.1:8787"
    }

    /// Base URL of the Python analysis service (FastAPI, local uvicorn or Modal).
    static var analysisServiceBaseURL: String {
        AppBundleConfiguration.stringValue(forKey: "SounderAnalysisBaseURL") ?? "http://127.0.0.1:8000"
    }

    /// Fireworks model for planning, narration and vision grounding. Nil lets the
    /// Worker fill in its configured default so the model can change without a rebuild.
    static var chatModel: String? {
        AppBundleConfiguration.stringValue(forKey: "SounderChatModel")
    }

    /// "kokoro" (neural voice on Modal), "elevenlabs" (via Worker /tts) or "system" (AVSpeechSynthesizer, offline).
    static var speechOutputProvider: String {
        AppBundleConfiguration.stringValue(forKey: "SounderSpeechOutputProvider")?.lowercased() ?? "elevenlabs"
    }

    /// Whether the LLM rewrites the deterministic result sentences for speech.
    /// The numbers always come from the analysis service; the LLM only rephrases.
    static var usesLLMNarration: Bool {
        (AppBundleConfiguration.stringValue(forKey: "SounderUsesLLMNarration") ?? "false").lowercased() == "true"
    }

    /// Base URL of the Kokoro text-to-speech service (Modal). Used when the speech
    /// output provider is "kokoro".
    static var ttsServiceBaseURL: String {
        AppBundleConfiguration.stringValue(forKey: "SounderTTSBaseURL") ?? "https://amanibobo1--sounder-tts-kokorospeaker-tts.modal.run"
    }
}
