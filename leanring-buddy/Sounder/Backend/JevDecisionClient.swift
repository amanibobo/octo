//
//  JevDecisionClient.swift
//  leanring-buddy
//
//  Jev (TypeSafe AI's "System One" model) through the Worker's /jev route. It
//  generates no text: it takes a state and typed questions and returns typed
//  answers with probabilities in ~100 ms. Octo uses it at decision points where
//  the answer set is known in advance (which feature a request is for, whether an
//  action worked, whether an action is irreversible). Every caller treats a
//  failure or a low confidence as "no opinion" and falls back to what it did before.
//

import Foundation

struct JevChoiceAnswer {
    let choice: String
    let probabilities: [String: Double]
    let confidence: Double
}

struct JevError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class JevDecisionClient {
    private let jevURL: URL
    private let urlSession: URLSession
    /// Set from the Worker's /health: false means every call short-circuits.
    var isConfigured = false

    init(workerBaseURL: String) {
        self.jevURL = URL(string: workerBaseURL)!.appendingPathComponent("jev")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.urlSession = URLSession(configuration: configuration)
    }

    /// One option out of a known set. `options` maps option id → what it means.
    func choice(state: String, instructions: String, options: [String: String], timeoutSeconds: TimeInterval = 2.5) async throws -> JevChoiceAnswer {
        let answers = try await decide(state: state, questions: [
            "answer": ["type": "choice", "instructions": instructions, "criteria": options]
        ], timeoutSeconds: timeoutSeconds)
        guard let answer = answers["answer"] as? [String: Any], let choice = answer["choice"] as? String else {
            throw JevError(message: "jev returned no choice")
        }
        let probabilities = (answer["probabilities"] as? [String: Double]) ?? [:]
        return JevChoiceAnswer(choice: choice, probabilities: probabilities, confidence: (answer["confidence"] as? Double) ?? probabilities[choice] ?? 0)
    }

    /// The probability (0…1) that a statement about the state is true.
    func noul(state: String, instructions: String, whenTrue: String? = nil, whenFalse: String? = nil, timeoutSeconds: TimeInterval = 2.5) async throws -> Double {
        var question: [String: Any] = ["type": "noul", "instructions": instructions]
        if let whenTrue, let whenFalse { question["criteria"] = ["true": whenTrue, "false": whenFalse] }
        let answers = try await decide(state: state, questions: ["answer": question], timeoutSeconds: timeoutSeconds)
        guard let answer = answers["answer"] as? [String: Any], let probability = answer["noul"] as? Double else {
            throw JevError(message: "jev returned no probability")
        }
        return probability
    }

    /// Raw call: several questions over one state, answers keyed by question id.
    func decide(state: String, questions: [String: [String: Any]], timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        guard isConfigured else { throw JevError(message: "jev is not configured on the proxy") }
        let body: [String: Any] = ["state": state, "questions": questions]
        var request = URLRequest(url: jevURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let startedAt = Date()
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw JevError(message: "no http response") }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JevError(message: "jev failed (HTTP \(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else {
            throw JevError(message: "jev response had no answers")
        }
        print("⚡️ jev: \(String(format: "%.0f", Date().timeIntervalSince(startedAt) * 1000)) ms · \(questions.count) question(s)")
        return answers
    }
}
