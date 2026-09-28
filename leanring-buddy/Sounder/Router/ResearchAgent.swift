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

    struct MediaRequest {
        let query: String
        let preferredKind: MediaCard.Kind?
    }

    private static let mediaVerbs = ["show me", "show us", "pull up", "bring up", "find me", "find a", "find an", "find the", "look up", "get me", "can you find", "can you show", "could you find", "could you show", "search for", "google", "is there a", "i want to see", "let me see"]
    private static let mediaNouns: [(noun: String, kind: MediaCard.Kind)] = [
        ("paper", .paper), ("papers", .paper), ("study", .paper), ("studies", .paper), ("trial", .paper), ("article", .paper), ("research on", .paper), ("publication", .paper),
        ("image", .image), ("picture", .image), ("photo", .image), ("diagram of", .image), ("illustration", .image),
        ("video", .video), ("clip", .video), ("youtube", .video), ("tutorial", .video), ("lecture", .video),
        ("website", .link), ("web page", .link), ("documentation", .link), ("docs for", .link), ("a link", .link), ("the link", .link)
    ]
    /// Questions about doing something on this screen are never media lookups.
    private static let onScreenPhrases = ["how to", "how do i", "how can i", "where do i", "where is", "what are the steps", "walk me through", "on this page", "on this screen", "on my screen", "here"]

    /// Detects "show me a paper on…", "pull up a video of…", "find a picture of…"
    /// in any mode. Returns nil for ordinary questions so they route as before.
    static func mediaRequest(in transcript: String) -> MediaRequest? {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard mediaVerbs.contains(where: { lowered.contains($0) }) else { return nil }
        guard !onScreenPhrases.contains(where: { lowered.contains($0) }) else { return nil }
        guard let matchedNoun = mediaNouns.first(where: { lowered.contains($0.noun) }) else { return nil }
        return MediaRequest(query: transcript, preferredKind: matchedNoun.kind)
    }

    /// Finds one relevant paper, image or video for a query with web search and
    /// returns it as a card. The model answers in a fixed one-line format so no
    /// second structured call is needed. `screenContext` is OCR text from the
    /// user's screen so "a paper about this" resolves to what they are looking at.
    func findMedia(query: String, preferredKind: MediaCard.Kind?, screenContext: String?) async throws -> MediaCard {
        let kindHint = preferredKind.map { "the user wants a \($0.rawValue)." } ?? "pick the most useful kind: a paper (pubmed, doi, arxiv), a video (youtube), or an image."
        var userContent = "the user said: \"\(query)\""
        if let screenContext, !screenContext.isEmpty {
            userContent += "\n\ntext currently on their screen, for context when they say \"this\" or \"that\": \(screenContext.prefix(1500))"
        }
        let requestBody: [String: Any] = [
            "max_tokens": 400,
            "system": "you find one authoritative, directly relevant resource on the web for what the user asked to see. \(kindHint) reply with exactly one line and nothing else, in this format: KIND | TITLE | URL | SOURCE | IMAGE_URL. KIND is paper, image, video or link. SOURCE is the journal/site and year. IMAGE_URL is a direct image url (ending in .jpg, .png, .webp or .gif) when the kind is image, or a figure/thumbnail if you have one, otherwise the word none. the URL must be one you actually found in search results; for a paper prefer pubmed, doi.org, nejm, jama, thelancet or arxiv; for a video prefer youtube.",
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 4]],
            "messages": [["role": "user", "content": userContent]]
        ]
        var request = URLRequest(url: claudeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = payload["content"] as? [[String: Any]] else {
            throw ClaudeChatError(message: "media lookup failed")
        }
        let text = contentBlocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        print("🖼️ media lookup raw: \(text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))")
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.contains(" | ") }) else {
            throw ClaudeChatError(message: "media lookup returned no result line")
        }
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let url = URL(string: parts[2]) else {
            throw ClaudeChatError(message: "media lookup line was malformed")
        }
        let kind = MediaCard.Kind(rawValue: parts[0].lowercased()) ?? .link
        let source = parts.count > 3 ? parts[3] : ""
        let imageURL = parts.count > 4 && parts[4].lowercased() != "none" ? URL(string: parts[4]) : nil
        return MediaCard(kind: kind, title: parts[1], subtitle: source, url: url, imageURL: imageURL)
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
