//
//  OctoAppearance.swift
//  leanring-buddy
//
//  The one colour Octo is painted in: the cursor buddy, the notch eyes and
//  activity wings, the accent inside the card, and every drawing on screen.
//  Picked in Settings › Buddy and remembered across launches.
//

import Combine
import SwiftUI

enum OctoAccent: String, CaseIterable, Identifiable {
    case green
    case blue
    case purple
    case pink
    case orange
    case yellow
    case teal
    case white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .teal: return "Teal"
        case .white: return "White"
        }
    }

    var color: Color {
        switch self {
        case .green: return Color(hex: "#22C55E")
        case .blue: return Color(hex: "#3B82F6")
        case .purple: return Color(hex: "#A855F7")
        case .pink: return Color(hex: "#EC4899")
        case .orange: return Color(hex: "#F97316")
        case .yellow: return Color(hex: "#EAB308")
        case .teal: return Color(hex: "#14B8A6")
        case .white: return Color(hex: "#F4F4F5")
        }
    }
}

@MainActor
final class OctoAppearance: ObservableObject {
    static let shared = OctoAppearance()
    private static let defaultsKey = "octoAccentColor"

    @Published var accent: OctoAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        accent = OctoAccent(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .green
    }
}
