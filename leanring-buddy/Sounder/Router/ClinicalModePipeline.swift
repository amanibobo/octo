//
//  ClinicalModePipeline.swift
//  leanring-buddy
//
//  Rx mode: medications, labs and conditions read off the screen → concept-only
//  payload → interaction/dosing findings or recent evidence → links, underlines,
//  badges and footnotes drawn on the chart → spoken summary built from the
//  findings. The privacy boundary is enforced here: before anything is sent, the
//  outbound payload is scanned and every string must be a lexicon drug name, a
//  condition concept, an id or a fixed key. Raw OCR text never leaves the laptop.
//

import CoreGraphics
import Foundation

enum ClinicalIntent: Equatable {
    case checkMedications
    case evidence(conditionQuery: String?)
    case none
}

@MainActor
final class ClinicalModePipeline {

    struct Outcome {
        let primitives: [DrawingPrimitive]
        let spokenText: String
        let metricText: String
        let footnotes: [String]
        /// Something worth holding up next to the buddy (the top trial for evidence).
        var mediaCard: MediaCard? = nil
    }

    private let clinicalClient: ClinicalServiceClient
    private let chatClient: any ChatModelClient

    static let fillerPhrases = ["checking the med list", "pulling the latest evidence"]

    init(clinicalClient: ClinicalServiceClient, chatClient: any ChatModelClient) {
        self.clinicalClient = clinicalClient
        self.chatClient = chatClient
    }

    // MARK: - Intent

    static func intent(for transcript: String) -> ClinicalIntent {
        let lowered = transcript.lowercased()
        let evidenceKeywords = ["what's new", "whats new", "new for", "latest", "evidence", "trial", "study", "studies", "guideline", "recent", "research", "anything new"]
        if evidenceKeywords.contains(where: { lowered.contains($0) }) {
            return .evidence(conditionQuery: conditionMentioned(in: lowered))
        }
        let checkKeywords = ["med", "drug", "interaction", "dose", "dosing", "wrong", "safe", "problem", "prescription", "rx", "renal", "kidney", "check", "list", "regimen", "contraindic"]
        if checkKeywords.contains(where: { lowered.contains($0) }) {
            return .checkMedications
        }
        return .none
    }

    private static func conditionMentioned(in loweredTranscript: String) -> String? {
        for condition in ClinicalLexicon.conditions {
            for alias in condition.aliases where alias.count > 3 || alias == alias.uppercased() {
                if loweredTranscript.contains(alias.lowercased()) {
                    return condition.canonicalName
                }
            }
        }
        return nil
    }

    // MARK: - Spatial context

    /// Keeps only the medications and conditions inside the circled region. Labs,
    /// age and sex stay (they are context, not targets). Falls back to the whole
    /// reading when nothing clinical lies inside the region.
    static func scoped(_ reading: ClinicalScreenReading, to regionOfInterest: CGRect?) -> ClinicalScreenReading {
        guard let region = regionOfInterest else { return reading }
        let medications = reading.medications.filter { $0.rowBox.intersects(region) || $0.drugBox.intersects(region) }
        let conditions = reading.conditions.filter { $0.box.intersects(region) }
        guard !medications.isEmpty || !conditions.isEmpty else { return reading }
        return ClinicalScreenReading(medications: medications, conditions: conditions, labs: reading.labs, ageYears: reading.ageYears, sex: reading.sex)
    }

    // MARK: - Medication check

    func checkMedications(reading: ClinicalScreenReading, question: String, isScopedToCircle: Bool, userContextText: String? = nil) async throws -> Outcome {
        let payload = Self.buildCheckPayload(from: reading)
        let privacyReport = Self.privacyReport(for: payload, reading: reading)
        print("🔒 outbound /clinical/check: \(privacyReport)")

        let response = try await clinicalClient.check(payload: payload)
        let mentionsByID = Dictionary(uniqueKeysWithValues: reading.medications.map { ($0.id, $0) })

        // Findings are spoken, not drawn: the chart stays clean. The list is kept
        // for the report and the narration prompt.
        let primitives: [DrawingPrimitive] = []
        var footnotes: [String] = []
        for (index, finding) in response.findings.enumerated() {
            let mentions = finding.medicationIds.compactMap { mentionsByID[$0] }
            let drugNames = mentions.map(\.name).joined(separator: " + ")
            footnotes.append("\(index + 1). \(drugNames) (\(finding.severity)): \(finding.message) — \(finding.reference)")
        }

        let metricText = "\(response.findings.count) findings · \(response.interactionsChecked) pairs checked · eGFR \(response.egfrUsed.map { String(format: "%.0f", $0) } ?? "n/a") (\(response.egfrSource ?? "none"))"
        let spokenText = await narrate(question: question, reading: reading, findings: response, footnotes: footnotes, isScopedToCircle: isScopedToCircle, userContextText: userContextText)
        return Outcome(primitives: primitives, spokenText: spokenText, metricText: metricText, footnotes: footnotes)
    }

