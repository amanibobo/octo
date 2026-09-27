//
//  AgentModePipeline.swift
//  leanring-buddy
//
//  Agent mode: the buddy carries out a task on the Mac ("open spotify and play
//  matches by che"). Each step: capture → OCR elements (Set-of-Mark) → Claude
//  picks ONE action referring to elements by id → the buddy flies to the target,
//  the caption says what it is doing, the action is executed, and the loop
//  repeats until Claude reports done or the step budget runs out.
//
//  Grounding stays by ID (never coordinates). Safety: at most `maximumSteps`,
//  a fresh screenshot before every decision, and a new hotkey press cancels.
//

import CoreGraphics
import Foundation

struct AgentAction {
    enum Kind: String {
        case openApp = "open_app"
        case openURL = "open_url"
        case click
        case doubleClick = "double_click"
        case type
        case pressKeys = "press_keys"
        case scroll
        case wait
        case done
    }
    let kind: Kind
    let elementID: Int?
    let text: String?
    let app: String?
    let keys: String?
    let scrollLines: Int?
    let narration: String
    let isTaskComplete: Bool
    let completionSummary: String?
}

@MainActor
final class AgentModePipeline {

    static let maximumSteps = 10
    static let fillerPhrase = "on it"

    private let chatClient: any ChatModelClient
    private static let maximumElementsSentToModel = 120

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    static func looksLikeTask(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        let taskStarters = ["open ", "launch ", "play ", "close ", "quit ", "click ", "press ", "type ", "search for", "search ", "go to ", "switch to ",
                            "scroll ", "navigate to", "start ", "pause ", "skip ", "next song", "turn on ", "turn off ", "send ", "create ", "add a ", "add an ",
                            "can you open", "can you play", "could you open", "could you play", "please open", "please play"]
        return taskStarters.contains { lowered.hasPrefix($0) || lowered.contains(" " + $0) }
    }

    private static let systemPrompt = """
    you are octo, an assistant that operates the user's mac to carry out a spoken task. you see a screenshot with numbered red tags and the list of those elements (id → text). the frontmost app is named. decide the single best next action.

    actions: open_app (app name), open_url (a url or url scheme, e.g. spotify:search:matches che), click (element_id), double_click (element_id), type (text; only after a text field is focused), press_keys (a combo like cmd+l, enter, escape, space, down), scroll (element_id near where to scroll, scroll_lines negative = down), wait (let the ui settle), done (task complete or impossible; give completion_summary).

    rules: one action per turn. prefer app search fields and enter over clicking many things. in spotify, cmd+l focuses search; a search result row can be clicked, then space or the play control plays it. never enter passwords or payment details; if a login or payment screen appears, return done and say so. only use element ids from the list. narration is a short lowercase phrase shown to the user while you act, e.g. "opening spotify", "typing the song name", "clicking the first result". if research notes are provided, follow them.
    """

