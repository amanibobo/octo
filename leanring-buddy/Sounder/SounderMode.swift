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
    case data
    case clinical
    case agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .general: return "General"
        case .data: return "Data"
        case .clinical: return "Rx"
        case .agent: return "Agent"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return "Agent for tasks (\"open…\", \"play…\"), Rx for charts, Data for tables, otherwise General."
        case .general: return "See the screen, answer by voice, point at things."
        case .data: return "Read the table, train a model, draw the answer on screen."
        case .clinical: return "Read the chart, check interactions and dosing, surface evidence. Only concept IDs leave the Mac."
        case .agent: return "Do the task on this Mac: open apps, click, type. The buddy shows each step as it goes."
        }
    }
}
