//
//  UserContextStore.swift
//  leanring-buddy
//
//  Context the user pins in the notch so Octo knows what they are working on:
//  notes, links (fetched once and kept as a text excerpt) and images. Items are
//  persisted under Application Support and folded into every model prompt as
//  background; the screen stays the primary subject. Nothing here is sent in
//  Rx mode's concept payload, only to the narration step.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct UserContextItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case link
        case image
    }

    let id: UUID
    let kind: Kind
    var title: String
    /// The note itself, the extracted page text for a link, or a caption for an image.
    var body: String
    var urlString: String?
    var imageFileName: String?
    let addedAt: Date
}

/// What a pipeline receives: one prompt block plus up to a couple of images.
struct UserContextBundle {
    let promptText: String
    let images: [ChatModelImage]
}

@MainActor
final class UserContextStore: ObservableObject {
    @Published private(set) var items: [UserContextItem] = []
    @Published private(set) var isFetchingLink = false

    private static let maximumItems = 12
    private static let maximumLinkExcerptCharacters = 4000
    private static let maximumImageWidth = 1280

    private let directoryURL: URL
    private var storeFileURL: URL { directoryURL.appendingPathComponent("context.json") }

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directoryURL = applicationSupport.appendingPathComponent("Octo/Context", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        load()
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Adding

    /// A typed or pasted string: a URL becomes a link, anything else a note.
    func add(fromInput input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.webURL(from: trimmed) {
            Task { await addLink(url) }
        } else {
            addText(trimmed)
        }
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let item = UserContextItem(id: UUID(), kind: .text, title: String(firstLine.prefix(60)), body: trimmed, urlString: nil, imageFileName: nil, addedAt: Date())
        append(item)
    }

    /// Fetches the page once, keeps its title and a plain-text excerpt.
    func addLink(_ url: URL) async {
        isFetchingLink = true
        defer { isFetchingLink = false }
        var title = url.host ?? url.absoluteString
        var excerpt = ""
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0 (Macintosh) Octo/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                if let pageTitle = Self.htmlTitle(in: html), !pageTitle.isEmpty { title = pageTitle }
                excerpt = String(Self.plainText(fromHTML: html).prefix(Self.maximumLinkExcerptCharacters))
            }
        } catch {
            print("📎 context: could not fetch \(url.absoluteString): \(error.localizedDescription)")
        }
        let item = UserContextItem(id: UUID(), kind: .link, title: String(title.prefix(80)), body: excerpt, urlString: url.absoluteString, imageFileName: nil, addedAt: Date())
        append(item)
    }

    func addImage(_ image: NSImage, title: String) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = NativeScreenCaptureUtility.makeDownscaledJPEG(from: cgImage, maximumWidth: Self.maximumImageWidth, compressionQuality: 0.8) else { return }
        let fileName = "\(UUID().uuidString).jpg"
        do {
            try jpeg.data.write(to: directoryURL.appendingPathComponent(fileName))
        } catch {
            print("📎 context: could not save image: \(error.localizedDescription)")
            return
        }
        let item = UserContextItem(id: UUID(), kind: .image, title: String(title.prefix(60)), body: "", urlString: nil, imageFileName: fileName, addedAt: Date())
        append(item)
    }

    func addImageFile(at fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return }
        addImage(image, title: fileURL.lastPathComponent)
    }

    /// Image, URL or text from the clipboard, in that order of preference.
    @discardableResult
    func addFromPasteboard() -> Bool {
        add(from: NSPasteboard.general)
    }

    /// Same, from any pasteboard (a drag's, for instance).
    @discardableResult
    func add(from pasteboard: NSPasteboard) -> Bool {
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            var addedAny = false
            for fileURL in fileURLs.prefix(6) {
                if UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) == true {
                    addImageFile(at: fileURL)
                    addedAny = true
                } else if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    addText("\(fileURL.lastPathComponent):\n\(text.prefix(4000))")
                    addedAny = true
                } else {
                    addText("file: \(fileURL.lastPathComponent) (\(fileURL.path))")
                    addedAny = true
                }
            }
            if addedAny { return true }
        }
        if let image = NSImage(pasteboard: pasteboard) {
            addImage(image, title: "Pasted image")
            return true
        }
        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(fromInput: string)
            return true
        }
        return false
    }

    func remove(_ item: UserContextItem) {
        if let imageFileName = item.imageFileName {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(imageFileName))
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.imageFileName != nil {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(item.imageFileName!))
        }
        items = []
        save()
    }

    func imageData(for item: UserContextItem) -> Data? {
        guard let imageFileName = item.imageFileName else { return nil }
        return try? Data(contentsOf: directoryURL.appendingPathComponent(imageFileName))
    }

    // MARK: - Prompt

    /// Everything pinned, as one prompt block plus images, or nil when empty.
    func promptBundle(maxCharacters: Int = 6000, maxImages: Int = 2) -> UserContextBundle? {
        guard !items.isEmpty else { return nil }
        var lines: [String] = []
        var images: [ChatModelImage] = []
        var remainingCharacters = maxCharacters
        for item in items {
            switch item.kind {
            case .text:
                let body = String(item.body.prefix(max(0, remainingCharacters)))
                remainingCharacters -= body.count
                lines.append("- note: \(body)")
            case .link:
                let excerpt = String(item.body.prefix(max(0, min(1500, remainingCharacters))))
                remainingCharacters -= excerpt.count
                lines.append("- link \"\(item.title)\" (\(item.urlString ?? "")): \(excerpt.isEmpty ? "(page text unavailable)" : excerpt)")
            case .image:
                if images.count < maxImages, let data = imageData(for: item) {
                    images.append(ChatModelImage(data: data, mimeType: "image/jpeg"))
                    lines.append("- image \"\(item.title)\" (attached after the screenshot)")
                } else {
                    lines.append("- image \"\(item.title)\" (not attached)")
                }
            }
            if remainingCharacters <= 0 { break }
        }
        let promptText = "context the user pinned in octo, to keep in mind while answering (background only; the screen is still the subject):\n" + lines.joined(separator: "\n")
        return UserContextBundle(promptText: promptText, images: images)
    }

    /// Text-only form for pipelines that never send images.
    func promptText(maxCharacters: Int = 4000) -> String? {
        promptBundle(maxCharacters: maxCharacters, maxImages: 0)?.promptText
    }

    // MARK: - Persistence

    private func append(_ item: UserContextItem) {
        items.append(item)
        if items.count > Self.maximumItems {
            let dropped = items.removeFirst()
            if let imageFileName = dropped.imageFileName {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(imageFileName))
            }
        }
        save()
        print("📎 context: added \(item.kind.rawValue) \"\(item.title)\" (\(items.count) items)")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeFileURL),
              let decoded = try? JSONDecoder().decode([UserContextItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeFileURL, options: .atomic)
    }

    // MARK: - Helpers

    static func webURL(from text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        var candidate = text
        if !candidate.lowercased().hasPrefix("http://") && !candidate.lowercased().hasPrefix("https://") {
            guard candidate.contains(".") else { return nil }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let match = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(html[match]).replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        return decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<nav[\s\S]*?</nav>"#, #"<!--[\s\S]*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&#8217;", "’"), ("&#8211;", "–")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
