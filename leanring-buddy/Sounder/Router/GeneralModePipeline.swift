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
        /// Exact boxes to light up: word runs when the model quoted part of a line, else the line.
        let highlightRects: [CGRect]
        /// Where to fly when pointing: the quoted words' centre, else the element centre.
        let pointedCenterInCapturePixels: CGPoint?
        /// A web search query when the user asked to see a paper, image, video or link.
        let mediaQuery: String?
        let mediaKind: MediaCard.Kind?
        /// Elements in order, when the user asked how something flows or how to do a multi-step thing here.
        let routeElements: [ScreenElement]
        let routeLabels: [String]
        /// "flow" (explain the order) or "guide" (steps the user will click through).
        let routeKind: String?
        /// True when the question is conceptual and a small diagram in the margin would help.
        let wantsWhiteboard: Bool
    }

    private let chatClient: any ChatModelClient
    private static let maximumElementsSentToModel = 100

    private static let cameraAnswerSchema: [String: Any] = [
        "type": "object",
        "properties": ["speak": ["type": "string"], "key_line_indices": ["type": "array", "items": ["type": "integer"]]],
        "required": ["speak", "key_line_indices"]
    ]

    /// Answers about something held up to the webcam: the frame plus its OCR lines.
    /// Returns the spoken answer and the indices of the lines it leaned on.
    func answerAboutCameraFrame(transcript: String, frameJPEG: Data, textLines: [String], userContext: UserContextBundle?) async throws -> (spokenText: String, keyLineIndices: [Int]) {
        let numbered = textLines.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
        var userText = ""
        if let userContext { userText += userContext.promptText + "\n\n" }
        userText += "the user is holding something up to the webcam (a page, a whiteboard, a label). text read from it:\n\(numbered.isEmpty ? "(no text recognized)" : numbered)\n\nuser said: \"\(transcript)\""
        let object = try await chatClient.completeJSON(
            systemPrompt: "you're octo. describe or answer about what the user is holding up to the camera, using the image and the recognized text. spoken reply: one to three short sentences, lowercase, no lists. if they asked you to read it, read the important lines back in order, condensed. key_line_indices are the indices of the recognized lines your answer relies on (up to 8).",
            userText: userText,
            images: [ChatModelImage(data: frameJPEG, mimeType: "image/jpeg")] + (userContext?.images ?? []),
            priorTurns: [],
            jsonSchema: Self.cameraAnswerSchema,
            maxTokens: 500,
            timeoutSeconds: 25
        )
        let spoken = ((object["speak"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let indices = ((object["key_line_indices"] as? [Int]) ?? []).filter { $0 >= 0 && $0 < textLines.count }
        return (spoken.isEmpty ? "i can see it, but i couldn't make out much." : spoken, indices)
    }

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    private static let systemPrompt = """
    you're octo, a friendly companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen. your reply is spoken aloud, so write the way you'd talk: one or two short sentences, all lowercase, casual, no lists, no markdown, no emojis. spell out small numbers. never say "simply" or "just". if they ask for more detail, go deeper.

    the first image is the screen. any further images are references the user pinned as context, not the screen; never point at things in them.

    grounding rules, strictly: highlight only the exact thing the user asked about, and nothing next to it "for context". each highlight names an element id and quotes, verbatim from the element list, the words to light up: quote just the phrase when the user asked about a word or phrase (the app lights only those words), quote the whole element text only when the whole line is the answer. a highlight whose quote is not in that element's text is discarded, so never guess. when the user circled a region, only elements inside it exist: answer about those and never highlight or point outside. if nothing on screen matches what was asked, say so and highlight nothing rather than the nearest thing. point_element_id and point_quote follow the same rule.

    the screenshot has numbered red tags. each tag is an element id from the list you are given. point (point_element_id + a 1-3 word point_label) only when the user is asking where something is, how to do something, or what to click, and the thing is on screen. for descriptive questions ("what do you see", "what is this") return null and do not point. you may also return a few highlight_element_ids to light up related text. only use ids from the list.

    routes: if the user asks how something flows, moves or connects on this screen, or what order things happen in ("how does the data flow here?", "walk me through this"), you must put the element ids in order in route_element_ids (2 to 8, pick the labelled boxes, headings or buttons that make the best stops even if the ids are small text), a 1-4 word label per hop in route_labels, and route_kind "flow"; narrate the hops in order in speak. never answer a walkthrough question with an empty route while there are elements on screen. if they ask how to do a multi-step thing on this screen themselves ("show me how to…", "where do i click to…", "what are the steps to…"), do the same with route_kind "guide": the ids are the things they will click in order, labels say what each click does, and speak tells them to follow the numbers. otherwise leave route_element_ids empty and route_kind null.

    sketch_diagram: set true only when the question is conceptual rather than about what is on screen (how something works in general, a comparison, a process), so a small diagram in the margin would help. otherwise false.

    if the user asks you to show, find, pull up or bring up a paper, study, article, image, picture, diagram, video or link about something, set media_query to a precise web search query for it and media_kind to paper, image, video or link; you will hold the result up next to you, so say something like "here's one" in speak. otherwise leave both null.
    """

    private static let answerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "speak": ["type": "string"],
            "point_element_id": ["type": ["integer", "null"]],
            "point_quote": ["type": ["string", "null"]],
            "point_label": ["type": ["string", "null"]],
            "highlights": ["type": "array", "items": ["type": "object", "properties": ["element_id": ["type": "integer"], "quote": ["type": "string"]], "required": ["element_id", "quote"]]],
            "media_query": ["type": ["string", "null"]],
            "media_kind": ["type": ["string", "null"], "enum": ["paper", "image", "video", "link", NSNull()]],
            "route_element_ids": ["type": "array", "items": ["type": "integer"]],
            "route_labels": ["type": "array", "items": ["type": "string"]],
            "route_kind": ["type": ["string", "null"], "enum": ["flow", "guide", NSNull()]],
            "sketch_diagram": ["type": "boolean"]
        ],
        "required": ["speak", "point_element_id", "point_quote", "point_label", "highlights", "media_query", "media_kind", "route_element_ids", "route_labels", "route_kind", "sketch_diagram"]
    ]

    /// The box for a quoted phrase inside an element: the shortest run of that
    /// line's OCR words whose text contains the quote, else the whole element when
    /// the quote is the whole text (or the element has no word boxes). Nil when the
    /// quote is not in the element at all.
    static func groundedRect(for quote: String, in element: ScreenElement, textLines: [RecognizedTextLine]) -> CGRect? {
        func normalize(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let normalizedQuote = normalize(quote)
        let normalizedText = normalize(element.text)
        if normalizedQuote.isEmpty { return element.boundingBoxInCapturePixels } // no quote: whole element, as before
        guard normalizedText.contains(normalizedQuote) else { return nil }
        if normalizedQuote == normalizedText { return element.boundingBoxInCapturePixels }
        // OCR elements are lines in order; find the line and its words.
        guard element.kind == "text", element.id >= 1, element.id <= textLines.count else { return element.boundingBoxInCapturePixels }
        let line = textLines[element.id - 1]
        let words = line.words.filter { !$0.text.isEmpty }
        guard words.count >= 2 else { return element.boundingBoxInCapturePixels }
        let normalizedWords = words.map { normalize($0.text) }
        var best: (start: Int, end: Int)?
        for start in 0..<words.count {
            var joined = ""
            for end in start..<words.count {
                joined = joined.isEmpty ? normalizedWords[end] : joined + " " + normalizedWords[end]
                if joined.contains(normalizedQuote) {
                    if best == nil || (end - start) < (best!.end - best!.start) { best = (start, end) }
                    break
                }
                if joined.count > normalizedQuote.count + 24 { break }
            }
        }
        guard let best else { return element.boundingBoxInCapturePixels }
        return words[best.start...best.end].dropFirst().reduce(words[best.start].boundingBoxInCapturePixels) { $0.union($1.boundingBoxInCapturePixels) }
    }

    func answer(
        transcript: String,
        capture: SounderScreenCapture,
        elements: [ScreenElement],
        textLines: [RecognizedTextLine] = [],
        regionOfInterestInCapturePixels: CGRect? = nil,
        conversationHistory: [ChatModelPriorTurn],
        userContext: UserContextBundle? = nil,
        regionReason: String? = nil
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
                // Only what the user actually circled: an element counts when most of
                // it lies inside the circle, so a neighbouring line that merely touches
                // the edge is not offered to the model at all.
                let strictRegion = region.insetBy(dx: -6, dy: -6)
                groundingElements = elements
                    .filter { element in
                        let box = element.boundingBoxInCapturePixels
                        let overlap = box.intersection(strictRegion)
                        return !overlap.isNull && overlap.width * overlap.height >= 0.6 * box.width * box.height
                    }
                    .prefix(Self.maximumElementsSentToModel)
                    .map { element in
                        ScreenElement(id: element.id, kind: element.kind, text: element.text,
                                      boundingBoxInCapturePixels: element.boundingBoxInCapturePixels.offsetBy(dx: -paddedRegion.minX, dy: -paddedRegion.minY),
                                      confidence: element.confidence)
                    }
                regionNote = (regionReason ?? "the user circled part of the screen with the cursor while asking") + "; the image is only that region. \"this\" or \"here\" means what is inside it.\n"
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

        // Pinned context rides along as background; its images follow the screenshot.
        var contextNote = ""
        if let userContext {
            contextNote = userContext.promptText + "\n\n"
            images.append(contentsOf: userContext.images)
        }
        let userText = """
        \(contextNote)\(regionNote)elements on screen (id → text):
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
        let pointLabel = responseObject["point_label"] as? String
        // Only elements that were offered to the model can be lit: this is what
        // keeps a circled question from spilling onto neighbours.
        let elementsByID = Dictionary(uniqueKeysWithValues: groundingElements.map { ($0.id, $0) })

        // Every highlight must quote text that is really in that element, and the
        // quote picks the exact words to light up.
        var highlightedElements: [ScreenElement] = []
        var highlightRects: [CGRect] = []
        var seenHighlightIDs = Set<Int>()
        for entry in (responseObject["highlights"] as? [[String: Any]]) ?? [] {
            guard let id = entry["element_id"] as? Int, let element = elementsByID[id], seenHighlightIDs.insert(id).inserted else { continue }
            let quote = (entry["quote"] as? String) ?? ""
            guard let rect = Self.groundedRect(for: quote, in: element, textLines: textLines) else {
                print("🎯 dropped highlight [\(id)]: quote \"\(quote.prefix(40))\" not in \"\(element.text.prefix(40))\"")
                continue
            }
            highlightedElements.append(element)
            highlightRects.append(rect)
        }

        var pointedElement: ScreenElement?
        var pointedCenter: CGPoint?
        if let pointedElementID = responseObject["point_element_id"] as? Int, let element = elementsByID[pointedElementID] {
            let quote = (responseObject["point_quote"] as? String) ?? ""
            if let rect = Self.groundedRect(for: quote, in: element, textLines: textLines) {
                pointedElement = element
                pointedCenter = CGPoint(x: rect.midX, y: rect.midY)
            } else {
                print("🎯 dropped point [\(pointedElementID)]: quote \"\(quote.prefix(40))\" not in \"\(element.text.prefix(40))\"")
            }
        }
        if let pointedElement, let index = highlightedElements.firstIndex(where: { $0.id == pointedElement.id }) {
            highlightedElements.remove(at: index)
            highlightRects.remove(at: index)
        }

        let mediaQuery = (responseObject["media_query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaKind = (responseObject["media_kind"] as? String).flatMap { MediaCard.Kind(rawValue: $0) }
        let routeIDs = (responseObject["route_element_ids"] as? [Int]) ?? []
        var routeElements: [ScreenElement] = []
        var seenRouteIDs = Set<Int>()
        for id in routeIDs where seenRouteIDs.insert(id).inserted {
            if let element = elementsByID[id] { routeElements.append(element) }
        }
        let routeLabels = (responseObject["route_labels"] as? [String]) ?? []
        let routeKind = routeElements.count >= 2 ? (responseObject["route_kind"] as? String) : nil
        return Answer(
            spokenText: spokenText.isEmpty ? "i didn't catch a question in that." : spokenText,
            pointedElement: pointedElement,
            pointLabel: pointLabel,
            highlightedElements: Array(highlightedElements.prefix(6)),
            highlightRects: Array(highlightRects.prefix(6)),
            pointedCenterInCapturePixels: pointedCenter,
            mediaQuery: (mediaQuery?.isEmpty ?? true) ? nil : mediaQuery,
            mediaKind: mediaKind,
            routeElements: Array(routeElements.prefix(8)),
            routeLabels: routeLabels,
            routeKind: routeKind,
            wantsWhiteboard: (responseObject["sketch_diagram"] as? Bool) ?? false
        )
    }
}
