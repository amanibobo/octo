//
//  ClinicalEntityExtractor.swift
//  leanring-buddy
//
//  Turns OCR words into clinical entities entirely on device: medications with
//  dose and frequency (dictionary + regex), conditions (alias matching), labs,
//  age and sex. Every entity keeps its capture-pixel box so findings can be
//  drawn in place. This is the weak-supervision path the PRD describes; a
//  fine-tuned NER model would slot in here with the same output type.
//

import CoreGraphics
import Foundation

nonisolated struct MedicationMention: Sendable, Identifiable {
    let id: String
    let name: String
    let rxcui: String?
    let doseMilligrams: Double?
    let dosesPerDay: Double?
    let drugBox: CGRect
    let doseBox: CGRect?
    let frequencyBox: CGRect?
    let rowBox: CGRect
}

nonisolated struct ConditionMention: Sendable, Identifiable {
    let id: String
    let canonicalName: String
    let code: String
    let box: CGRect
}

nonisolated struct LabReading: Sendable {
    let key: String
    let value: Double
    let box: CGRect
}

nonisolated struct ClinicalScreenReading: Sendable {
    var medications: [MedicationMention]
    var conditions: [ConditionMention]
    var labs: [LabReading]
    var ageYears: Int?
    var sex: String?

    var isEmpty: Bool { medications.isEmpty && conditions.isEmpty }

    func lab(_ key: String) -> Double? {
        labs.first { $0.key == key }?.value
    }
}

