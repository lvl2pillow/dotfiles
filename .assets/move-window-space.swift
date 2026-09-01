// move-window-space — move the frontmost window to the adjacent Space.
// Usage: move-window-space next|prev|focus
//
// `next` and `prev` move the window but leave the current Space unchanged.
// BTT can then animate the Space switch, followed by `focus`.
// This script exists as a stop-gap for BTT bug:
// https://community.folivora.ai/t/move-window-to-desktop-activates-zoom-instead/45708

import AppKit
import ApplicationServices
import Darwin
import Foundation
import ObjectiveC

private func fail(_ message: String, status: Int32 = 1) -> Never {
    fputs("move-window-space: \(message)\n", stderr)
    exit(status)
}

private let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)!
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T {
    guard let handle, let pointer = dlsym(handle, name) else {
        fail("cannot resolve \(name)", status: 2)
    }
    return unsafeBitCast(pointer, to: type)
}

private func optionalSymbol<T>(_ name: String, _ type: T.Type) -> T? {
    for handle in [skyLight, defaultHandle] {
        guard let handle, let pointer = dlsym(handle, name) else { continue }
        return unsafeBitCast(pointer, to: type)
    }
    return nil
}

private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
private typealias CopyManagedDisplayForSpaceFn = @convention(c) (Int32, UInt64) -> CFString?
private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
private typealias DisplayIsAnimatingFn = @convention(c) (Int32, CFString) -> Bool
private typealias SpaceSetFrontPSNFn = @convention(c) (Int32, UInt64, ProcessSerialNumber) -> Int32
private typealias GetWindowOwnerFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
private typealias GetConnectionPSNFn = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
private typealias GetAXWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private let connection = symbol(skyLight, "SLSMainConnectionID", MainConnectionFn.self)()
private let copyWindowSpaces = symbol(skyLight, "SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
private let copyDisplaySpaces = symbol(skyLight, "SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
private let copyManagedDisplayForSpace = symbol(skyLight, "SLSCopyManagedDisplayForSpace", CopyManagedDisplayForSpaceFn.self)
private let currentSpaceForDisplay = symbol(skyLight, "SLSManagedDisplayGetCurrentSpace", CurrentSpaceFn.self)
private let displayIsAnimating = optionalSymbol("SLSManagedDisplayIsAnimating", DisplayIsAnimatingFn.self)
private let spaceSetFrontPSN = optionalSymbol("SLSSpaceSetFrontPSN", SpaceSetFrontPSNFn.self)
private let getWindowOwner = optionalSymbol("SLSGetWindowOwner", GetWindowOwnerFn.self)
private let getConnectionPSN = optionalSymbol("SLSGetConnectionPSN", GetConnectionPSNFn.self)
private let setFrontProcess = optionalSymbol("_SLPSSetFrontProcessWithOptions", SetFrontProcessFn.self)
private let postEventRecord = optionalSymbol("SLPSPostEventRecordTo", PostEventRecordFn.self)
private let getAXWindow = optionalSymbol("_AXUIElementGetWindow", GetAXWindowFn.self)

// The operation is a private Objective-C class, but its public runtime method is
// discoverable without parsing the dyld shared cache or calling a guessed address.
private func moveWindow(_ window: CGWindowID, to space: UInt64) {
    guard let operationClass: AnyClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else {
        fail("bridged window-management operation is unavailable", status: 2)
    }

    let initializer = sel_registerName("initWithWindows:spaceID:")
    let performSelector = sel_registerName("performWithWMBridgeDelegate")
    guard let initializerMethod = class_getInstanceMethod(operationClass, initializer),
          let initializerEncoding = method_getTypeEncoding(initializerMethod),
          String(cString: initializerEncoding) == "@32@0:8@16Q24",
          let performMethod = class_getInstanceMethod(operationClass, performSelector),
          let performEncoding = method_getTypeEncoding(performMethod),
          String(cString: performEncoding) == "v16@0:8" else {
        fail("bridged window-management ABI is unavailable", status: 2)
    }

    let send = symbol(defaultHandle, "objc_msgSend", UnsafeMutableRawPointer.self)
    let alloc = unsafeBitCast(send, to: (@convention(c) (AnyClass, Selector) -> AnyObject).self)
    let initialize = unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector, CFArray, UInt64) -> AnyObject?).self)
    let perform = unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector) -> Void).self)

    guard let operation = initialize(alloc(operationClass, sel_registerName("alloc")), initializer,
                                     [NSNumber(value: window)] as CFArray, space) else {
        fail("cannot create window-management operation", status: 2)
    }
    perform(operation, performSelector)
}

