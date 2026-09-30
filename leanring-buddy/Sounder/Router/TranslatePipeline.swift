//
//  TranslatePipeline.swift
//  leanring-buddy
//
//  Translate in place. "translate this (to spanish)" takes the OCR lines in the
//  circled region (or every foreign line on screen), asks Claude for one
//  translation per line, and the overlay paints each translation exactly over
//  the original line, on a patch sampled from the pixels around it.
//

import CoreGraphics
import Foundation
import NaturalLanguage

struct TranslateRequest {
    let targetLanguageName: String
    let targetLanguage: NLLanguage
}

enum TranslateIntent {
    private static let languages: [(names: [String], code: NLLanguage, display: String)] = [
        (["english"], .english, "english"), (["spanish", "español"], .spanish, "spanish"), (["french", "français"], .french, "french"),
        (["german", "deutsch"], .german, "german"), (["italian"], .italian, "italian"), (["portuguese"], .portuguese, "portuguese"),
        (["japanese"], .japanese, "japanese"), (["chinese", "mandarin"], .simplifiedChinese, "chinese"), (["korean"], .korean, "korean"),
        (["arabic"], .arabic, "arabic"), (["hindi"], .hindi, "hindi"), (["russian"], .russian, "russian"), (["dutch"], .dutch, "dutch"),
        (["turkish"], .turkish, "turkish"), (["polish"], .polish, "polish"), (["swedish"], .swedish, "swedish"), (["vietnamese"], .vietnamese, "vietnamese"),
        (["thai"], .thai, "thai"), (["greek"], .greek, "greek"), (["hebrew"], .hebrew, "hebrew"), (["indonesian"], .indonesian, "indonesian"),
    ]

    static func detect(_ transcript: String) -> TranslateRequest? {
        let lowered = transcript.lowercased()
        guard lowered.contains("translat") || lowered.contains("in english") || lowered.contains("what does this say") else { return nil }
        // "to spanish", "into french", "in german"; default english.
        for entry in languages {
            for name in entry.names where lowered.contains(" to \(name)") || lowered.contains(" into \(name)") || lowered.contains(" in \(name)") {
                return TranslateRequest(targetLanguageName: entry.display, targetLanguage: entry.code)
            }
        }
        return TranslateRequest(targetLanguageName: "english", targetLanguage: .english)
    }

    /// Lines worth translating: real words, and (when not circled) not already in the target language.
    static func candidateLines(_ lines: [RecognizedTextLine], target: NLLanguage, isScoped: Bool) -> [RecognizedTextLine] {
        let recognizer = NLLanguageRecognizer()
        return lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 2 else { return false }
            if isScoped { return true }
            recognizer.reset()
            recognizer.processString(text)
            guard let dominant = recognizer.dominantLanguage else { return false }
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
            return dominant != target && confidence >= 0.6 && letters >= 4
        }
    }
}

@MainActor
final class TranslatePipeline {
    private let chatClient: any ChatModelClient

    init(chatClient: any ChatModelClient) {
        self.chatClient = chatClient
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": ["type": "array", "items": ["type": "object", "properties": ["index": ["type": "integer"], "text": ["type": "string"]], "required": ["index", "text"]]]
        ],
        "required": ["translations"]
    ]

    /// One translation per input line, by index. Missing indices are left untranslated.
    func translate(lines: [String], to targetLanguageName: String) async throws -> [Int: String] {
        let numbered = lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let object = try await chatClient.completeJSON(
            systemPrompt: "you translate screen text line by line into \(targetLanguageName). each input line is one entry: return the same index with its translation. keep numbers, names, units and codes as they are; keep each translation about as long as the original so it fits in the same space; keep the same casing style. no commentary.",
            userText: numbered,
            images: [],
            priorTurns: [],
            jsonSchema: Self.schema,
            maxTokens: 4000,
            timeoutSeconds: 35,
            effort: "low"
        )
        var result: [Int: String] = [:]
        for entry in (object["translations"] as? [[String: Any]]) ?? [] {
            if let index = entry["index"] as? Int, let text = entry["text"] as? String, index >= 0, index < lines.count {
                result[index] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}

/// Average colour of the pixels just outside a text box, so a patch painted over
/// the box matches the page behind the text.
nonisolated enum BackgroundColorSampler {
    struct RGB: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    static func sample(_ image: CGImage, around rect: CGRect) -> RGB {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Two thin strips: above and below the box (text ink rarely reaches them).
        let strips = [
            CGRect(x: rect.minX, y: rect.minY - 4, width: rect.width, height: 3),
            CGRect(x: rect.minX, y: rect.maxY + 1, width: rect.width, height: 3),
        ].map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        var total = (0.0, 0.0, 0.0)
        var count = 0.0
        for strip in strips {
            guard let cropped = image.cropping(to: strip.integral) else { continue }
            let width = cropped.width, height = cropped.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            var offset = 0
            while offset + 3 < pixels.count {
                total.0 += Double(pixels[offset]); total.1 += Double(pixels[offset + 1]); total.2 += Double(pixels[offset + 2])
                count += 1
                offset += 4
            }
        }
        guard count > 0 else { return RGB(red: 1, green: 1, blue: 1) }
        return RGB(red: total.0 / count / 255, green: total.1 / count / 255, blue: total.2 / count / 255)
    }
}
