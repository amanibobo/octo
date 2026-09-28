//
//  PushToTalkChord.swift
//  leanring-buddy
//
//  A user-recordable push-to-talk chord: a set of modifier keys, optionally
//  plus one regular key. Modifier-only chords (ctrl + option) are held via
//  flagsChanged events; chords with a key (ctrl + option + space) are held via
//  keyDown/keyUp of that key while the modifiers are down.
//

import AppKit
import Foundation

struct PushToTalkChord: Codable, Equatable {
    /// Device-independent modifier flags, limited to the five real modifiers.
    let modifierFlagsRawValue: UInt
    /// Virtual key code of the non-modifier key, if the chord has one.
    let keyCode: UInt16?

    static let recognizedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    init(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16?) {
        self.modifierFlagsRawValue = modifierFlags.intersection(Self.recognizedModifiers).rawValue
        self.keyCode = keyCode
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue) }

    /// A chord needs at least one modifier, unless the key is a function key (F1–F19).
    var isValid: Bool {
        if !modifierFlags.isEmpty { return true }
        guard let keyCode else { return false }
        return Self.functionKeyCodes.contains(keyCode)
    }

    static let controlOption = PushToTalkChord(modifierFlags: [.control, .option], keyCode: nil)

    /// Ordered labels for key-cap rendering: ctrl, option, shift, cmd, fn, then the key.
    var keyCapsuleLabels: [String] {
        var labels: [String] = []
        if modifierFlags.contains(.control) { labels.append("ctrl") }
        if modifierFlags.contains(.option) { labels.append("option") }
        if modifierFlags.contains(.shift) { labels.append("shift") }
        if modifierFlags.contains(.command) { labels.append("cmd") }
        if modifierFlags.contains(.function) { labels.append("fn") }
        if let keyCode { labels.append(Self.keyName(for: keyCode)) }
        return labels
    }

    var displayText: String { keyCapsuleLabels.joined(separator: " + ") }

    // MARK: - Key names (US layout; good enough for labels)

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80]

    private static let keyNames: [UInt16: String] = [
        49: "space", 36: "return", 48: "tab", 53: "esc", 51: "delete", 76: "enter",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "key \(keyCode)"
    }
}