// MARK: Queries

private struct Space {
    let id: UInt64
    let type: Int
}

private struct FrontWindow {
    let app: NSRunningApplication
    let id: CGWindowID
}

private func frontWindow() -> FrontWindow? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    for window in windows {
        guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
              pid.int32Value == app.processIdentifier,
              let layer = window[kCGWindowLayer as String] as? NSNumber,
              layer.intValue == 0,
              let number = window[kCGWindowNumber as String] as? NSNumber,
              number.uint32Value != 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            continue
        }
        return FrontWindow(app: app, id: CGWindowID(number.uint32Value))
    }
    return nil
}

private func windowSpaces(_ window: CGWindowID) -> [UInt64] {
    (copyWindowSpaces(connection, 0x7, [NSNumber(value: window)] as CFArray) as? [NSNumber])?.map(\.uint64Value) ?? []
}

private func windowOwnerPID(_ window: CGWindowID) -> pid_t? {
    guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], window) as? [[String: Any]],
          let info = windows.first,
          let pid = info[kCGWindowOwnerPID as String] as? NSNumber else {
        return nil
    }
    return pid.int32Value
}

private func displaySpaces() -> [[Space]] {
    guard let displays = copyDisplaySpaces(connection) as? [[String: Any]] else { return [] }
    return displays.map { display in
        guard let raw = display["Spaces"] as? [[String: Any]] else { return [] }
        return raw.compactMap { space in
            guard let id = space["id64"] as? NSNumber,
                  let type = space["type"] as? NSNumber else { return nil }
            return Space(id: id.uint64Value, type: type.intValue)
        }
    }
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    repeat {
        if condition() { return true }
        usleep(10_000)
    } while DispatchTime.now().uptimeNanoseconds < deadline
    return condition()
}

// MARK: Pending move state

private struct PendingMove {
    let pid: pid_t
    let window: CGWindowID
    let space: UInt64
    let created: TimeInterval
}

private let stateURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("move-window-space-\(getuid()).state")

private func loadState() -> PendingMove? {
    guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return nil }
    let fields = text.split(whereSeparator: \.isWhitespace)
    guard fields.count == 4,
          let pid = pid_t(fields[0]),
          let window = UInt32(fields[1]),
          let space = UInt64(fields[2]),
          let created = TimeInterval(fields[3]) else {
        return nil
    }
    return PendingMove(pid: pid, window: CGWindowID(window), space: space, created: created)
}