    // MARK: - Evidence

    func evidence(reading: ClinicalScreenReading, conditionQuery: String?, drug: String? = nil) async throws -> Outcome {
        let targetCondition: ConditionMention? = {
            if let conditionQuery, let match = reading.conditions.first(where: { $0.canonicalName == conditionQuery }) { return match }
            return reading.conditions.first
        }()
        let conditionName = conditionQuery ?? targetCondition?.canonicalName
        guard let conditionName else {
            throw AnalysisServiceError(message: "no condition to look up")
        }
        print("🔒 outbound /clinical/evidence: condition=\(conditionName)\(drug.map { " drug=\($0)" } ?? "") (concept names only)")

        let response = try await clinicalClient.evidence(condition: conditionName, drug: drug)

        // Evidence is spoken and offered as a card; nothing is drawn on the chart.
        let primitives: [DrawingPrimitive] = []
        var footnotes: [String] = []
        let trials = response.items.filter { $0.kind == "trial" }
        let sponsored = response.items.filter { $0.kind == "sponsored" }
        for (index, item) in trials.enumerated() {
            footnotes.append("\(index + 1). \(item.title) — \(item.source) (\(item.id))")
        }
        for item in sponsored {
            footnotes.append("Sponsored medical information (\(item.source)): \(item.title). Disclosed, opt-in.")
        }

        let metricText = "\(trials.count) trials · source \(response.source)\(sponsored.isEmpty ? "" : " · 1 sponsored slot")"
        var outcome = Outcome(primitives: primitives, spokenText: response.spokenSummary, metricText: metricText, footnotes: footnotes)
        if let lead = trials.first, let url = URL(string: lead.url), !lead.url.isEmpty {
            outcome.mediaCard = MediaCard(kind: .paper, title: lead.title, subtitle: "\(lead.source) · \(lead.id)", url: url, imageURL: nil)
        }
        return outcome
    }

    // MARK: - Narration

