//
//  ClinicalServiceClient.swift
//  leanring-buddy
//
//  Client for /clinical/check and /clinical/evidence on the analysis service.
//  The request body is built from concepts only (see ClinicalModePipeline).
//

import Foundation

nonisolated struct ClinicalFinding: Codable, Sendable {
    let type: String
    let medicationIds: [String]
    let severity: String
    let message: String
    let advice: String?
    let reference: String
}

nonisolated struct ClinicalCheckResponse: Codable, Sendable {
    let findings: [ClinicalFinding]
    let egfrUsed: Double?
    let egfrSource: String?
    let interactionsChecked: Int
    let medicationsRecognized: Int
    let summaryText: String
}

nonisolated struct EvidenceItem: Codable, Sendable {
    let kind: String
    let title: String
    let source: String
    let id: String
    let url: String
    let summary: String
    let disclosure: Bool
}

nonisolated struct EvidenceResponse: Codable, Sendable {
    let condition: String
    let items: [EvidenceItem]
    let spokenSummary: String
    let source: String
}

@MainActor
final class ClinicalServiceClient {
    private let baseURL: URL
    private let urlSession: URLSession
    private let jsonDecoder: JSONDecoder

    init(baseURL: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://127.0.0.1:8000")!
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.jsonDecoder = decoder
    }

    func check(payload: [String: Any]) async throws -> ClinicalCheckResponse {
        try await post(path: "clinical/check", payload: payload)
    }

    func evidence(condition: String, drug: String?) async throws -> EvidenceResponse {
        var payload: [String: Any] = ["condition": condition]
        if let drug { payload["drug"] = drug }
        return try await post(path: "clinical/evidence", payload: payload)
    }

    private func post<Response: Decodable>(path: String, payload: [String: Any]) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisServiceError(message: "clinical service returned an invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AnalysisServiceError(message: "clinical check failed (HTTP \(httpResponse.statusCode)): \(bodyText.prefix(200))")
        }
        return try jsonDecoder.decode(Response.self, from: data)
    }
}
