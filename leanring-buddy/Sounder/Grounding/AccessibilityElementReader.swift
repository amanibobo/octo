//
//  AccessibilityElementReader.swift
//  leanring-buddy
//
//  Grounding from the Accessibility API. Native apps hand over every control
//  with its role, label and frame for free, which is exact where OCR is a
//  guess: buttons, fields, links, menu items, rows. These are merged into the
//  Set-of-Mark element list next to the OCR lines (kind "ax:button" etc.), and
//  Agent mode presses them through AX instead of aiming a click at pixels.
//  Also powers "read me this dialog". Web pages and canvases still rely on OCR.
//

import AppKit
import ApplicationServices
import Foundation

/// One accessibility element, with its frame in global Core Graphics points
/// (top-left origin of the primary display) as the AX API reports it.
struct AccessibilityElement: @unchecked Sendable {
    let axElement: AXUIElement
    let role: String
    let label: String
    let frameInGlobalCGPoints: CGRect
    let isPressable: Bool
    let isTextInput: Bool

    /// Short role for the model: "button", "textfield", "link", "menuitem", "text"…
    var shortRole: String {
        switch role {
        case kAXButtonRole: return "button"
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField": return "textfield"
        case "AXLink": return "link"
        case kAXMenuItemRole, kAXMenuBarItemRole: return "menuitem"
        case kAXCheckBoxRole: return "checkbox"
        case kAXRadioButtonRole: return "radio"
        case kAXPopUpButtonRole, kAXMenuButtonRole: return "popup"
        case kAXStaticTextRole: return "text"
        case kAXSliderRole: return "slider"
        case kAXTabGroupRole: return "tab"
        case kAXRowRole, kAXCellRole: return "row"
        case kAXImageRole: return "image"
        default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
}

nonisolated enum AccessibilityElementReader {
    private static let interestingRoles: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXLink", kAXMenuItemRole, kAXMenuBarItemRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXStaticTextRole, kAXSliderRole, kAXRowRole, kAXCellRole,
        kAXImageRole, kAXTabGroupRole, "AXHeading", kAXIncrementorRole, kAXDisclosureTriangleRole,
    ]
    private static let inputRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    private static let maximumDepth = 14

    /// Elements of the frontmost app's windows that intersect `displayFrameCG`
    /// (global CG points). Slow-ish (tens of ms for a big window): call off the main actor.
    static func elements(intersecting displayFrameCG: CGRect, maximum: Int = 120) -> [AccessibilityElement] {
        guard AXIsProcessTrusted(), let frontmost = NSWorkspace.shared.frontmostApplication else { return [] }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        // Stay responsive if the app is busy or hung.
        AXUIElementSetMessagingTimeout(application, 0.25)

        var windowsValue: AnyObject?
        var windows: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let list = windowsValue as? [AXUIElement] {
            windows = list
        }
        var focusedValue: AnyObject?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = focusedValue, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let focusedWindow = focused as! AXUIElement
            windows.removeAll { CFEqual($0, focusedWindow) }
            windows.insert(focusedWindow, at: 0)
        }

        var collected: [AccessibilityElement] = []
        var visited = 0
        for window in windows.prefix(3) {
            walk(window, depth: 0, displayFrame: displayFrameCG, into: &collected, visited: &visited, maximum: maximum)
            if collected.count >= maximum { break }
        }
        // Menu bar items are useful targets too ("File", "Edit").
        var menuBarValue: AnyObject?
        if collected.count < maximum, AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
           let menuBarObject = menuBarValue, CFGetTypeID(menuBarObject) == AXUIElementGetTypeID() {
            walk(menuBarObject as! AXUIElement, depth: maximumDepth - 1, displayFrame: displayFrameCG, into: &collected, visited: &visited, maximum: maximum)
        }
        return collected
    }

