//
//  Grounding eval harness.
//
//  Runs saved screenshots through the real pipeline (Vision OCR → Set-of-Mark
//  elements → GeneralModePipeline via the proxy) and checks whether the element
//  Octo points at or highlights contains the expected text. Compares the zoom
//  pass on and off so grounding changes are measured, not guessed.
//
//  cases/<name>/screenshot.png   native-resolution capture
//  cases/<name>/cases.json       [{"question": "...", "expect": "quote", "where": "point"|"highlight"|"any"}]
//
//  ./run.sh --dump               list numbered OCR lines per case (to write questions)
//  ./run.sh [--zoom] [--only name] [--worker URL]
//

import AppKit
import Foundation
import Vision

struct EvalCase: Decodable {
    let question: String
    let expect: String
    let `where`: String?
}

struct CaseOutcome: Encodable {
    let screenshot: String
    let question: String
    let expect: String
    let passed: Bool
    let pointedText: String?
    let highlightedTexts: [String]
    let seconds: Double
    let error: String?
}

func normalize(_ text: String) -> String {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

func loadImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

let arguments = CommandLine.arguments
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(after name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let harnessDirectory = URL(fileURLWithPath: value(after: "--root") ?? FileManager.default.currentDirectoryPath)
let casesDirectory = harnessDirectory.appendingPathComponent("cases")
let workerBaseURL = value(after: "--worker") ?? ProcessInfo.processInfo.environment["OCTO_WORKER_URL"] ?? "https://octo-proxy.vercel.app"
let onlyCase = value(after: "--only")
let dumpOnly = flag("--dump")
GeneralModePipeline.isZoomPassEnabled = flag("--zoom")

let caseDirectories = ((try? FileManager.default.contentsOfDirectory(at: casesDirectory, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.hasDirectoryPath && (onlyCase == nil || $0.lastPathComponent == onlyCase) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

if caseDirectories.isEmpty {
    print("no cases under \(casesDirectory.path)")
    exit(1)
}

let pipeline = GeneralModePipeline(chatClient: ClaudeChatClient(workerBaseURL: workerBaseURL, model: nil))
var outcomes: [CaseOutcome] = []

for caseDirectory in caseDirectories {
    let name = caseDirectory.lastPathComponent
    guard let image = loadImage(at: caseDirectory.appendingPathComponent("screenshot.png")) else {
        print("⚠️ \(name): no screenshot.png")
        continue
    }
    let ocrStartedAt = Date()
    let textLines = try await Task.detached { try ScreenTextRecognizer.recognizeText(in: image) }.value
    let elements = ScreenElementDetector.makeElements(from: textLines)
    print("\n━━ \(name): \(image.width)×\(image.height) px, \(textLines.count) lines in \(String(format: "%.2f", Date().timeIntervalSince(ocrStartedAt)))s")

    if dumpOnly {
        for element in elements {
            let box = element.boundingBoxInCapturePixels
            print("[\(element.id)] h\(Int(box.height)) @(\(Int(box.minX)),\(Int(box.minY))) \(element.text)")
        }
        continue
    }

    let casesURL = caseDirectory.appendingPathComponent("cases.json")
    guard let casesData = try? Data(contentsOf: casesURL), let cases = try? JSONDecoder().decode([EvalCase].self, from: casesData) else {
        print("⚠️ \(name): no cases.json")
        continue
    }
    let capture = SounderScreenCapture(
        cgImage: image,
        geometry: CaptureGeometry(captureWidthInPixels: image.width, captureHeightInPixels: image.height,
                                  displayFrame: CGRect(x: 0, y: 0, width: image.width / 2, height: image.height / 2)),
        backingScaleFactor: 2
    )

    for evalCase in cases {
        let startedAt = Date()
        do {
            let answer = try await pipeline.answer(transcript: evalCase.question, capture: capture, elements: elements, textLines: textLines, conversationHistory: [])
            let seconds = Date().timeIntervalSince(startedAt)
            let expected = normalize(evalCase.expect)
            let pointedText = answer.pointedElement?.text
            let highlightedTexts = answer.highlightedElements.map(\.text)
            let pointHit = pointedText.map { normalize($0).contains(expected) } ?? false
            let highlightHit = highlightedTexts.contains { normalize($0).contains(expected) }
            let passed: Bool
            switch evalCase.where ?? "any" {
            case "point": passed = pointHit
            case "highlight": passed = highlightHit
            default: passed = pointHit || highlightHit
            }
            print("\(passed ? "✅" : "❌") \(String(format: "%4.1fs", seconds))  \"\(evalCase.question)\"  expect \"\(evalCase.expect)\"")
            if !passed {
                print("      point: \(pointedText.map { "\"\($0.prefix(60))\"" } ?? "none") · highlights: \(highlightedTexts.map { "\"\($0.prefix(40))\"" }.joined(separator: ", "))")
                print("      said: \(answer.spokenText.prefix(120))")
            }
            outcomes.append(CaseOutcome(screenshot: name, question: evalCase.question, expect: evalCase.expect, passed: passed, pointedText: pointedText, highlightedTexts: highlightedTexts, seconds: seconds, error: nil))
        } catch {
            print("💥 \(evalCase.question): \(error.localizedDescription)")
            outcomes.append(CaseOutcome(screenshot: name, question: evalCase.question, expect: evalCase.expect, passed: false, pointedText: nil, highlightedTexts: [], seconds: Date().timeIntervalSince(startedAt), error: error.localizedDescription))
        }
    }
}

if !dumpOnly {
    let passed = outcomes.filter(\.passed).count
    let meanSeconds = outcomes.isEmpty ? 0 : outcomes.map(\.seconds).reduce(0, +) / Double(outcomes.count)
    print("\n━━ \(GeneralModePipeline.isZoomPassEnabled ? "zoom on " : "zoom off") · \(passed)/\(outcomes.count) passed · mean \(String(format: "%.1f", meanSeconds))s per question")
    let resultsDirectory = harnessDirectory.appendingPathComponent("results")
    try? FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let resultsURL = resultsDirectory.appendingPathComponent("\(formatter.string(from: Date()))-\(GeneralModePipeline.isZoomPassEnabled ? "zoom" : "nozoom").json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(outcomes).write(to: resultsURL)
    print("results → \(resultsURL.path)")
}
