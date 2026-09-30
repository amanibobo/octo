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
        /// The way out: a question for the user, or a plain statement that the task cannot be done.
        case askUser = "ask_user"
        case cannotDetermine = "cannot_determine"
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
    /// What the screen should show once this step has worked (kept in history).
    let expectedOutcome: String?
}

/// One rehearsed step: what will happen, and on which element if it is visible now.
struct AgentPlanStep {
    let number: Int
    let action: String
    let elementID: Int?
    let detail: String?
    let description: String
    let expectedOutcome: String?

    var promptLine: String {
        var line = "\(number). \(action)"
        if let elementID { line += " element \(elementID)" }
        if let detail, !detail.isEmpty { line += " \"\(detail)\"" }
        line += " — \(description)"
        if let expectedOutcome, !expectedOutcome.isEmpty { line += " (then: \(expectedOutcome))" }
        return line
    }
}

struct AgentVerdict {
    let isAchieved: Bool
    let evidence: String
    let nextHint: String?
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
    you are octo, an assistant that operates the user's mac to carry out a spoken task. you see a screenshot with numbered red tags and the list of those elements (id → role: text). the frontmost app is named. decide the single best next action.

    elements marked with a role (button, textfield, link, menuitem, row, popup, checkbox) come from the accessibility tree: their labels and positions are exact and clicking them always lands. plain "text" elements come from ocr and are approximate. prefer the accessibility element when both describe the same thing.

    actions: open_app (app name), open_url (a url or url scheme, e.g. spotify:search:matches che), click (element_id), double_click (element_id), type (text; only after a text field is focused, or with element_id of a textfield to focus it first), press_keys (a combo like cmd+l, enter, escape, space, down), scroll (element_id near where to scroll, scroll_lines negative = down), wait (let the ui settle), done (the screenshot already shows the result; give completion_summary), ask_user (text = one short question, when the task is ambiguous or needs a choice only the user can make; the loop ends and the question is spoken), cannot_determine (text = one short reason, when the task cannot be done from this screen; better than guessing).

    each history line ends with what the screen did after the action: "screen changed" or "no visible change". when the last actions had no visible change, or the same action repeats, state in expected_outcome what you expected versus what you see and pick a different approach, or ask_user.

    example of a good sequence for "open notes and write buy milk": step 1 open_app "Notes" (expected: notes window in front) → screen changed. step 2 press_keys cmd+n (expected: an empty note) → screen changed. step 3 type "buy milk" with element_id of the note body textfield (expected: the words appear in the note) → screen changed. step 4 done, completion_summary "buy milk is in a new note". example of a good way out: the task says "send it to sarah" and two contacts are named sarah → ask_user "which sarah, sarah kim or sarah lopez?".

    rules: one action per turn. never say done on hope: done means the screenshot already shows the result (the song title in the now-playing bar, the page loaded, the message sent). if the evidence is not on screen yet, take the next action instead. before each action fill expected_outcome with what the next screenshot should show if it worked; if the last expected outcome did not appear, do something different rather than repeating. prefer app search fields and enter over clicking many things. never enter passwords or payment details; if a login or payment screen appears, return done and say so. only use element ids from the list. narration is a short lowercase phrase shown to the user while you act, e.g. "opening spotify", "typing the song name", "clicking the first result". if research notes are provided, follow them.

