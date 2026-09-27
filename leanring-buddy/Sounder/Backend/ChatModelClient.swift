//
//  ChatModelClient.swift
//  leanring-buddy
//
//  Abstraction over the language model used for planning, grounding and
//  narration, so Claude (default) and Fireworks are interchangeable.
//

import Foundation

struct ChatModelImage {
    let data: Data
    let mimeType: String
}

struct ChatModelPriorTurn {
    let userText: String
    let assistantText: String
}

@MainActor
protocol ChatModelClient: AnyObject {
    var displayName: String { get }

    /// Returns a JSON object matching `jsonSchema`.
    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatModelImage],
        priorTurns: [ChatModelPriorTurn],
        jsonSchema: [String: Any],
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any]

    func completeText(
        systemPrompt: String,
        userText: String,
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> String
}

extension ChatModelClient {
    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatModelImage] = [],
        priorTurns: [ChatModelPriorTurn] = [],
        jsonSchema: [String: Any],
        maxTokens: Int = 700,
        timeoutSeconds: TimeInterval = 25
    ) async throws -> [String: Any] {
        try await completeJSON(systemPrompt: systemPrompt, userText: userText, images: images, priorTurns: priorTurns,
                               jsonSchema: jsonSchema, maxTokens: maxTokens, timeoutSeconds: timeoutSeconds)
    }

    func completeText(systemPrompt: String, userText: String, maxTokens: Int = 400, timeoutSeconds: TimeInterval = 12) async throws -> String {
        try await completeText(systemPrompt: systemPrompt, userText: userText, maxTokens: maxTokens, timeoutSeconds: timeoutSeconds)
    }
}
