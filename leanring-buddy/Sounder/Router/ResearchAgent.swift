//
//  ResearchAgent.swift
//  leanring-buddy
//
//  Quick "how do I do this in that app?" research before Agent mode acts on a
//  task it may not know well. One Claude call with the server-side web search
//  tool returns a short numbered plan; the plan is shown in the drawer beside
//  the buddy and handed to the agent as notes. Skipped for tasks the agent
//  handles natively (Spotify, Safari, Finder, Notes, Messages, Mail).
//

import Foundation

struct ResearchNotes {
    let steps: [String]
    let sourceTitles: [String]

    var asPromptText: String {
        steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

@MainActor
final class ResearchAgent {

    private let claudeURL: URL
    private let urlSession: URLSession

    private static let familiarApps = ["spotify", "safari", "chrome", "finder", "notes", "messages", "mail", "calendar", "terminal", "music", "system settings"]

    init(workerBaseURL: String) {
        self.claudeURL = URL(string: workerBaseURL)!.appendingPathComponent("claude")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 40
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
    }

    /// Research only when the task names an app the agent has no built-in playbook for.
    static func needsResearch(for task: String) -> Bool {
        let lowered = task.lowercased()
        let mentionsFamiliarApp = familiarApps.contains { lowered.contains($0) }
        let mentionsAnApp = lowered.contains(" in ") || lowered.contains("open ") || lowered.contains(" app")
        return mentionsAnApp && !mentionsFamiliarApp
    }

    /// Asks Claude (with web search, at most 3 searches) for a 3–6 step plan.
    func research(task: String) async throws -> ResearchNotes {
        let requestBody: [String: Any] = [
            "max_tokens": 700,
            "system": "you research how to accomplish a task on macOS in a specific app, then answer with a short numbered plan of concrete ui steps (menus, shortcuts, buttons), 3 to 6 lines, nothing else. lowercase.",
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]],
            "messages": [["role": "user", "content": "how do i do this on a mac: \"\(task)\""]]
        ]
        var request = URLRequest(url: claudeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let startedAt = Date()
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = payload["content"] as? [[String: Any]] else {
            throw ClaudeChatError(message: "research request failed")
        }

        var text = ""
        var sourceTitles: [String] = []
        for block in contentBlocks {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String ?? "") + "\n"
            case "web_search_tool_result":
                for result in (block["content"] as? [[String: Any]]) ?? [] {
                    if let title = result["title"] as? String { sourceTitles.append(title) }
                }
            default:
                break
            }
        }
        let steps = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                // strip "1." / "1)" / "-" prefixes; the drawer numbers lines itself
                var cleaned = line
                while let first = cleaned.first, first.isNumber || first == "." || first == ")" || first == "-" || first == " " {
                    cleaned.removeFirst()
                }
                return cleaned
            }
            .filter { !$0.isEmpty }
        print("🔎 research: \(steps.count) steps, \(sourceTitles.count) sources in \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
        return ResearchNotes(steps: Array(steps.prefix(6)), sourceTitles: Array(Set(sourceTitles)).prefix(3).map { $0 })
    }
}
