//
//  ReadabilityPipeline.swift
//  leanring-buddy
//
//  Model calls behind "make this readable" (structure over a dense page) and
//  "clearer" (rewrite a circled paragraph in place). Both return JSON that
//  refers to OCR lines by index, so drawings are grounded in the page.
//

import Foundation

struct ReadableStructure {
    struct Definition {
        let lineIndex: Int
        let term: String
        let definition: String
    }
    let headingLineIndices: [Int]
    let keyPointLineIndices: [Int]
    let definitions: [Definition]
    let summary: String
}

struct RewriteResult {
    struct Segment {
        let text: String
        let isChanged: Bool
    }
    let rewritten: String
    let segments: [Segment]
    let summary: String
}

@MainActor
final class ReadabilityPipeline {
    private let chatClient: any ChatModelClient

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    private static let structureSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "heading_line_indices": ["type": "array", "items": ["type": "integer"]],
            "key_point_line_indices": ["type": "array", "items": ["type": "integer"]],
            "definitions": ["type": "array", "items": ["type": "object", "properties": ["line_index": ["type": "integer"], "term": ["type": "string"], "definition": ["type": "string"]], "required": ["line_index", "term", "definition"]]],
            "summary": ["type": "string"]
        ],
        "required": ["heading_line_indices", "key_point_line_indices", "definitions", "summary"]
    ]

    func structure(for lines: [String]) async throws -> ReadableStructure {
        let numbered = lines.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
        let object = try await chatClient.completeJSON(
            systemPrompt: "you add structure to a dense page for a reader, without changing it. given numbered text lines from the screen: heading_line_indices are lines that act as section headings (or the first line of each topic if there are no headings; 2 to 8). key_point_line_indices are the lines carrying the most important claims, numbers or conclusions (4 to 10; never more than a third of the lines). definitions: up to 5 technical terms that appear on a line, each with a plain 6-12 word definition. summary: one spoken sentence, lowercase, saying what the page is about and what the key points are.",
            userText: numbered,
            images: [],
            priorTurns: [],
            jsonSchema: Self.structureSchema,
            maxTokens: 1800,
            timeoutSeconds: 30,
            effort: "medium"
        )
        let valid = { (index: Int) -> Bool in index >= 0 && index < lines.count }
        let definitions = ((object["definitions"] as? [[String: Any]]) ?? []).compactMap { entry -> ReadableStructure.Definition? in
            guard let index = entry["line_index"] as? Int, valid(index), let term = entry["term"] as? String, let definition = entry["definition"] as? String else { return nil }
            return ReadableStructure.Definition(lineIndex: index, term: term, definition: definition)
        }
        return ReadableStructure(
            headingLineIndices: ((object["heading_line_indices"] as? [Int]) ?? []).filter(valid),
            keyPointLineIndices: ((object["key_point_line_indices"] as? [Int]) ?? []).filter(valid),
            definitions: Array(definitions.prefix(5)),
            summary: (object["summary"] as? String) ?? ""
        )
    }

    private static let rewriteSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "segments": ["type": "array", "items": ["type": "object", "properties": ["text": ["type": "string"], "changed": ["type": "boolean"]], "required": ["text", "changed"]]],
            "summary": ["type": "string"]
        ],
        "required": ["segments", "summary"]
    ]

    /// Rewrites a paragraph per the instruction. The result comes back as segments
    /// so the changed spans can be marked on screen.
    func rewrite(_ paragraph: String, instruction: String) async throws -> RewriteResult {
        let object = try await chatClient.completeJSON(
            systemPrompt: "you rewrite a paragraph the user circled on screen. follow the instruction, keep the meaning, keep names and numbers, keep it about the same length unless asked otherwise. return the full rewritten paragraph as an ordered list of segments: unchanged runs (changed=false, copied verbatim from the original) and rewritten runs (changed=true). keep unchanged text unchanged so the marks are honest. summary: one short lowercase sentence on what you changed.",
            userText: "instruction: \(instruction)\n\nparagraph:\n\(paragraph)",
            images: [],
            priorTurns: [],
            jsonSchema: Self.rewriteSchema,
            maxTokens: 2400,
            timeoutSeconds: 30,
            effort: "medium"
        )
        let segments = ((object["segments"] as? [[String: Any]]) ?? []).compactMap { entry -> RewriteResult.Segment? in
            guard let text = entry["text"] as? String else { return nil }
            return RewriteResult.Segment(text: text, isChanged: (entry["changed"] as? Bool) ?? false)
        }
        let rewritten = segments.map(\.text).joined()
        return RewriteResult(rewritten: rewritten, segments: segments, summary: (object["summary"] as? String) ?? "")
    }
}
