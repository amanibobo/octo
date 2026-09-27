//
//  GeneralModePipeline.swift
//  leanring-buddy
//
//  The Clicky baseline: see the screen, answer by voice, point at the thing.
//  Grounding is by element ID (Set-of-Mark): the vision model sees a marked
//  screenshot plus the numbered element list and returns an ID, never pixels.
//

import CoreGraphics
import Foundation

@MainActor
final class GeneralModePipeline {

    struct Answer {
        let spokenText: String
        let pointedElement: ScreenElement?
        let pointLabel: String?
        let highlightedElements: [ScreenElement]
        /// A web search query when the user asked to see a paper, image, video or link.
        let mediaQuery: String?
        let mediaKind: MediaCard.Kind?
    }

    private let chatClient: any ChatModelClient
    private static let maximumElementsSentToModel = 100

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    private static let systemPrompt = """
    you're sounder, a friendly companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen. your reply is spoken aloud, so write the way you'd talk: one or two short sentences, all lowercase, casual, no lists, no markdown, no emojis. spell out small numbers. never say "simply" or "just". if they ask for more detail, go deeper.

    the screenshot has numbered red tags. each tag is an element id from the list you are given. point (point_element_id + a 1-3 word point_label) only when the user is asking where something is, how to do something, or what to click, and the thing is on screen. for descriptive questions ("what do you see", "what is this") return null and do not point. you may also return a few highlight_element_ids to light up related text. only use ids from the list.

    if the user asks you to show, find, pull up or bring up a paper, study, article, image, picture, diagram, video or link about something, set media_query to a precise web search query for it and media_kind to paper, image, video or link; you will hold the result up next to you, so say something like "here's one" in speak. otherwise leave both null.
    """

    private static let answerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "speak": ["type": "string"],
            "point_element_id": ["type": ["integer", "null"]],
            "point_label": ["type": ["string", "null"]],
            "highlight_element_ids": ["type": "array", "items": ["type": "integer"]],
            "media_query": ["type": ["string", "null"]],
            "media_kind": ["type": ["string", "null"], "enum": ["paper", "image", "video", "link", NSNull()]]
        ],
        "required": ["speak", "point_element_id", "point_label", "highlight_element_ids", "media_query", "media_kind"]
    ]

    func answer(
        transcript: String,
        capture: SounderScreenCapture,
        elements: [ScreenElement],
        regionOfInterestInCapturePixels: CGRect? = nil,
        conversationHistory: [ChatModelPriorTurn]
    ) async throws -> Answer {
        // Spatial context: when the user circled a region while holding the hotkey,
        // the model sees only that crop and the elements inside it. IDs are kept so
        // the pointed element still resolves against the full-screen list.
        var groundingImage = capture.cgImage
        var groundingElements = Array(elements.prefix(Self.maximumElementsSentToModel))
        var regionNote = ""
        if let region = regionOfInterestInCapturePixels {
            let fullBounds = CGRect(x: 0, y: 0, width: capture.cgImage.width, height: capture.cgImage.height)
            let paddedRegion = region.insetBy(dx: -region.width * 0.12, dy: -region.height * 0.12).intersection(fullBounds).integral
            if paddedRegion.width >= 40, paddedRegion.height >= 40, let cropped = capture.cgImage.cropping(to: paddedRegion) {
                groundingImage = cropped
                groundingElements = elements
                    .filter { $0.boundingBoxInCapturePixels.intersects(paddedRegion) }
                    .prefix(Self.maximumElementsSentToModel)
                    .map { element in
                        ScreenElement(id: element.id, kind: element.kind, text: element.text,
                                      boundingBoxInCapturePixels: element.boundingBoxInCapturePixels.offsetBy(dx: -paddedRegion.minX, dy: -paddedRegion.minY),
                                      confidence: element.confidence)
                    }
                regionNote = "the user circled part of the screen with the cursor while asking; the image is only that region. \"this\" or \"here\" means what is inside it.\n"
            }
        }

        var images: [ChatModelImage] = []
        // 1280px is enough to read tags and costs half the upload/vision time of 1568px.
        if let markedScreenshot = SetOfMarkRenderer.renderMarkedScreenshot(capture: groundingImage, elements: groundingElements, maximumWidth: 1280) {
            images.append(ChatModelImage(data: markedScreenshot.data, mimeType: "image/jpeg"))
        } else if let plainScreenshot = NativeScreenCaptureUtility.makeDownscaledJPEG(from: groundingImage) {
            images.append(ChatModelImage(data: plainScreenshot.data, mimeType: "image/jpeg"))
        }

        let elementListText = groundingElements.map { element in
            "[\(element.id)] \(String(element.text.prefix(70)))"
        }.joined(separator: "\n")

        let userText = """
        \(regionNote)elements on screen (id → text):
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

        let mediaQuery = (responseObject["media_query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaKind = (responseObject["media_kind"] as? String).flatMap { MediaCard.Kind(rawValue: $0) }
        return Answer(
            spokenText: spokenText.isEmpty ? "i didn't catch a question in that." : spokenText,
            pointedElement: pointedElement,
            pointLabel: pointLabel,
            highlightedElements: Array(highlightedElements.prefix(6)),
            mediaQuery: (mediaQuery?.isEmpty ?? true) ? nil : mediaQuery,
            mediaKind: mediaKind
        )
    }
}
