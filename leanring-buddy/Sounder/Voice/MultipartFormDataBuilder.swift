//
//  MultipartFormDataBuilder.swift
//  leanring-buddy
//
//  Minimal multipart/form-data encoder for audio uploads.
//

import Foundation

nonisolated struct MultipartFormDataBuilder {
    let boundary = "SounderBoundary-\(UUID().uuidString)"
    private var body = Data()

    var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func appendField(name: String, value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, fileData: Data) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")
    }

    func finalizedBody() -> Data {
        var finalBody = body
        finalBody.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return finalBody
    }

    private mutating func appendString(_ string: String) {
        body.append(string.data(using: .utf8)!)
    }
}