    private static let actionSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["open_app", "open_url", "click", "double_click", "type", "press_keys", "scroll", "wait", "done"]],
            "element_id": ["type": ["integer", "null"]],
            "text": ["type": ["string", "null"]],
            "app": ["type": ["string", "null"]],
            "keys": ["type": ["string", "null"]],
            "scroll_lines": ["type": ["integer", "null"]],
            "narration": ["type": "string"],
            "task_complete": ["type": "boolean"],
            "completion_summary": ["type": ["string", "null"]]
        ],
        "required": ["action", "element_id", "text", "app", "keys", "scroll_lines", "narration", "task_complete", "completion_summary"]
    ]

    func decideNextAction(
        task: String,
        researchNotes: String?,
        stepNumber: Int,
        history: [String],
        capture: SounderScreenCapture,
        elements: [ScreenElement]
    ) async throws -> AgentAction {
        let groundingElements = Array(elements.prefix(Self.maximumElementsSentToModel))
        var images: [ChatModelImage] = []
        if let marked = SetOfMarkRenderer.renderMarkedScreenshot(capture: capture.cgImage, elements: groundingElements, maximumWidth: 1280) {
            images.append(ChatModelImage(data: marked.data, mimeType: "image/jpeg"))
        }
        let elementListText = groundingElements.map { "[\($0.id)] \(String($0.text.prefix(60)))" }.joined(separator: "\n")
        let historyText = history.isEmpty ? "(none yet)" : history.joined(separator: "\n")
        let researchText = researchNotes.map { "research notes on how to do this:\n\($0)\n\n" } ?? ""
        let userText = """
        task: "\(task)"
        \(researchText)step \(stepNumber) of \(Self.maximumSteps). frontmost app: \(MacControl.frontmostApplicationName())
        actions taken so far:
        \(historyText)

        elements on screen (id → text):
        \(elementListText.isEmpty ? "(no text detected)" : elementListText)
        """
        let object = try await chatClient.completeJSON(systemPrompt: Self.systemPrompt, userText: userText, images: images,
                                                       priorTurns: [], jsonSchema: Self.actionSchema, maxTokens: 400, timeoutSeconds: 30)
        let kind = AgentAction.Kind(rawValue: (object["action"] as? String) ?? "wait") ?? .wait
        return AgentAction(
            kind: kind,
            elementID: object["element_id"] as? Int,
            text: object["text"] as? String,
            app: object["app"] as? String,
            keys: object["keys"] as? String,
            scrollLines: object["scroll_lines"] as? Int,
            narration: (object["narration"] as? String) ?? kind.rawValue,
            isTaskComplete: (object["task_complete"] as? Bool) ?? (kind == .done),
            completionSummary: object["completion_summary"] as? String
        )
    }

    /// Executes one action. Returns a one-line history entry.
    func execute(_ action: AgentAction, elements: [ScreenElement], geometry: CaptureGeometry) async -> String {
        let elementsByID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        func center(of elementID: Int?) -> CGPoint? {
            guard let elementID, let element = elementsByID[elementID] else { return nil }
            return geometry.globalAppKitPoint(fromCapturePixel: element.centerInCapturePixels)
        }
        switch action.kind {
        case .openApp:
            let name = action.app ?? action.text ?? ""
            let ok = await MacControl.openApplication(named: name)
            return "open_app \(name) → \(ok ? "ok" : "not found")"
        case .openURL:
            let url = action.text ?? ""
            return "open_url \(url) → \(MacControl.open(urlString: url) ? "ok" : "failed")"
        case .click, .doubleClick:
            guard let elementID = action.elementID, let point = center(of: elementID) else {
                return "\(action.kind.rawValue) element \(action.elementID ?? -1) → no such element"
            }
            MacControl.click(atGlobalAppKitPoint: point, doubleClick: action.kind == .doubleClick)
            return "\(action.kind.rawValue) [\(elementID)] \(elementsByID[elementID]?.text.prefix(30) ?? "")"
        case .type:
            MacControl.typeText(action.text ?? "")
            return "type \"\(action.text ?? "")\""
        case .pressKeys:
            let combo = action.keys ?? action.text ?? ""
            return "press \(combo) → \(MacControl.pressKeyCombo(combo) ? "ok" : "unknown key")"
        case .scroll:
            let point = center(of: action.elementID) ?? CGPoint(x: geometry.displayFrame.midX, y: geometry.displayFrame.midY)
            MacControl.scroll(atGlobalAppKitPoint: point, lines: Int32(action.scrollLines ?? -5))
            return "scroll \(action.scrollLines ?? -5)"
        case .wait:
            return "wait"
        case .done:
            return "done: \(action.completionSummary ?? "")"
        }
    }

    /// How long the UI needs to settle after an action before the next screenshot.
    static func settleDelayNanoseconds(after action: AgentAction) -> UInt64 {
        switch action.kind {
        case .openApp, .openURL: return 2_500_000_000
        case .type, .pressKeys: return 900_000_000
        case .click, .doubleClick, .scroll: return 1_100_000_000
        case .wait: return 1_500_000_000
        case .done: return 0
        }
    }
}
