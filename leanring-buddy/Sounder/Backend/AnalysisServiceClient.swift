//
//  AnalysisServiceClient.swift
//  leanring-buddy
//
//  Client for the Python analysis service (services/analysis). The service
//  trains/fits models on the extracted table and returns row ids, column
//  importances or curve points — never prose the app has to parse.
//

import Foundation

struct AnalysisServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AnalysisServiceClient {
    private let baseURL: URL
    private let urlSession: URLSession
    private let jsonDecoder: JSONDecoder

    init(baseURL: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://127.0.0.1:8000")!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.jsonDecoder = decoder
    }

    /// True when the service answers /health. Used for the panel status dot.
    func checkHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        guard let (_, response) = try? await urlSession.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        return (200...299).contains(httpResponse.statusCode)
    }

    func analyze(
        table: ExtractedTable,
        task: AnalysisTask,
        targetColumn: String?,
        groupColumn: String?,
        topK: Int,
        xColumn: String?,
        yColumn: String?
    ) async throws -> AnalysisResponse {
        var requestBody: [String: Any] = [
            "task": task.rawValue,
            "table": table.analysisPayload(),
            "k": topK
        ]
        if let targetColumn { requestBody["target_col"] = targetColumn }
        if let groupColumn { requestBody["group_col"] = groupColumn }
        if let xColumn { requestBody["x_col"] = xColumn }
        if let yColumn { requestBody["y_col"] = yColumn }

        var request = URLRequest(url: baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisServiceError(message: "analysis service returned an invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // FastAPI puts validation problems under "detail"; surface that text directly.
            if let errorPayload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = errorPayload["detail"] {
                throw AnalysisServiceError(message: "analysis failed: \(detail)")
            }
            let bodyText = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw AnalysisServiceError(message: "analysis failed (HTTP \(httpResponse.statusCode)): \(bodyText)")
        }

        return try jsonDecoder.decode(AnalysisResponse.self, from: responseData)
    }
}
