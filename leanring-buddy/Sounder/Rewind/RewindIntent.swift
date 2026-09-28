//
//  RewindIntent.swift
//  leanring-buddy
//
//  Detects questions about the past ("what did that error say five minutes
//  ago?", "go back to the page I had open earlier") and pulls out the time hint.
//

import Foundation

struct RewindRequest {
    /// The question with the time phrase removed.
    let query: String
    /// How far back the user pointed, if they said ("five minutes ago" → 300).
    let targetAgeSeconds: TimeInterval?
}

enum RewindIntent {
    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "couple": 2, "few": 3, "half": 0.5,
    ]

    private static let agePattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:about|around|like|maybe)\s+)?(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty|fifty|couple(?: of)?|few|half an?)\s+(seconds?|secs?|minutes?|mins?|hours?|hrs?)\s+(?:ago|back|earlier)\b"#,
        options: .caseInsensitive
    )

    private static let rewindPhrases = [
        "ago", "earlier", "a while back", "a moment ago", "before that", "before this", "go back", "scroll back", "rewind",
        "what did that", "what did it say", "what did the", "what was that", "what was the error", "what was on", "what was in",
        "the last error", "the previous", "last message", "last screen", "last page", "that error", "that message", "that popup",
        "that dialog", "that warning", "what did i", "what was i",
    ]

    static func detect(_ transcript: String) -> RewindRequest? {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard rewindPhrases.contains(where: { lowered.contains($0) }) else { return nil }

        var targetAge: TimeInterval?
        var query = lowered
        let range = NSRange(lowered.startIndex..., in: lowered)
        if let match = agePattern.firstMatch(in: lowered, range: range),
           let amountRange = Range(match.range(at: 1), in: lowered),
           let unitRange = Range(match.range(at: 2), in: lowered) {
            let amountText = String(lowered[amountRange]).replacingOccurrences(of: " of", with: "").replacingOccurrences(of: "half an", with: "half").replacingOccurrences(of: "half a", with: "half")
            let amount = Double(amountText) ?? numberWords[amountText] ?? 1
            let unit = String(lowered[unitRange])
            let multiplier: Double = unit.hasPrefix("h") ? 3600 : (unit.hasPrefix("m") ? 60 : 1)
            targetAge = amount * multiplier
            if let wholeRange = Range(match.range, in: lowered) {
                query.removeSubrange(wholeRange)
            }
        }
        query = query.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return RewindRequest(query: query.isEmpty ? transcript : query, targetAgeSeconds: targetAge)
    }
}
