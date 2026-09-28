//
//  WhiteboardPipeline.swift
//  leanring-buddy
//
//  Whiteboard in the margins. For a conceptual question, Claude returns a small
//  node-and-edge diagram as JSON (never coordinates); the app lays it out and
//  sketches it in the emptiest part of the screen, then wipes it.
//

import Foundation

struct WhiteboardDiagram {
    struct Node: Identifiable {
        let id: String
        let label: String
    }
    struct Edge {
        let from: String
        let to: String
        let label: String?
    }
    let title: String
    let nodes: [Node]
    let edges: [Edge]
}

@MainActor
final class WhiteboardPipeline {
    private let chatClient: any ChatModelClient

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "nodes": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "string"], "label": ["type": "string"]], "required": ["id", "label"]]],
            "edges": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"], "label": ["type": ["string", "null"]]], "required": ["from", "to", "label"]]]
        ],
        "required": ["title", "nodes", "edges"]
    ]

    private static let systemPrompt = """
    you turn an explanation into a tiny whiteboard sketch: 3 to 7 boxes and the arrows between them. labels are 1 to 4 words. ids are short slugs. edges go from cause to effect, input to output, or step to next step; an edge label is at most 3 words or null. the title is at most 5 words. keep it to the single most useful picture, not everything.
    """

    func diagram(for question: String, spokenAnswer: String) async throws -> WhiteboardDiagram? {
        let object = try await chatClient.completeJSON(
            systemPrompt: Self.systemPrompt,
            userText: "question: \"\(question)\"\nthe spoken answer was: \"\(spokenAnswer)\"\n\nsketch it.",
            images: [],
            priorTurns: [],
            jsonSchema: Self.schema,
            maxTokens: 500,
            timeoutSeconds: 15
        )
        let nodes = ((object["nodes"] as? [[String: Any]]) ?? []).compactMap { node -> WhiteboardDiagram.Node? in
            guard let id = node["id"] as? String, let label = node["label"] as? String, !label.isEmpty else { return nil }
            return WhiteboardDiagram.Node(id: id, label: String(label.prefix(28)))
        }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = ((object["edges"] as? [[String: Any]]) ?? []).compactMap { edge -> WhiteboardDiagram.Edge? in
            guard let from = edge["from"] as? String, let to = edge["to"] as? String, nodeIDs.contains(from), nodeIDs.contains(to), from != to else { return nil }
            return WhiteboardDiagram.Edge(from: from, to: to, label: (edge["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(18)) })
        }
        guard nodes.count >= 2 else { return nil }
        return WhiteboardDiagram(title: String(((object["title"] as? String) ?? "").prefix(40)), nodes: Array(nodes.prefix(7)), edges: edges)
    }
}