private func saveState(_ state: PendingMove) {
    let text = "\(state.pid) \(state.window) \(state.space) \(state.created)\n"
    do {
        try text.write(to: stateURL, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot save pending move: \(error)")
    }
}

private func clearState() {
    try? FileManager.default.removeItem(at: stateURL)
}

private func rejectExistingMove() {
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
    let age = loadState().map { Date().timeIntervalSince1970 - $0.created }
    if let age, age >= 0, age < 30 {
        fail("a move is already waiting for focus")
    }
    clearState()
}

// MARK: Focus

private func ownerPSN(for window: CGWindowID) -> ProcessSerialNumber? {
    guard let getWindowOwner, let getConnectionPSN else { return nil }
    var ownerConnection: Int32 = 0
    guard getWindowOwner(connection, window, &ownerConnection) == 0 else { return nil }
    var psn = ProcessSerialNumber()
    guard getConnectionPSN(ownerConnection, &psn) == 0 else { return nil }
    return psn
}

private func postKeyWindowEvent(_ psn: inout ProcessSerialNumber, window: CGWindowID, event: UInt8) -> Bool {
    guard let postEventRecord else { return false }
    var record = [UInt8](repeating: 0, count: 0xf8)
    record[0x04] = 0xf8
    record[0x08] = event
    record[0x3a] = 0x10
    for index in 0x20..<0x30 { record[index] = 0xff }
    withUnsafeBytes(of: window) { bytes in
        for (index, byte) in bytes.enumerated() {
            record[0x3c + index] = byte
        }
    }
    return withUnsafeMutablePointer(to: &psn) { psnPointer in
        record.withUnsafeMutableBufferPointer { eventPointer in
            postEventRecord(psnPointer, eventPointer.baseAddress!) == 0
        }
    }
}

private func focusedWindowID(for pid: pid_t) -> CGWindowID? {
    guard let getAXWindow else { return nil }
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value else { return nil }
    let windowElement = unsafeBitCast(value, to: AXUIElement.self)
    var window = CGWindowID(0)
    return getAXWindow(windowElement, &window) == .success ? window : nil
}

private func raiseFocusedWindow(for pid: pid_t, expected: CGWindowID) {
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value else { return }
    let window = unsafeBitCast(value, to: AXUIElement.self)
    var windowID = CGWindowID(0)
    guard getAXWindow?(window, &windowID) == .success, windowID == expected else { return }
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}

private func focus(_ state: PendingMove) {
    guard windowOwnerPID(state.window) == state.pid else {
        fail("window identity changed")
    }
    guard let display = copyManagedDisplayForSpace(connection, state.space),
          waitUntil(timeout: 3, {
              guard currentSpaceForDisplay(connection, display) == state.space else { return false }
              guard let displayIsAnimating else { return true }
              return !displayIsAnimating(connection, display)
          }) else {
        fail("destination Space is still animating")
    }
    usleep(200_000)

    guard let owner = ownerPSN(for: state.window),
          let setFrontProcess,
          let spaceSetFrontPSN else {
        fail("focus APIs are unavailable", status: 2)
    }

    _ = spaceSetFrontPSN(connection, state.space, owner)
    var psn = owner
    guard setFrontProcess(&psn, state.window, 0x200) == 0,
          postKeyWindowEvent(&psn, window: state.window, event: 0x01),
          postKeyWindowEvent(&psn, window: state.window, event: 0x02) else {
        fail("cannot focus moved window", status: 2)
    }
    raiseFocusedWindow(for: state.pid, expected: state.window)

    guard waitUntil(timeout: 2, {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == state.pid else { return false }
        if let focused = focusedWindowID(for: state.pid) {
            return focused == state.window
        }
        return frontWindow()?.id == state.window
    }) else {
        fail("moved window is not frontmost")
    }
}

// MARK: Process lock

private final class InvocationLock {
    private let descriptor: Int32

    init() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-window-space-\(getuid()).lock")
        descriptor = open(path.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { fail("cannot create invocation lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            fail("another invocation is running")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MARK: Main

let arguments = CommandLine.arguments
let command = arguments.dropFirst()
guard arguments.count == 2,
      let action = command.first,
      ["next", "prev", "focus"].contains(action) else {
    fail("usage: move-window-space next|prev|focus")
}

private let lock = InvocationLock()

switch action {
case "next", "prev":
    rejectExistingMove()
    guard let front = frontWindow() else { fail("no frontmost window found") }
    let ownedSpaces = windowSpaces(front.id)
    guard ownedSpaces.count == 1,
          let display = displaySpaces().first(where: { $0.contains { $0.id == ownedSpaces[0] } }),
          let current = display.firstIndex(where: { $0.id == ownedSpaces[0] }) else {
        fail("window is sticky or unmanaged")
    }

    let direction = action == "next" ? 1 : -1
    let targetIndex = current + direction
    guard display[current].type == 0,
          display.indices.contains(targetIndex),
          display[targetIndex].type == 0 else {
        fail("no adjacent desktop Space")
    }

    let target = display[targetIndex].id
    moveWindow(front.id, to: target)
    guard waitUntil(timeout: 3, { windowSpaces(front.id).contains(target) }) else {
        fail("window move did not complete")
    }

    if let owner = ownerPSN(for: front.id) {
        _ = spaceSetFrontPSN?(connection, target, owner)
    }
    saveState(PendingMove(pid: front.app.processIdentifier,
                          window: front.id,
                          space: target,
                          created: Date().timeIntervalSince1970))

case "focus":
    guard let state = loadState() else { fail("no pending move") }
    let age = Date().timeIntervalSince1970 - state.created
    guard age >= 0, age < 30 else {
        clearState()
        fail("pending move has expired")
    }
    guard windowSpaces(state.window).contains(state.space) else {
        fail("moved window is no longer in the destination Space")
    }
    focus(state)
    clearState()

default:
    fail("usage: move-window-space next|prev|focus")
}
