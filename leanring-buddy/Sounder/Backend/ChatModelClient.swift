//
//  ChatModelClient.swift
//  leanring-buddy
//
//  Abstraction over the language model used for planning, grounding and
//  narration, so Claude (default) and Fireworks are interchangeable.
//

import Foundation

struct ChatModelImage {
    let data: Data
    let mimeType: String
}

struct ChatModelPriorTurn {
    let userText: String
    let assistantText: String
}

@MainActor
protocol ChatModelClient: AnyObject {
    var displayName: String { get }

    /// Returns a JSON object matching `jsonSchema`. `effort` is the model's
    /// reasoning effort ("low" … "xhigh"); nil leaves the provider default.
    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatModelImage],
        priorTurns: [ChatModelPriorTurn],
        jsonSchema: [String: Any],
        maxTokens: Int,
        timeoutSeconds: TimeInterval,
        effort: String?
    ) async throws -> [String: Any]

    func completeText(
        systemPrompt: String,
        userText: String,
        maxTokens: Int,
        timeoutSeconds: TimeInterval,
        effort: String?
    ) async throws -> String
}

extension ChatModelClient {
    func completeJSON(
        systemPrompt: String,
        userText: String,
        images: [ChatModelImage] = [],
        priorTurns: [ChatModelPriorTurn] = [],
        jsonSchema: [String: Any],
        maxTokens: Int = 1200,
        timeoutSeconds: TimeInterval = 30,
        effort: String? = nil
    ) async throws -> [String: Any] {
        try await completeJSON(systemPrompt: systemPrompt, userText: userText, images: images, priorTurns: priorTurns,
                               jsonSchema: jsonSchema, maxTokens: maxTokens, timeoutSeconds: timeoutSeconds, effort: effort)
    }

    func completeText(systemPrompt: String, userText: String, maxTokens: Int = 600, timeoutSeconds: TimeInterval = 15, effort: String? = nil) async throws -> String {
        try await completeText(systemPrompt: systemPrompt, userText: userText, maxTokens: maxTokens, timeoutSeconds: timeoutSeconds, effort: effort)
    }
}

/// Small JSON-schema utilities for strict, per-turn tool schemas.
enum JSONSchemaTools {
    /// Makes every object in the schema strict: `additionalProperties: false` and
    /// every property required (nullable properties stay nullable). Required by
    /// the API's strict tool mode, which then guarantees the input validates.
    static func strict(_ schema: [String: Any]) -> [String: Any] {
        var result = schema
        if let type = schema["type"] as? String, type == "object" {
            result["additionalProperties"] = false
            if let properties = schema["properties"] as? [String: Any] {
                var strictProperties: [String: Any] = [:]
                for (key, value) in properties {
                    strictProperties[key] = (value as? [String: Any]).map(strict) ?? value
                }
                result["properties"] = strictProperties
                result["required"] = Array(properties.keys).sorted()
            }
        }
        if let items = schema["items"] as? [String: Any] {
            result["items"] = strict(items)
        }
        return result
    }

    /// Returns a copy with `enum: values` set on the schema at `path` (property
    /// names, with "items" for array elements). Used to allow only the element ids
    /// that exist on this turn, so an unlisted id cannot be emitted at all.
    /// Sets `enum` on a leaf. Strict mode rejects `enum` next to a `["x", "null"]`
    /// type, so a nullable leaf becomes `anyOf: [{type: x, enum: [...]}, {type: null}]`.
    static func nullableEnum(_ schema: [String: Any], values: [Any]) -> [String: Any] {
        var leaf = schema
        let concreteValues = values.filter { !($0 is NSNull) }
        let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map { [$0] } ?? []
        if types.contains("null") {
            let concreteTypes = types.filter { $0 != "null" }
            let concreteType: Any = concreteTypes.count == 1 ? concreteTypes[0] : concreteTypes
            leaf["type"] = nil
            leaf["enum"] = nil
            leaf["anyOf"] = [["type": concreteType, "enum": concreteValues] as [String: Any], ["type": "null"] as [String: Any]]
        } else {
            leaf["enum"] = concreteValues
        }
        return leaf
    }

    static func settingEnum(_ schema: [String: Any], atPath path: [String], values: [Any]) -> [String: Any] {
        guard let first = path.first else {
            return nullableEnum(schema, values: values)
        }
        var result = schema
        if first == "items", let items = schema["items"] as? [String: Any] {
            result["items"] = settingEnum(items, atPath: Array(path.dropFirst()), values: values)
        } else if var properties = schema["properties"] as? [String: Any], let child = properties[first] as? [String: Any] {
            properties[first] = settingEnum(child, atPath: Array(path.dropFirst()), values: values)
            result["properties"] = properties
        }
        return result
    }
}
