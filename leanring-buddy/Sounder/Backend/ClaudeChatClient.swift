//
//  ClaudeChatClient.swift
//  leanring-buddy
//
//  Claude through the Worker's /claude route (Anthropic Messages API). JSON
//  answers are forced through a single tool whose input_schema is the contract,
//  which is the most reliable structured-output path on this API.
//

import Foundation

struct ClaudeChatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class ClaudeChatClient: ChatModelClient {
    let displayName: String

    private let claudeURL: URL
    /// Nil lets the Worker inject its configured default model.
    private let model: String?
    private let urlSession: URLSession

    init(workerBaseURL: String, model: String?) {
        self.claudeURL = URL(string: workerBaseURL)!.appendingPathComponent("claude")
        self.model = model
        self.displayName = "Claude (\(model ?? "worker default"))"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.urlSession = URLSession(configuration: configuration)
    }

    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatModelImage],
        priorTurns: [ChatModelPriorTurn],
        jsonSchema: [String: Any],
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any] {
        var requestBody = baseRequestBody(systemPrompt: systemPrompt, userText: userText, images: images, priorTurns: priorTurns, maxTokens: maxTokens)
        requestBody["tools"] = [[
            "name": "answer",
            "description": "Return the structured answer.",
            "input_schema": jsonSchema
        ]]
        requestBody["tool_choice"] = ["type": "tool", "name": "answer"]

        let contentBlocks = try await send(requestBody, timeoutSeconds: timeoutSeconds)
        guard let toolBlock = contentBlocks.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolBlock["input"] as? [String: Any] else {
            throw ClaudeChatError(message: "claude returned no tool_use block")
        }
        return input
    }

    func completeText(systemPrompt: String, userText: String, maxTokens: Int, timeoutSeconds: TimeInterval) async throws -> String {
        let requestBody = baseRequestBody(systemPrompt: systemPrompt, userText: userText, images: [], priorTurns: [], maxTokens: maxTokens)
        let contentBlocks = try await send(requestBody, timeoutSeconds: timeoutSeconds)
        let text = contentBlocks.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeChatError(message: "claude returned empty text") }
        return text
    }

    // MARK: - Private

    private func baseRequestBody(systemPrompt: String, userText: String, images: [ChatModelImage], priorTurns: [ChatModelPriorTurn], maxTokens: Int) -> [String: Any] {
        var messages: [[String: Any]] = []
        for turn in priorTurns {
            messages.append(["role": "user", "content": turn.userText])
            messages.append(["role": "assistant", "content": turn.assistantText])
        }
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": userText])
        messages.append(["role": "user", "content": content])

        var body: [String: Any] = [
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages
        ]
        if let model { body["model"] = model }
        return body
    }

    private func send(_ requestBody: [String: Any], timeoutSeconds: TimeInterval) async throws -> [[String: Any]] {
        var request = URLRequest(url: claudeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let startedAt = Date()
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeChatError(message: "claude proxy returned an invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClaudeChatError(message: "claude failed (HTTP \(httpResponse.statusCode)): \(bodyText.prefix(300))")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = payload["content"] as? [[String: Any]] else {
            throw ClaudeChatError(message: "claude response had no content")
        }
        print("🧠 Claude: \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        return contentBlocks
    }
}