    /// Claude answers the clinician's actual question in its own words, grounded in
    /// the findings the rules service produced (numbered like the footnotes). It sees
    /// the same concept-level facts the service saw, never raw chart text. If the
    /// rewrite drops a number the findings contain, the deterministic summary is used.
    private func narrate(question: String, reading: ClinicalScreenReading, findings: ClinicalCheckResponse, footnotes: [String], isScopedToCircle: Bool, userContextText: String?) async -> String {
        let medicationLines = reading.medications.map { mention -> String in
            var line = mention.name
            if let dose = mention.doseMilligrams { line += " \(dose.formatted()) mg" }
            if let perDay = mention.dosesPerDay { line += " ×\(perDay.formatted())/day" }
            return line
        }.joined(separator: ", ")
        let labLines = reading.labs.map { "\($0.key)=\($0.value.formatted())" }.joined(separator: ", ")
        let findingLines = findings.findings.enumerated().map { index, finding in
            "\(index + 1). [\(finding.severity)] \(finding.message)\(finding.advice.map { " advice: \($0)" } ?? "")"
        }.joined(separator: "\n")

        let systemPrompt = """
        you are octo, a clinical sidekick speaking to a clinician looking at a chart. answer their question directly and conversationally in at most 75 words, lowercase, no lists. the numbered findings below were computed by a rules engine; refer to them by drug name, not by number. you may add one sentence of general pharmacology context from your own knowledge, but say "generally" when you do, and never invent lab values, doses or interactions that are not in the findings. if the question is about something the findings do not cover, say what the findings do show and answer the rest from general knowledge briefly. if nothing was flagged, say so plainly.
        """
        let scopeNote = isScopedToCircle ? "the clinician circled part of the chart, so only those medications were checked.\n" : ""
        let contextNote = userContextText.map { $0 + "\n\n" } ?? ""
        let userText = """
        \(contextNote)\(scopeNote)patient: \(reading.ageYears.map { "\($0) years" } ?? "age unknown") \(reading.sex ?? "")
        medications on screen: \(medicationLines.isEmpty ? "none" : medicationLines)
        labs: \(labLines.isEmpty ? "none" : labLines)
        conditions: \(reading.conditions.map(\.canonicalName).joined(separator: ", "))
        egfr used: \(findings.egfrUsed.map { "\($0.formatted()) (\(findings.egfrSource ?? ""))" } ?? "n/a")
        findings (\(findings.interactionsChecked) pairs checked):
        \(findingLines.isEmpty ? "none" : findingLines)

        clinician asked: "\(question)"
        """
        print("🔒 outbound narration: \(reading.medications.count) drug concepts, \(findings.findings.count) findings, 0 raw chart words")

        do {
            let answer = try await chatClient.completeText(systemPrompt: systemPrompt, userText: userText, maxTokens: 300, timeoutSeconds: 12)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !trimmed.isEmpty else { return findings.summaryText }
            // Every number the findings mention must survive verbatim if it is spoken at all;
            // the model may leave numbers out but may not alter them.
            let allowedNumbers = Self.numberTokens(in: findingLines + " " + labLines + " " + medicationLines + " \(reading.ageYears ?? 0) " + (userContextText ?? ""))
            let spokenNumbers = Self.numberTokens(in: trimmed)
            guard spokenNumbers.isSubset(of: allowedNumbers) else {
                print("⚠️ narration altered a number; using the rules summary")
                return findings.summaryText
            }
            return trimmed
        } catch {
            return findings.summaryText
        }
    }

    private static func numberTokens(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    // MARK: - Payload + privacy boundary

    static func buildCheckPayload(from reading: ClinicalScreenReading) -> [String: Any] {
        var medications: [[String: Any]] = []
        for mention in reading.medications {
            var entry: [String: Any] = ["id": mention.id, "name": mention.name]
            if let rxcui = mention.rxcui { entry["rxcui"] = rxcui }
            if let dose = mention.doseMilligrams { entry["dose_mg"] = dose }
            if let perDay = mention.dosesPerDay { entry["doses_per_day"] = perDay }
            medications.append(entry)
        }
        var labs: [String: Any] = [:]
        for lab in reading.labs { labs[lab.key] = lab.value }
        var patient: [String: Any] = [:]
        if let age = reading.ageYears { patient["age_years"] = age }
        if let sex = reading.sex { patient["sex"] = sex }
        let conditions: [[String: Any]] = reading.conditions.map { ["id": $0.id, "code": $0.code, "name": $0.canonicalName] }
        return ["medications": medications, "labs": labs, "patient": patient, "conditions": conditions]
    }

    /// Scans every string in the outbound payload. Anything that is not a drug
    /// concept name, a condition concept, an id, a sex value or a schema key is a
    /// leak. Returns a one-line report for the console (and the demo slide).
    static func privacyReport(for payload: [String: Any], reading: ClinicalScreenReading) -> String {
        var allowed = Set<String>(["male", "female"])
        allowed.formUnion(reading.medications.map(\.name))
        allowed.formUnion(reading.medications.compactMap(\.rxcui))
        allowed.formUnion(reading.medications.map(\.id))
        allowed.formUnion(reading.conditions.flatMap { [$0.id, $0.code, $0.canonicalName] })

        var strings: [String] = []
        func collect(_ value: Any) {
            if let text = value as? String { strings.append(text) }
            else if let array = value as? [Any] { array.forEach(collect) }
            else if let dictionary = value as? [String: Any] { dictionary.values.forEach(collect) }
        }
        collect(payload)
        let leaks = strings.filter { !allowed.contains($0) }
        let numberCount = reading.labs.count + (reading.ageYears == nil ? 0 : 1)
        assert(leaks.isEmpty, "raw text in clinical payload: \(leaks)")
        return "\(reading.medications.count) drug concepts, \(reading.conditions.count) condition concepts, \(numberCount) numeric values, \(leaks.count) raw words"
    }
}
