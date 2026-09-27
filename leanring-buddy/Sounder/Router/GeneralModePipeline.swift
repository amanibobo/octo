//
//  GeneralModePipeline.swift
//  leanring-buddy
//
//  The Clicky baseline: see the screen, answer by voice, point at the thing.
//  Grounding is by element ID (Set-of-Mark): the vision model sees a marked
//  screenshot plus the numbered element list and returns an ID, never pixels.
//

import Foundation

@MainActor
final class GeneralModePipeline {

    struct Answer {
        let spokenText: String
        let pointedElement: ScreenElement?
        let pointLabel: String?
        let highlightedElements: [ScreenElement]
    }

    private let chatClient: FireworksChatClient

    init(chatClient: FireworksChatClient) {
        self.chatClient = chatClient
    }

    private static let systemPrompt = """
    you're sounder, a friendly companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen. your reply is spoken aloud, so write the way you'd talk: one or two short sentences, all lowercase, casual, no lists, no markdown, no emojis. spell out small numbers. never say "simply" or "just". if they ask for more detail, go deeper.

    the screenshot has numbered red tags. each tag is an element id from the list you are given. when pointing at something on screen would genuinely help (finding a button, a menu, a cell, a field), return that element's id in point_element_id and a 1-3 word point_label. if nothing on screen is worth pointing at, return null. you may also return a few highlight_element_ids to light up related text. only use ids from the list.

    if the question is about a table on screen, answer what you can see, and mention that saying "what drives" or "what's weird here" makes you run a real model on it.
    """

    private static let answerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "speak": ["type": "string"],
            "point_element_id": ["type": ["integer", "null"]],
            "point_label": ["type": ["string", "null"]],
            "highlight_element_ids": ["type": "array", "items": ["type": "integer"]]
        ],
        "required": ["speak", "point_element_id", "point_label", "highlight_element_ids"]
    ]

    func answer(
        transcript: String,
        capture: SounderScreenCapture,
        elements: [ScreenElement],
        conversationHistory: [FireworksChatClient.PriorTurn]
    ) async throws -> Answer {
        var images: [FireworksChatClient.ChatImage] = []
        if let markedScreenshot = SetOfMarkRenderer.renderMarkedScreenshot(capture: capture.cgImage, elements: elements) {
            images.append(FireworksChatClient.ChatImage(data: markedScreenshot.data, mimeType: "image/jpeg"))
        } else if let plainScreenshot = NativeScreenCaptureUtility.makeDownscaledJPEG(from: capture.cgImage) {
            images.append(FireworksChatClient.ChatImage(data: plainScreenshot.data, mimeType: "image/jpeg"))
        }

        let elementListText = elements.map { element in
            "[\(element.id)] \(String(element.text.prefix(70)))"
        }.joined(separator: "\n")

        let userText = """
        elements on screen (id → text):
        \(elementListText.isEmpty ? "(no text detected)" : elementListText)

        user said: "\(transcript)"
        """

        let responseObject = try await chatClient.completeJSON(
            systemPrompt: Self.systemPrompt,
            userText: userText,
            images: images,
            priorTurns: conversationHistory,
            jsonSchema: Self.answerSchema,
            maxTokens: 900
        )

        let spokenText = (responseObject["speak"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pointedElementID = responseObject["point_element_id"] as? Int
        let pointLabel = responseObject["point_label"] as? String
        let highlightIDs = Set((responseObject["highlight_element_ids"] as? [Int]) ?? [])

        let elementsByID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        let pointedElement = pointedElementID.flatMap { elementsByID[$0] }
        let highlightedElements = highlightIDs.compactMap { elementsByID[$0] }.filter { $0.id != pointedElementID }

        return Answer(
            spokenText: spokenText.isEmpty ? "i didn't catch a question in that." : spokenText,
            pointedElement: pointedElement,
            pointLabel: pointLabel,
            highlightedElements: Array(highlightedElements.prefix(6))
        )
    }
}
