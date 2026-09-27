//
//  DataModePipeline.swift
//  leanring-buddy
//
//  Data mode: plan → analyze → draw → speak.
//
//  The planner (Fireworks, JSON-schema constrained) sees only column names,
//  types and the row count — never cell values — and picks a typed task. A
//  keyword planner covers the offline case. The analysis service returns row
//  ids, importances or curve points; drawings are built from those numbers
//  deterministically, and the spoken sentence is assembled from them too. The
//  LLM may rephrase the sentence but every number in it came from the service.
//

import Foundation

struct DataModePlan {
    /// Nil means "this is not a data question" → fall through to General mode.
    var task: AnalysisTask?
    var targetColumn: String?
    var groupColumn: String?
    var topK: Int
    var xColumn: String?
    var yColumn: String?
    /// Short phrase spoken immediately so the user hears something within a second.
    var fillerText: String
    var plannerSource: String
}

@MainActor
final class DataModePipeline {

    struct Outcome {
        let response: AnalysisResponse
        let primitives: [DrawingPrimitive]
        let spokenText: String
    }

    private let chatClient: FireworksChatClient
    private let analysisClient: AnalysisServiceClient

    init(chatClient: FireworksChatClient, analysisClient: AnalysisServiceClient) {
        self.chatClient = chatClient
        self.analysisClient = analysisClient
    }

    // MARK: - Planning

    private static let plannerSystemPrompt = """
    you route a spoken question about a spreadsheet to one analysis task. you only see column names and types, never data.

    tasks:
    - "anomaly": weird, odd, unusual, outliers, suspicious, errors, doesn't look right.
    - "drivers": what drives / predicts / explains / causes / matters for a target column; why do people churn; what's important for X. target_col must be one of the columns (pick the one the user means, e.g. "churn" → Churn).
    - "fit": fit a curve, trend line, regression, trend over time, relationship between two numeric columns (x_col, y_col).
    - "none": not a question about analyzing this table (general chat, how-to, navigation).

    group_col: only when the user says "per plan", "within each region", etc. k: how many rows to flag (default 6).
    filler: 3-6 lowercase words to say immediately while working, e.g. "looking for outliers" or "training on churn". reply with json only.
    """