    private static func walk(_ element: AXUIElement, depth: Int, displayFrame: CGRect, into collected: inout [AccessibilityElement], visited: inout Int, maximum: Int) {
        guard depth <= maximumDepth, collected.count < maximum, visited < 2500 else { return }
        visited += 1
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let frame = frameOf(element)
        let isVisible = frame.map { $0.width >= 4 && $0.height >= 4 && $0.intersects(displayFrame) } ?? false

        if isVisible, let frame, interestingRoles.contains(role) {
            let label = bestLabel(for: element, role: role)
            if !label.isEmpty, label.count <= 80 {
                var actionNames: CFArray?
                let actions = AXUIElementCopyActionNames(element, &actionNames) == .success ? (actionNames as? [String]) ?? [] : []
                collected.append(AccessibilityElement(axElement: element, role: role, label: label, frameInGlobalCGPoints: frame,
                                                      isPressable: actions.contains(kAXPressAction), isTextInput: inputRoles.contains(role)))
            }
        }
        // Do not descend into offscreen or collapsed containers; do descend into
        // unlabelled groups (most of a window is groups).
        if let frame, !frame.intersects(displayFrame), frame.width > 0, frame.height > 0 { return }
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(200) {
            walk(child, depth: depth + 1, displayFrame: displayFrame, into: &collected, visited: &visited, maximum: maximum)
            if collected.count >= maximum { return }
        }
    }

    private static func bestLabel(for element: AXUIElement, role: String) -> String {
        let candidates = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            role == kAXStaticTextRole || inputRoles.contains(role) ? stringAttribute(element, kAXValueAttribute) : nil,
            stringAttribute(element, kAXPlaceholderValueAttribute),
            stringAttribute(element, kAXHelpAttribute),
        ]
        for candidate in candidates {
            if let candidate {
                let trimmed = candidate.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionObject = positionValue, let sizeObject = sizeValue,
              CFGetTypeID(positionObject) == AXValueGetTypeID(), CFGetTypeID(sizeObject) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionObject as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeObject as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Frame of the frontmost app's focused window in global CG points, if any.
    static func focusedWindowFrameCG() -> CGRect? {
        guard AXIsProcessTrusted(), let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return frameOf(focused as! AXUIElement)
    }

    // MARK: - Actions

    /// Presses the element through AX (exact, no pointer needed). False if the app refused.
    @discardableResult
    static func press(_ element: AccessibilityElement) -> Bool {
        AXUIElementPerformAction(element.axElement, kAXPressAction as CFString) == .success
    }

    /// Gives a text field keyboard focus so typing lands in it.
    @discardableResult
    static func focus(_ element: AccessibilityElement) -> Bool {
        AXUIElementSetAttributeValue(element.axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Sets a text field's value directly (faster and safer than keystrokes).
    @discardableResult
    static func setValue(_ text: String, of element: AccessibilityElement) -> Bool {
        AXUIElementSetAttributeValue(element.axElement, kAXValueAttribute as CFString, text as CFString) == .success
    }

    // MARK: - Dialog reading

    /// The frontmost window's text and controls in reading order, for "read me this dialog".
    static func focusedWindowSummary() -> (title: String, texts: [String], buttons: [String], elements: [AccessibilityElement])? {
        guard AXIsProcessTrusted(), let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        let windowTitle = stringAttribute(window, kAXTitleAttribute) ?? ""
        let title = windowTitle.isEmpty ? (frontmost.localizedName ?? "window") : windowTitle
        var collected: [AccessibilityElement] = []
        var visited = 0
        walk(window, depth: 0, displayFrame: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000), into: &collected, visited: &visited, maximum: 200)
        let ordered = collected.sorted {
            abs($0.frameInGlobalCGPoints.minY - $1.frameInGlobalCGPoints.minY) > 8
                ? $0.frameInGlobalCGPoints.minY < $1.frameInGlobalCGPoints.minY
                : $0.frameInGlobalCGPoints.minX < $1.frameInGlobalCGPoints.minX
        }
        var texts: [String] = []
        var buttons: [String] = []
        for element in ordered {
            switch element.shortRole {
            case "button", "checkbox", "radio", "popup", "link", "menuitem": buttons.append(element.label)
            case "text", "textfield", "heading", "row": texts.append(element.label)
            default: break
            }
        }
        return (title, texts, buttons, ordered)
    }
}
