//
//  ReadingIntents.swift
//  leanring-buddy
//
//  Reading features. Read-aloud ("read this to me"): OCR lines become
//  paragraphs and sentences, each sentence is spoken while its lines are
//  highlighted; the hotkey interrupts for "skip this section", "explain that",
//  "go back", "stop". Make-readable ("make this readable"): structure drawn
//  over a dense page. Rewrite ("clearer", "fix this paragraph"): a circled
//  paragraph rewritten in place with the changes marked.
//

import CoreGraphics
import Foundation
import NaturalLanguage

// MARK: - Read aloud

struct ReadAloudSentence {
    let text: String
    let lineIndices: [Int]
    let paragraphIndex: Int
}

struct ReadAloudScript {
    let lines: [RecognizedTextLine]
    let sentences: [ReadAloudSentence]
    let paragraphCount: Int

    /// Groups lines into paragraphs by vertical gaps and heading-like lines, joins
    /// each paragraph's text, and splits it into sentences that remember which
    /// lines they cover.
    static func build(from lines: [RecognizedTextLine]) -> ReadAloudScript {
        let ordered = lines
            .filter { $0.text.trimmingCharacters(in: .whitespaces).count >= 2 }
            .sorted { abs($0.boundingBoxInCapturePixels.minY - $1.boundingBoxInCapturePixels.minY) > 6
                ? $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY
                : $0.boundingBoxInCapturePixels.minX < $1.boundingBoxInCapturePixels.minX }
        guard !ordered.isEmpty else { return ReadAloudScript(lines: [], sentences: [], paragraphCount: 0) }
        let heights = ordered.map(\.boundingBoxInCapturePixels.height).sorted()
        let medianHeight = max(heights[heights.count / 2], 4)

        // Paragraphs: a gap taller than ~1.3 lines, or a short heading-like line, starts a new one.
        var paragraphs: [[Int]] = [[0]]
        for index in 1..<ordered.count {
            let previous = ordered[index - 1].boundingBoxInCapturePixels
            let current = ordered[index].boundingBoxInCapturePixels
            let gap = current.minY - previous.maxY
            let previousIsHeading = ordered[index - 1].text.count <= 60 && !ordered[index - 1].text.hasSuffix(".") && previous.height > medianHeight * 1.25
            if gap > medianHeight * 1.3 || previousIsHeading || current.height > medianHeight * 1.25 {
                paragraphs.append([index])
            } else {
                paragraphs[paragraphs.count - 1].append(index)
            }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        var sentences: [ReadAloudSentence] = []
        for (paragraphIndex, lineIndices) in paragraphs.enumerated() {
            // Join lines, remembering where each line starts in the joined string.
            var joined = ""
            var lineStarts: [(start: Int, lineIndex: Int)] = []
            for lineIndex in lineIndices {
                var text = ordered[lineIndex].text.trimmingCharacters(in: .whitespaces)
                if text.hasSuffix("-"), text.count > 2 { text.removeLast() } else { text += " " }
                lineStarts.append((joined.count, lineIndex))
                joined += text
            }
            tokenizer.string = joined
            tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
                let sentence = joined[range].trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count >= 2 else { return true }
                let startOffset = joined.distance(from: joined.startIndex, to: range.lowerBound)
                let endOffset = joined.distance(from: joined.startIndex, to: range.upperBound)
                var covered: [Int] = []
                for (position, entry) in lineStarts.enumerated() {
                    let lineEnd = position + 1 < lineStarts.count ? lineStarts[position + 1].start : joined.count
                    if entry.start < endOffset && lineEnd > startOffset { covered.append(entry.lineIndex) }
                }
                sentences.append(ReadAloudSentence(text: sentence, lineIndices: covered, paragraphIndex: paragraphIndex))
                return true
            }
        }
        return ReadAloudScript(lines: ordered, sentences: sentences, paragraphCount: paragraphs.count)
    }
}

enum ReadAloudIntent {
    enum Command {
        case start
        case skipSection
        case explain
        case back
        case resume
        case stop
    }

    private static let startPhrases = ["read this to me", "read it to me", "read this out loud", "read this aloud", "read this page to me", "read the page to me",
                                       "read this article", "read this doc", "read this document", "read this for me", "read to me", "read this"]
    private static let skipPhrases = ["skip this section", "skip this part", "skip this", "skip ahead", "next section", "skip that", "next part", "move on", "skip it", "skip", "next"]
    private static let explainPhrases = ["explain that", "explain this", "what does that mean", "what does this mean", "explain", "what did that mean", "say more about that"]
    private static let backPhrases = ["go back", "read that again", "say that again", "repeat that", "one more time", "back up"]
    private static let resumePhrases = ["continue", "keep going", "keep reading", "resume", "go on", "carry on"]
    private static let stopPhrases = ["stop reading", "that's enough", "stop", "enough", "pause", "hold on"]

    static func startRequested(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        return startPhrases.contains { lowered.contains($0) }
    }

    /// Commands that only make sense while reading.
    static func command(whileReading transcript: String) -> Command? {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if skipPhrases.contains(where: { lowered.contains($0) }) { return .skipSection }
        if backPhrases.contains(where: { lowered.contains($0) }) { return .back }
        if resumePhrases.contains(where: { lowered.hasPrefix($0) }) { return .resume }
        if stopPhrases.contains(where: { lowered.hasPrefix($0) || lowered == $0 }) { return .stop }
        if explainPhrases.contains(where: { lowered.hasPrefix($0) || lowered.contains(" " + $0) }) { return .explain }
        return nil
    }
}

// MARK: - Make readable

enum ReadableIntent {
    private static let phrases = ["make this readable", "make it readable", "structure this", "give this structure", "highlight the key points", "highlight key points",
                                  "what matters here", "break this down", "what's important here", "whats important here", "outline this", "mark this up",
                                  "annotate this", "make this easier to read", "make sense of this"]

    static func matches(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        return phrases.contains { lowered.contains($0) }
    }
}

// MARK: - Rewrite in place

struct RewriteRequest {
    let instruction: String
}

enum RewriteIntent {
    /// Only with a circled region: a one-word style ("clearer") or a fix request.
    static func detect(_ transcript: String) -> RewriteRequest? {
        let lowered = transcript.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let styles: [(String, String)] = [
            ("clearer", "make it clearer and easier to read"), ("clear", "make it clearer and easier to read"), ("simpler", "make it simpler"),
            ("shorter", "make it shorter without losing meaning"), ("tighter", "make it tighter"), ("longer", "expand it a little"),
            ("formal", "make it more formal"), ("more formal", "make it more formal"), ("casual", "make it more casual"), ("friendlier", "make it friendlier"),
            ("professional", "make it more professional"), ("concise", "make it concise"), ("punchier", "make it punchier"),
        ]
        for (word, instruction) in styles where lowered == word || lowered == "make it " + word || lowered == "make this " + word || lowered == "make that " + word {
            return RewriteRequest(instruction: instruction)
        }
        let fixPhrases = ["fix this", "fix that", "fix the grammar", "fix grammar", "proofread", "rewrite this", "rewrite that", "rewrite", "improve this", "polish this", "clean this up", "reword"]
        if fixPhrases.contains(where: { lowered.hasPrefix($0) || lowered.contains(" " + $0) }) {
            return RewriteRequest(instruction: lowered.contains("grammar") || lowered.contains("proofread") ? "fix grammar, spelling and punctuation only" : "rewrite it to be clearer and better written, keeping the meaning")
        }
        return nil
    }
}
