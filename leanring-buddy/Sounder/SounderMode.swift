//
//  SounderMode.swift
//  leanring-buddy
//
//  The buddy's operating mode. `automatic` lets the router decide per question:
//  a detected table plus a data-shaped question goes to Data mode; everything
//  else falls through to General mode (see the screen, answer, point).
//

import Foundation

enum SounderMode: String, CaseIterable, Identifiable {
    case automatic
    case general
    case clinical
    case agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .general: return "General"
        case .clinical: return "Rx"
        case .agent: return "Agent"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return "Picks the mode per question: tasks go to Agent, a chart plus a clinical question goes to Rx, everything else to General."
        case .general: return "Looks at your screen, answers by voice and points at what it means. Ask for a paper, picture or video and it holds one up."
        case .clinical: return "Reads the chart on screen, checks interactions and dosing, and pulls evidence. Only drug and condition IDs leave the Mac."
        case .agent: return "Does the task on this Mac: opens apps, clicks, types. Shows each step as it goes and researches unfamiliar apps first."
        }
    }

    /// Example question shown under the mode picker.
    var exampleQuestion: String {
        switch self {
        case .automatic: return "what's on my screen?"
        case .general: return "show me a video on how this works"
        case .clinical: return "anything I should worry about with these meds?"
        case .agent: return "open spotify and play matches by che"
        }
    }
}