    spotify playbook: open_url spotify:search:<song> <artist> (one action) → wait → in the results, click the accessibility button whose label starts with "Play" for the top song, or click the top result row then press_keys enter → verify: the bottom now-playing bar shows the song title; only then done. if the wrong track is playing, search again with the artist name added.
    """

    private static let actionSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["open_app", "open_url", "click", "double_click", "type", "press_keys", "scroll", "wait", "done", "ask_user", "cannot_determine"]],
            "element_id": ["type": ["integer", "null"]],
            "text": ["type": ["string", "null"]],
            "app": ["type": ["string", "null"]],
            "keys": ["type": ["string", "null"]],
            "scroll_lines": ["type": ["integer", "null"]],
            "narration": ["type": "string"],
            "task_complete": ["type": "boolean"],
            "completion_summary": ["type": ["string", "null"]],
            "expected_outcome": ["type": ["string", "null"]]
        ],
        "required": ["action", "element_id", "text", "app", "keys", "scroll_lines", "narration", "task_complete", "completion_summary", "expected_outcome"]
    ]

    private static let verdictSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "achieved": ["type": "boolean"],
            "evidence": ["type": "string"],
            "next_hint": ["type": ["string", "null"]]
        ],
        "required": ["achieved", "evidence", "next_hint"]
    ]

    /// Looks at a fresh screenshot and decides whether the task's outcome is visible.
    func verifyCompletion(task: String, claimedSummary: String, capture: SounderScreenCapture, elements: [ScreenElement]) async throws -> AgentVerdict {
        let groundingElements = Array(elements.prefix(Self.maximumElementsSentToModel))
        var images: [ChatModelImage] = []
        if let marked = SetOfMarkRenderer.renderMarkedScreenshot(capture: capture.cgImage, elements: groundingElements, maximumWidth: 1280) {
            images.append(ChatModelImage(data: marked.data, mimeType: "image/jpeg"))
        }
        let elementListText = groundingElements.map { "[\($0.id)] \(Self.roleLabel($0)): \(String($0.text.prefix(60)))" }.joined(separator: "\n")
        let object = try await chatClient.completeJSON(
            systemPrompt: "you are a strict verifier. given a task, an agent's claim that it is done, and the current screenshot with its elements, decide whether the screen itself proves the task is complete. be concrete: for \"play X\" the now-playing bar must show X (not a different track, not just search results); for \"open Y\" Y must be the frontmost window; for \"send\" the message must appear as sent. evidence is one sentence describing exactly what you see. if not achieved, next_hint is one concrete next action.",
            userText: "task: \"\(task)\"\nagent claims: \"\(claimedSummary)\"\nfrontmost app: \(MacControl.frontmostApplicationName())\n\nelements on screen:\n\(elementListText)",
            images: images, priorTurns: [], jsonSchema: Self.verdictSchema, maxTokens: 800, timeoutSeconds: 30, effort: "high")
        return AgentVerdict(isAchieved: (object["achieved"] as? Bool) ?? false,
                            evidence: (object["evidence"] as? String) ?? "no evidence",
                            nextHint: object["next_hint"] as? String)
    }

    private static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "steps": ["type": "array", "items": ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["open_app", "open_url", "click", "double_click", "type", "press_keys", "scroll", "wait"]],
                "element_id": ["type": ["integer", "null"]],
                "detail": ["type": ["string", "null"]],
                "description": ["type": "string"],
                "expected_outcome": ["type": ["string", "null"]]
            ], "required": ["action", "element_id", "detail", "description", "expected_outcome"]]],
            "spoken_summary": ["type": "string"]
        ],
        "required": ["steps", "spoken_summary"]
    ]

    /// Dry run: the whole task as a short ordered plan against the current screen.
    /// Steps that will happen on screens not visible yet carry no element id.
    func plan(task: String, researchNotes: String?, userContextText: String?, redirect: String?, capture: SounderScreenCapture, elements: [ScreenElement]) async throws -> (steps: [AgentPlanStep], spokenSummary: String) {
        let groundingElements = Array(elements.prefix(Self.maximumElementsSentToModel))
        var images: [ChatModelImage] = []
        if let marked = SetOfMarkRenderer.renderMarkedScreenshot(capture: capture.cgImage, elements: groundingElements, maximumWidth: 1280) {
            images.append(ChatModelImage(data: marked.data, mimeType: "image/jpeg"))
        }
        let elementListText = groundingElements.map { "[\($0.id)] \(Self.roleLabel($0)): \(String($0.text.prefix(60)))" }.joined(separator: "\n")
        var userText = "task: \"\(task)\"\nfrontmost app: \(MacControl.frontmostApplicationName())\n"
        if let userContextText { userText += userContextText + "\n" }
        if let researchNotes { userText += "research notes:\n\(researchNotes)\n" }
        if let redirect { userText += "the user watched the previous plan and said: \"\(redirect)\". change the plan accordingly.\n" }
        userText += "\nelements on screen (id → role: text):\n\(elementListText.isEmpty ? "(no text detected)" : elementListText)"
        let object = try await chatClient.completeJSON(
            systemPrompt: "you are octo, planning how to carry out a spoken task on the user's mac before doing anything. write the whole plan as 2 to 8 concrete steps in order. for each step: action (open_app, open_url, click, double_click, type, press_keys, scroll, wait), element_id only when the target is visible on the current screen (from the numbered list), detail (the app name, url, text to type, or key combo), a 3-8 word description shown to the user, and expected_outcome. later steps that depend on a screen not visible yet have element_id null and describe the target in words. prefer urls and search fields over many clicks. spoken_summary: one lowercase sentence, e.g. \"three steps: open spotify, search for the song, press play.\"" + " " + Self.systemPrompt.components(separatedBy: "spotify playbook:").dropFirst().map { "spotify playbook:" + $0 }.joined(),
            userText: userText, images: images, priorTurns: [], jsonSchema: Self.planSchema, maxTokens: 2500, timeoutSeconds: 45, effort: "xhigh")
        let steps = ((object["steps"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, entry -> AgentPlanStep? in
            guard let action = entry["action"] as? String, let description = entry["description"] as? String else { return nil }
            return AgentPlanStep(number: index + 1, action: action, elementID: entry["element_id"] as? Int, detail: entry["detail"] as? String,
                                 description: description, expectedOutcome: entry["expected_outcome"] as? String)
        }
        return (Array(steps.prefix(8)), (object["spoken_summary"] as? String) ?? "here's the plan.")
    }

    static func roleLabel(_ element: ScreenElement) -> String {
        element.kind.hasPrefix("ax:") ? String(element.kind.dropFirst(3)) : "text"
    }

    func decideNextAction(
        task: String,
        researchNotes: String?,
        userContextText: String? = nil,
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
        let elementListText = groundingElements.map { "[\($0.id)] \(Self.roleLabel($0)): \(String($0.text.prefix(60)))" }.joined(separator: "\n")
        let historyText = history.isEmpty ? "(none yet)" : history.joined(separator: "\n")
        let researchText = researchNotes.map { "research notes on how to do this:\n\($0)\n\n" } ?? ""
        let contextText = userContextText.map { $0 + "\n\n" } ?? ""
        let userText = """
        task: "\(task)"
        \(contextText)\(researchText)step \(stepNumber) of \(Self.maximumSteps). frontmost app: \(MacControl.frontmostApplicationName())
        actions taken so far:
        \(historyText)