nonisolated enum ClinicalEntityExtractor {

    private struct TextRow {
        var words: [RecognizedWord]
        var midY: CGFloat { words.map { $0.boundingBoxInCapturePixels.midY }.reduce(0, +) / CGFloat(max(words.count, 1)) }
        var box: CGRect { words.dropFirst().reduce(words[0].boundingBoxInCapturePixels) { $0.union($1.boundingBoxInCapturePixels) } }
    }

    // OCR cells arrive as one token ("1000 mg", "1.9 mg/dL"), so patterns match a
    // leading number with optional whitespace before the unit.
    private static let dosePattern = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*(mg|mcg|g|units?|meq|ml)\b"#, options: .caseInsensitive)
    private static let numberPattern = try! NSRegularExpression(pattern: #"^\d+(?:\.\d+)?$"#)
    private static let leadingNumberPattern = try! NSRegularExpression(pattern: #"^\d+(?:\.\d+)?"#)
    private static let agePattern = try! NSRegularExpression(pattern: #"\b(\d{1,3})\s*(?:y|yo|y/o|yr|yrs|years?|year-old|-year-old)\b"#, options: .caseInsensitive)

    private static let frequencyPerDay: [String: Double] = [
        "daily": 1, "qd": 1, "od": 1, "once": 1, "nightly": 1, "qhs": 1, "hs": 1, "qam": 1, "qpm": 1, "everyday": 1,
        "bid": 2, "twice": 2, "q12h": 2, "q12": 2,
        "tid": 3, "q8h": 3, "q8": 3, "thrice": 3,
        "qid": 4, "q6h": 4, "q6": 4,
        "weekly": 1.0 / 7.0, "qweek": 1.0 / 7.0, "qw": 1.0 / 7.0,
    ]

    static func extract(from lines: [RecognizedTextLine], lexicon: ClinicalLexicon) -> ClinicalScreenReading {
        let words = lines.flatMap(\.words).filter { !$0.text.isEmpty }
        guard !words.isEmpty else {
            return ClinicalScreenReading(medications: [], conditions: [], labs: [], ageYears: nil, sex: nil)
        }
        let medianHeight = TableExtractor.median(words.map { $0.boundingBoxInCapturePixels.height })
        let rows = clusterIntoRows(words, tolerance: medianHeight * 0.5)

        var medicationCandidates: [MedicationMention] = []
        var conditions: [ConditionMention] = []
        var labs: [LabReading] = []
        var ageYears: Int?
        var sex: String?

        for row in rows {
            let tokens = row.words.map { normalizeToken($0.text) }

            // Medications: single words, hyphen/slash parts, and two-word generics.
            var wordIndex = 0
            while wordIndex < row.words.count {
                var matchedName: String?
                var matchedWordCount = 1
                if wordIndex + 1 < row.words.count {
                    let twoWord = tokens[wordIndex] + " " + tokens[wordIndex + 1]
                    if twoWord.count >= 5, lexicon.isDrugName(twoWord) {
                        matchedName = twoWord
                        matchedWordCount = 2
                    }
                }
                if matchedName == nil, tokens[wordIndex].count >= 5, lexicon.isDrugName(tokens[wordIndex]) {
                    matchedName = tokens[wordIndex]
                }
                if matchedName == nil {
                    // "trimethoprim-sulfamethoxazole" → each part is its own concept.
                    for part in tokens[wordIndex].split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
                    where part.count >= 5 && lexicon.isDrugName(part) {
                        let box = row.words[wordIndex].boundingBoxInCapturePixels
                        let (dose, doseBox, frequency, frequencyBox) = doseAndFrequency(in: row, after: wordIndex, tokens: tokens)
                        medicationCandidates.append(MedicationMention(
                            id: "", name: part, rxcui: lexicon.rxcui(forDrugName: part), doseMilligrams: dose,
                            dosesPerDay: frequency, drugBox: box, doseBox: doseBox, frequencyBox: frequencyBox, rowBox: row.box))
                    }
                }
                if let matchedName {
                    let box = row.words[wordIndex..<(wordIndex + matchedWordCount)]
                        .dropFirst().reduce(row.words[wordIndex].boundingBoxInCapturePixels) { $0.union($1.boundingBoxInCapturePixels) }
                    let (dose, doseBox, frequency, frequencyBox) = doseAndFrequency(in: row, after: wordIndex + matchedWordCount - 1, tokens: tokens)
                    medicationCandidates.append(MedicationMention(
                        id: "", name: matchedName, rxcui: lexicon.rxcui(forDrugName: matchedName), doseMilligrams: dose,
                        dosesPerDay: frequency, drugBox: box, doseBox: doseBox, frequencyBox: frequencyBox, rowBox: row.box))
                    wordIndex += matchedWordCount
                    continue
                }
                wordIndex += 1
            }

            // Conditions: alias matching on consecutive tokens.
            for condition in ClinicalLexicon.conditions {
                for alias in condition.aliases {
                    let aliasTokens = alias.split(separator: " ").map { normalizeToken(String($0)) }
                    guard !aliasTokens.isEmpty, aliasTokens.count <= tokens.count else { continue }
                    let requiresExactCase = alias.count <= 3 && alias == alias.uppercased()
                    for start in 0...(tokens.count - aliasTokens.count) {
                        let slice = Array(tokens[start..<(start + aliasTokens.count)])
                        guard slice == aliasTokens else { continue }
                        if requiresExactCase, row.words[start].text.trimmingCharacters(in: .punctuationCharacters) != alias { continue }
                        let box = row.words[start..<(start + aliasTokens.count)]
                            .dropFirst().reduce(row.words[start].boundingBoxInCapturePixels) { $0.union($1.boundingBoxInCapturePixels) }
                        if !conditions.contains(where: { $0.canonicalName == condition.canonicalName }) {
                            conditions.append(ConditionMention(id: "c\(conditions.count + 1)", canonicalName: condition.canonicalName, code: condition.code, box: box))
                        }
                    }
                }
            }

            // Labs: "eGFR 38 mL/min", "Creatinine 1.9 mg/dL", "HbA1c 7.8 %".
            for (index, token) in tokens.enumerated() {
                guard let labKey = ClinicalLexicon.labKeys[token] else { continue }
                for nextIndex in (index + 1)..<min(index + 4, tokens.count) {
                    let candidate = tokens[nextIndex].replacingOccurrences(of: ",", with: "")
                    // "1.9 mg/dL" → 1.9; the first number after the lab name is the result,
                    // the reference range comes later in the row.
                    if let match = leadingNumberPattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                       let range = Range(match.range, in: candidate), let value = Double(candidate[range]) {
                        if !labs.contains(where: { $0.key == labKey }) {
                            labs.append(LabReading(key: labKey, value: value, box: row.words[nextIndex].boundingBoxInCapturePixels))
                        }
                        break
                    }
                }
            }

            // Age and sex.
            let rowText = row.words.map(\.text).joined(separator: " ")
            if ageYears == nil, let match = agePattern.firstMatch(in: rowText, range: NSRange(rowText.startIndex..., in: rowText)),
               let range = Range(match.range(at: 1), in: rowText), let age = Int(rowText[range]), (0...120).contains(age) {
                ageYears = age
            }
            if sex == nil {
                if tokens.contains(where: { $0 == "male" || $0 == "man" || $0 == "m" && tokens.contains("y") }) { sex = "male" }
                if tokens.contains(where: { $0 == "female" || $0 == "woman" }) { sex = "female" }
            }
        }

        // One mention per drug: prefer the one with a dose (the med list row) over prose mentions.
        var medications: [MedicationMention] = []
        for candidate in medicationCandidates {
            if let existingIndex = medications.firstIndex(where: { $0.name == candidate.name }) {
                if medications[existingIndex].doseMilligrams == nil, candidate.doseMilligrams != nil {
                    medications[existingIndex] = candidate
                }
                continue
            }
            medications.append(candidate)
        }
        medications = medications.enumerated().map { index, mention in
            MedicationMention(id: "m\(index + 1)", name: mention.name, rxcui: mention.rxcui, doseMilligrams: mention.doseMilligrams,
                              dosesPerDay: mention.dosesPerDay, drugBox: mention.drugBox, doseBox: mention.doseBox,
                              frequencyBox: mention.frequencyBox, rowBox: mention.rowBox)
        }

        return ClinicalScreenReading(medications: medications, conditions: conditions, labs: labs, ageYears: ageYears, sex: sex)
    }

    // MARK: - Helpers

    private static func doseAndFrequency(in row: TextRow, after drugIndex: Int, tokens: [String]) -> (Double?, CGRect?, Double?, CGRect?) {
        var dose: Double?
        var doseBox: CGRect?
        var frequency: Double?
        var frequencyBox: CGRect?
        var index = drugIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            let box = row.words[index].boundingBoxInCapturePixels
            if dose == nil {
                if let match = dosePattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                   let numberRange = Range(match.range(at: 1), in: token), let unitRange = Range(match.range(at: 2), in: token),
                   let number = Double(token[numberRange]) {
                    dose = milligrams(number, unit: String(token[unitRange]))
                    doseBox = box
                } else if numberPattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil,
                          index + 1 < tokens.count, let number = Double(token),
                          let converted = milligrams(number, unit: tokens[index + 1]) {
                    dose = converted
                    doseBox = box.union(row.words[index + 1].boundingBoxInCapturePixels)
                    index += 1
                }
            }
            if frequency == nil {
                // "po bid", "twice daily", "q12h" may share one token.
                for part in token.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init) {
                    if let perDay = frequencyPerDay[part] {
                        frequency = perDay
                        frequencyBox = box
                        break
                    }
                }
            }
            index += 1
        }
        return (dose, doseBox, frequency, frequencyBox)
    }

    private static func milligrams(_ value: Double, unit: String) -> Double? {
        switch unit.lowercased() {
        case "mg": return value
        case "mcg", "ug": return value / 1000
        case "g": return value * 1000
        default: return nil  // units, mEq, mL are not converted
        }
    }

    static func normalizeToken(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "-/")))
    }

    private static func clusterIntoRows(_ words: [RecognizedWord], tolerance: CGFloat) -> [TextRow] {
        let sorted = words.sorted { $0.boundingBoxInCapturePixels.midY < $1.boundingBoxInCapturePixels.midY }
        var rows: [TextRow] = []
        for word in sorted {
            if var last = rows.last, abs(word.boundingBoxInCapturePixels.midY - last.midY) <= tolerance {
                last.words.append(word)
                rows[rows.count - 1] = last
            } else {
                rows.append(TextRow(words: [word]))
            }
        }
        return rows.map { TextRow(words: $0.words.sorted { $0.boundingBoxInCapturePixels.minX < $1.boundingBoxInCapturePixels.minX }) }
    }
}
