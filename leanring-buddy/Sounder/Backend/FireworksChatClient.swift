//
//  FireworksChatClient.swift
//  leanring-buddy
//
//  OpenAI-compatible chat client that talks to Fireworks through the Worker's
//  /chat route. Supports image input (Set-of-Mark screenshots) and JSON-schema
//  constrained output, which is how the planner contract stays typed.
//

import Foundation

struct FireworksChatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class FireworksChatClient {
    struct ChatImage {
        let data: Data
        let mimeType: String
    }

    struct PriorTurn {
        let userText: String
        let assistantText: String
    }

    private let chatURL: URL
    /// Nil means "let the Worker choose its configured default model".
    private let model: String?
    private let urlSession: URLSession

    init(workerBaseURL: String, model: String?) {
        self.chatURL = URL(string: workerBaseURL)!.appendingPathComponent("chat")
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.urlSession = URLSession(configuration: configuration)
    }

    /// Asks the model for a JSON object that matches `jsonSchema` and returns it parsed.
    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatImage] = [],
        priorTurns: [PriorTurn] = [],
        jsonSchema: [String: Any],
        maxTokens: Int = 700,
        timeoutSeconds: TimeInterval = 25
    ) async throws -> [String: Any] {
        let responseText = try await complete(
            systemPrompt: systemPrompt,
            userText: userText,
            images: images,
            priorTurns: priorTurns,
            responseFormat: ["type": "json_object", "schema": jsonSchema],
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds
        )

        guard let jsonData = Self.extractJSONObjectText(from: responseText).data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw FireworksChatError(message: "model returned non-JSON content: \(responseText.prefix(200))")
        }
        return parsedObject
    }

    /// Plain text completion (used for speech narration).
    func completeText(
        systemPrompt: String,
        userText: String,
        maxTokens: Int = 400,
        timeoutSeconds: TimeInterval = 12
    ) async throws -> String {
        try await complete(
            systemPrompt: systemPrompt,
            userText: userText,
            images: [],
            priorTurns: [],
            responseFormat: nil,
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - Private

    private func complete(
        systemPrompt: String,
        userText: String,
        images: [ChatImage],
        priorTurns: [PriorTurn],
        responseFormat: [String: Any]?,
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]

        for turn in priorTurns {
            messages.append(["role": "user", "content": turn.userText])
            messages.append(["role": "assistant", "content": turn.assistantText])
        }

        if images.isEmpty {
            messages.append(["role": "user", "content": userText])
        } else {
            var contentParts: [[String: Any]] = []
            for image in images {
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"]
                ])
            }
            contentParts.append(["type": "text", "text": userText])
            messages.append(["role": "user", "content": contentParts])
        }

        var requestBody: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            // Reasoning models spend tokens thinking before answering; keep that short
            // so the planner stays inside the latency budget.
            "reasoning_effort": "low"
        ]
        if let model { requestBody["model"] = model }
        if let responseFormat { requestBody["response_format"] = responseFormat }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let startedAt = Date()
        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FireworksChatError(message: "chat proxy returned an invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw FireworksChatError(message: "chat failed (HTTP \(httpResponse.statusCode)): \(bodyText.prefix(300))")
        }

        guard let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw FireworksChatError(message: "chat response had no choices")
        }

        let content = (message["content"] as? String) ?? ""
        print("🧠 Fireworks chat: \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s, \(content.count) chars")

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FireworksChatError(message: "chat response was empty (reasoning may have consumed max_tokens)")
        }
        return content
    }

    /// Some models wrap JSON in ``` fences or prepend a sentence. Take the outermost {...}.
    nonisolated private static func extractJSONObjectText(from text: String) -> String {
        guard let openBrace = text.firstIndex(of: "{"), let closeBrace = text.lastIndex(of: "}"),
              openBrace < closeBrace else {
            return text
        }
        return String(text[openBrace...closeBrace])
    }
}
