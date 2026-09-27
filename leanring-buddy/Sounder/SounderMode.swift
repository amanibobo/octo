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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .general: return "General"
        case .data: return "Data"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return "Data mode when a table is on screen and the question is about it, otherwise General."
        case .general: return "See the screen, answer by voice, point at things."
        case .data: return "Read the table, train a model, draw the answer on screen."
        }
    }
}
