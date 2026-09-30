//
//  JevIntentRouter.swift
//  leanring-buddy
//
//  Which feature a spoken request is for, decided by Jev in one ~100 ms typed
//  question instead of a stack of phrase matchers. The phrase matchers stay as
//  the fallback for low confidence, for unreachable Jev, and to pull parameters
//  (target language, export format) out of the words.
//

import Foundation

enum OctoIntent: String, CaseIterable {
    case rewind
    case readAloud = "read_aloud"
    case makeReadable = "make_readable"
    case rewrite
    case camera
    case dialogReader = "dialog_reader"
    case translate
    case dictate
    case inkMath = "ink_math"
    case extract
    case media
    case agentTask = "agent_task"
    case clinical
    case general

    /// What each option means, in Jev's terms.
    var criteria: String {
        switch self {
        case .rewind: return "asks about something that was on screen earlier ('what did that error say five minutes ago', 'what was that number before')"
        case .readAloud: return "asks to have the page or text read out loud"
        case .makeReadable: return "asks to structure, outline, annotate or highlight the key points of a dense page"
        case .rewrite: return "asks to rewrite, fix, proofread or restyle the circled text (clearer, shorter, formal, fix grammar)"
        case .camera: return "asks to look at something physical through the webcam or camera, or to close the camera"
        case .dialogReader: return "asks to read out a dialog, alert, window or its buttons"
        case .translate: return "asks to translate the text on screen, or what foreign text says"
        case .dictate: return "dictates words to type into the circled field ('type hello there', 'write my name')"
        case .inkMath: return "asks for arithmetic over the circled numbers (sum, total, average, difference)"
        case .extract: return "asks to copy, extract or export a table, rows or text to the clipboard as csv, json or markdown"
        case .media: return "asks to show, find or pull up a paper, article, image, picture or video about a topic from the web"
        case .agentTask: return "asks Octo to do something on the mac: open, play, click, search, send, create, close, navigate, switch apps"
        case .clinical: return "a clinical question about the medications or diagnoses on a patient chart (interactions, doses, contraindications)"
        case .general: return "a question about what is on screen, where something is, how to do something, or anything else conversational"
        }
    }
}

struct JevIntentDecision {
    let intent: OctoIntent
    let confidence: Double
}

@MainActor
enum JevIntentRouter {
    /// Below this the phrase matchers decide, as before.
    static let confidenceThreshold = 0.6

    static func route(transcript: String, hasCircledRegion: Bool, frontmostAppName: String?, hasClinicalReading: Bool, isReadingAloud: Bool, using jev: JevDecisionClient) async -> JevIntentDecision? {
        guard jev.isConfigured else { return nil }
        let state = """
        spoken request: "\(transcript)"
        frontmost app: \(frontmostAppName ?? "unknown")
        the user circled a region on screen: \(hasCircledRegion ? "yes" : "no")
        a patient chart with medications is on screen: \(hasClinicalReading ? "yes" : "no")
        octo is currently reading aloud: \(isReadingAloud ? "yes" : "no")
        """
        let options = Dictionary(uniqueKeysWithValues: OctoIntent.allCases.map { ($0.rawValue, $0.criteria) })
        do {
            let answer = try await jev.choice(state: state, instructions: "Which Octo feature is this spoken request for?", options: options)
            guard let intent = OctoIntent(rawValue: answer.choice) else { return nil }
            let runnerUp = answer.probabilities.filter { $0.key != answer.choice }.values.max() ?? 0
            print("⚡️ jev intent: \(intent.rawValue) \(String(format: "%.2f", answer.confidence)) (next \(String(format: "%.2f", runnerUp)))")
            return JevIntentDecision(intent: intent, confidence: answer.confidence)
        } catch {
            print("⚠️ jev intent failed: \(error.localizedDescription)")
            return nil
        }
    }
}