    private static let plannerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": ["type": "string", "enum": ["anomaly", "drivers", "fit", "none"]],
            "target_col": ["type": ["string", "null"]],
            "group_col": ["type": ["string", "null"]],
            "k": ["type": ["integer", "null"]],
            "x_col": ["type": ["string", "null"]],
            "y_col": ["type": ["string", "null"]],
            "filler": ["type": "string"]
        ],
        "required": ["task", "target_col", "group_col", "k", "x_col", "y_col", "filler"]
    ]

    /// Fixed filler phrases so the speech client can synthesize them once at launch.
    static let fillerPhrases = ["looking for outliers", "training a model", "fitting a curve", "let me look"]

    /// Keyword routing first (no network, ~0ms). The language model is only asked
    /// when keywords find nothing and the caller allows it (forced Data mode).
    func plan(transcript: String, table: ExtractedTable, hasChart: Bool, allowLanguageModelFallback: Bool) async -> DataModePlan {
        let keywordPlan = Self.localPlan(transcript: transcript, table: table)
        if keywordPlan.task != nil || !allowLanguageModelFallback {
            return keywordPlan
        }

        let columnDescriptions = zip(table.headers, table.columnTypes).map { "\($0) (\($1.rawValue))" }.joined(separator: ", ")
        let userText = """
        columns: \(columnDescriptions)
        rows: \(table.rowCount)\(hasChart ? "\na chart with numeric axes is also on screen." : "")
        user said: "\(transcript)"
        """

        do {
            let responseObject = try await chatClient.completeJSON(
                systemPrompt: Self.plannerSystemPrompt,
                userText: userText,
                jsonSchema: Self.plannerSchema,
                maxTokens: 500,
                timeoutSeconds: 12
            )
            let taskName = (responseObject["task"] as? String) ?? "none"
            var plan = DataModePlan(
                task: AnalysisTask(rawValue: taskName),
                targetColumn: resolvedColumnName(responseObject["target_col"] as? String, in: table),
                groupColumn: resolvedColumnName(responseObject["group_col"] as? String, in: table),
                topK: min(max((responseObject["k"] as? Int) ?? 6, 1), 20),
                xColumn: resolvedColumnName(responseObject["x_col"] as? String, in: table),
                yColumn: resolvedColumnName(responseObject["y_col"] as? String, in: table),
                fillerText: (responseObject["filler"] as? String) ?? "looking",
                plannerSource: "fireworks"
            )
            // The model sometimes names a target that is not a column; fall back to keywords.
            if plan.task == .drivers, plan.targetColumn == nil {
                plan.targetColumn = Self.localPlan(transcript: transcript, table: table).targetColumn
            }
            return plan
        } catch {
            print("⚠️ Data planner fell back to keywords: \(error.localizedDescription)")
            return Self.localPlan(transcript: transcript, table: table)
        }
    }

    /// Offline planner: keyword routing plus fuzzy header matching. Also used to
    /// patch gaps in the model's plan.
    static func localPlan(transcript: String, table: ExtractedTable) -> DataModePlan {
        let lowered = transcript.lowercased()
        let mentionedColumns = table.headers.filter { header in
            let normalizedHeader = TableTextNormalizer.normalizeIdentifier(header)
            guard normalizedHeader.count >= 3 else { return false }
            return TableTextNormalizer.normalizeIdentifier(lowered).contains(normalizedHeader)
        }

        func containsAny(_ keywords: [String]) -> Bool { keywords.contains { lowered.contains($0) } }

        if containsAny(["weird", "odd", "unusual", "outlier", "anomal", "suspicious", "wrong", "strange", "stand out", "doesn't look right"]) {
            return DataModePlan(task: .anomaly, targetColumn: nil, groupColumn: nil, topK: 6, xColumn: nil, yColumn: nil,
                                fillerText: "looking for outliers", plannerSource: "keywords")
        }
        if containsAny(["fit", "trend", "curve", "regression", "relationship", "correlat"]) {
            let numericColumns = zip(table.headers, table.columnTypes).filter { $0.1 == .numeric }.map(\.0)
            let numericMentioned = mentionedColumns.filter { numericColumns.contains($0) }
            return DataModePlan(task: .fit, targetColumn: nil, groupColumn: nil, topK: 6,
                                xColumn: numericMentioned.first ?? numericColumns.first,
                                yColumn: numericMentioned.dropFirst().first ?? numericColumns.last,
                                fillerText: "fitting a curve", plannerSource: "keywords")
        }
        if containsAny(["drive", "driver", "predict", "explain", "cause", "important", "matter", "why", "influenc", "factor"]) {
            let target = mentionedColumns.first ?? table.headers.last
            return DataModePlan(task: .drivers, targetColumn: target, groupColumn: nil, topK: 6, xColumn: nil, yColumn: nil,
                                fillerText: "training a model", plannerSource: "keywords")
        }
        return DataModePlan(task: nil, targetColumn: nil, groupColumn: nil, topK: 6, xColumn: nil, yColumn: nil,
                            fillerText: "let me look", plannerSource: "keywords")
    }

    private func resolvedColumnName(_ requestedName: String?, in table: ExtractedTable) -> String? {
        guard let requestedName, !requestedName.isEmpty,
              let columnIndex = table.columnIndex(named: requestedName) else { return nil }
        return table.headers[columnIndex]
    }

    // MARK: - Analysis + drawing

    func run(plan: DataModePlan, table: ExtractedTable, chart: ChartRegion?) async throws -> Outcome {
        guard let task = plan.task else {
            throw AnalysisServiceError(message: "no analysis task planned")
        }

        let response = try await analysisClient.analyze(
            table: table,
            task: task,
            targetColumn: plan.targetColumn,
            groupColumn: plan.groupColumn,
            topK: plan.topK,
            xColumn: plan.xColumn,
            yColumn: plan.yColumn
        )

        let primitives = drawingPrimitives(for: response, table: table, chart: chart)
        let templateText = spokenTemplate(for: response, table: table, chart: chart)
        let spokenText = await polishedSpeech(from: templateText, transcript: plan.fillerText)
        return Outcome(response: response, primitives: primitives, spokenText: spokenText)
    }

    func drawingPrimitives(for response: AnalysisResponse, table: ExtractedTable, chart: ChartRegion?) -> [DrawingPrimitive] {
        switch response.task {
        case .anomaly:
            let rowIndices = response.anomaly?.rows.map(\.rowIndex) ?? []
            return DrawingOpsBuilder.circleRows(table: table, rowIndices: rowIndices)
        case .drivers:
            let importances = Dictionary(uniqueKeysWithValues: (response.drivers?.importances ?? []).map { ($0.column, $0.importance) })
            return DrawingOpsBuilder.barsUnderHeaders(table: table, importancesByColumnName: importances)
        case .fit:
            guard let fit = response.fit, let chart else { return [] }
            return DrawingOpsBuilder.curve(fit: fit, chart: chart)
        }
    }

    /// Deterministic sentence(s) built from the numbers only.
    func spokenTemplate(for response: AnalysisResponse, table: ExtractedTable, chart: ChartRegion?) -> String {
        switch response.task {
        case .anomaly:
            guard let anomaly = response.anomaly, !anomaly.rows.isEmpty else {
                return "nothing stands out in this table."
            }
            let visibleRows = anomaly.rows.filter { table.boundingBox(forRow: $0.rowIndex) != nil }
            var sentences = ["\(Self.countWord(anomaly.rows.count)) rows look unusual out of \(anomaly.nRowsScored)."]
            if visibleRows.count < anomaly.rows.count {
                sentences.append("\(Self.countWord(visibleRows.count)) of them are on screen and circled.")
            }
            for (position, row) in anomaly.rows.prefix(3).enumerated() {
                sentences.append("number \(Self.countWord(position + 1)), \(table.spokenRowLabel(forRow: row.rowIndex)): \(row.spokenReason).")
            }
            return sentences.joined(separator: " ")
        case .drivers:
            return response.summaryText
        case .fit:
            var text = response.summaryText
            if chart == nil {
                text += " i couldn't find a chart with numeric axes to draw it on."
            }
            return text
        }
    }

    /// Optional LLM rewrite for smoother speech. Keeps every number, ≤ 70 words,
    /// falls back to the template on any failure or slow response.
    private func polishedSpeech(from templateText: String, transcript: String) async -> String {
        guard SounderConfiguration.usesLLMNarration else { return templateText }
        let systemPrompt = """
        rewrite the following analysis result so it sounds like a friendly analyst talking, all lowercase, one breath, at most 70 words, no lists, no markdown. keep every number and every column name exactly as given, do not add facts, do not drop the row references. return only the rewritten speech.
        """
        do {
            let rewritten = try await chatClient.completeText(systemPrompt: systemPrompt, userText: templateText, maxTokens: 400, timeoutSeconds: 7)
            let trimmed = rewritten.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // Guard against a model that drops numbers: keep the template if any digit run went missing.
            let templateNumbers = Self.numberTokens(in: templateText)
            let rewrittenNumbers = Self.numberTokens(in: trimmed)
            guard !trimmed.isEmpty, templateNumbers.isSubset(of: rewrittenNumbers) else { return templateText }
            return trimmed
        } catch {
            return templateText
        }
    }

    private static func numberTokens(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    private static func countWord(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return count < words.count ? words[count] : String(count)
    }
}