        elements on screen (id → text):
        \(elementListText.isEmpty ? "(no text detected)" : elementListText)
        """
        let validIDs: [Any] = groundingElements.map(\.id) + [NSNull()]
        let turnSchema = JSONSchemaTools.settingEnum(Self.actionSchema, atPath: ["element_id"], values: validIDs)
        let object = try await chatClient.completeJSON(systemPrompt: Self.systemPrompt, userText: userText, images: images,
                                                       priorTurns: [], jsonSchema: turnSchema, maxTokens: 1600, timeoutSeconds: 40, effort: "high")
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
            completionSummary: object["completion_summary"] as? String,
            expectedOutcome: object["expected_outcome"] as? String
        )
    }

    /// Executes one action. Returns a one-line history entry.
    func execute(_ action: AgentAction, elements: [ScreenElement], accessibilityElementsByID: [Int: AccessibilityElement] = [:], geometry: CaptureGeometry) async -> String {
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
            // Accessibility elements are pressed through AX: exact, and it works even
            // when the pointer would land on a tooltip or an overlapping view.
            if action.kind == .click, let accessibilityElement = accessibilityElementsByID[elementID], accessibilityElement.isPressable,
               AccessibilityElementReader.press(accessibilityElement) {
                return "press [\(elementID)] \(accessibilityElement.shortRole) \(accessibilityElement.label.prefix(30)) (ax)"
            }
            MacControl.click(atGlobalAppKitPoint: point, doubleClick: action.kind == .doubleClick)
            return "\(action.kind.rawValue) [\(elementID)] \(elementsByID[elementID]?.text.prefix(30) ?? "")"
        case .type:
            if let elementID = action.elementID, let accessibilityElement = accessibilityElementsByID[elementID], accessibilityElement.isTextInput {
                AccessibilityElementReader.focus(accessibilityElement)
                try? await Task.sleep(nanoseconds: 150_000_000)
            } else if let elementID = action.elementID, let point = center(of: elementID) {
                MacControl.click(atGlobalAppKitPoint: point)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
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
        case .askUser:
            return "ask_user: \(action.text ?? action.narration)"
        case .cannotDetermine:
            return "cannot_determine: \(action.text ?? action.narration)"
        }
    }

    /// How long the UI needs to settle after an action before the next screenshot.
    static func settleDelayNanoseconds(after action: AgentAction) -> UInt64 {
        switch action.kind {
        case .openApp, .openURL: return 2_500_000_000
        case .type, .pressKeys: return 900_000_000
        case .click, .doubleClick, .scroll: return 1_100_000_000
        case .wait: return 1_500_000_000
        case .done, .askUser, .cannotDetermine: return 0
        }
    }
}
