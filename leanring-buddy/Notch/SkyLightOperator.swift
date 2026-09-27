//
//  SkyLightOperator.swift
//  leanring-buddy
//
//  Puts the notch window on a private SkyLight "space" with the highest absolute
//  level so it renders above the menu bar and inside the notch silhouette, the
//  way DynamicNotch and NotchNook do. Private API resolved with dlsym; if any
//  symbol is missing the app silently falls back to a normal high window level.
//

import AppKit
import Darwin

@MainActor
final class SkyLightOperator {
    static let shared = SkyLightOperator()

    private typealias MainConnectionIDFunction = @convention(c) () -> Int32
    private typealias SpaceCreateFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevelFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFunction = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpacesFunction = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let notchSurfaceLevel: Int32 = 2_147_483_647

    private let connection: Int32?
    private let space: Int32?
    private let addWindowsAndRemoveFromSpaces: AddWindowsAndRemoveFromSpacesFunction?

    private init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(frameworkPath, RTLD_NOW),
              let mainConnectionIDSymbol = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreateSymbol = dlsym(handle, "SLSSpaceCreate"),
              let spaceSetAbsoluteLevelSymbol = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpacesSymbol = dlsym(handle, "SLSShowSpaces"),
              let addWindowsSymbol = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            connection = nil
            space = nil
            addWindowsAndRemoveFromSpaces = nil
            print("🏝️ SkyLight unavailable; notch stays at a normal window level")
            return
        }

        let mainConnectionID = unsafeBitCast(mainConnectionIDSymbol, to: MainConnectionIDFunction.self)
        let spaceCreate = unsafeBitCast(spaceCreateSymbol, to: SpaceCreateFunction.self)
        let spaceSetAbsoluteLevel = unsafeBitCast(spaceSetAbsoluteLevelSymbol, to: SpaceSetAbsoluteLevelFunction.self)
        let showSpaces = unsafeBitCast(showSpacesSymbol, to: ShowSpacesFunction.self)

        let connectionID = mainConnectionID()
        let createdSpace = spaceCreate(connectionID, 1, 0)
        guard createdSpace != 0 else {
            connection = nil
            space = nil
            addWindowsAndRemoveFromSpaces = nil
            return
        }
        _ = spaceSetAbsoluteLevel(connectionID, createdSpace, Self.notchSurfaceLevel)
        _ = showSpaces(connectionID, [createdSpace] as CFArray)

        connection = connectionID
        space = createdSpace
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addWindowsSymbol, to: AddWindowsAndRemoveFromSpacesFunction.self)
    }

    var isAvailable: Bool { connection != nil && space != nil }

    /// Moves the window onto the notch-surface space (above the menu bar).
    func delegateWindow(_ window: NSWindow) {
        guard let connection, let space, let addWindowsAndRemoveFromSpaces else { return }
        _ = addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
        print("🏝️ notch window delegated to SkyLight space")
    }
}
