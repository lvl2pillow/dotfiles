// Build: swiftc -O -swift-version 5 move-window-space.swift -o move-window-space
// Usage: move-window-space next|prev

import AppKit
import Foundation
import MachO
import ObjectiveC

private func fail(_ message: String, status: Int32 = 1) -> Never {
    fputs("move-window-space: \(message)\n", stderr)
    exit(status)
}

private let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)!
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T {
    guard let handle, let pointer = dlsym(handle, name) else { fail("cannot resolve \(name)", status: 2) }
    return unsafeBitCast(pointer, to: type)
}

private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
private typealias SharedCacheUUIDFn = @convention(c) (UnsafeMutablePointer<UInt8>) -> Bool
private typealias PerformFn = @convention(c) (AnyObject?) -> Void

private let connection = symbol(skyLight, "SLSMainConnectionID", MainConnectionFn.self)()
private let copyWindowSpaces = symbol(skyLight, "SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
private let copyDisplaySpaces = symbol(skyLight, "SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
private let copySharedCacheUUID = symbol(defaultHandle, "_dyld_get_shared_cache_uuid", SharedCacheUUIDFn.self)

private struct SkyLightInfo {
    var slide: Int
    var textVM: UInt64
    var textSize: UInt64
    var linkeditVM: UInt64
    var symOff: UInt64
    var symbolCount: UInt32
    var strOff: UInt64
    var strSize: UInt64
}

private struct Bridge {
    let perform: PerformFn
    let operationClass: AnyClass
    let initializer: Selector
}

private func liveSkyLight() -> SkyLightInfo? {
    guard skyLight != nil else { return nil }
    for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index),
              String(cString: name).contains("SkyLight.framework"),
              String(cString: name).hasSuffix("/SkyLight") else { continue }
        let header = UnsafeRawPointer(_dyld_get_image_header(index))!
        var info = SkyLightInfo(slide: _dyld_get_image_vmaddr_slide(index), textVM: 0, textSize: 0,
                                linkeditVM: 0, symOff: 0, symbolCount: 0, strOff: 0, strSize: 0)
        // mach_header_64.ncmds@16; segment_command_64 segname@8, vmaddr@24, vmsize@32;
        // symtab_command symoff@8, nsyms@12, stroff@16, strsize@20.
        var command = header + 32
        for _ in 0..<header.load(fromByteOffset: 16, as: UInt32.self) {
            let type = command.load(as: UInt32.self)
            if type == UInt32(LC_SEGMENT_64) {
                let name = String(cString: (command + 8).assumingMemoryBound(to: CChar.self))
                if name == "__TEXT" {
                    info.textVM = command.load(fromByteOffset: 24, as: UInt64.self)
                    info.textSize = command.load(fromByteOffset: 32, as: UInt64.self)
                } else if name == "__LINKEDIT" {
                    info.linkeditVM = command.load(fromByteOffset: 24, as: UInt64.self)
                }
            } else if type == UInt32(LC_SYMTAB) {
                info.symOff = UInt64(command.load(fromByteOffset: 8, as: UInt32.self))
                info.symbolCount = command.load(fromByteOffset: 12, as: UInt32.self)
                info.strOff = UInt64(command.load(fromByteOffset: 16, as: UInt32.self))
                info.strSize = UInt64(command.load(fromByteOffset: 20, as: UInt32.self))
            }
            command += Int(command.load(fromByteOffset: 4, as: UInt32.self))
        }
        return info.textSize > 0 && info.linkeditVM > 0 && info.symbolCount > 0 ? info : nil
    }
    return nil
}

private func sharedCacheUUID() -> UUID? {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard bytes.withUnsafeMutableBufferPointer({ copySharedCacheUUID($0.baseAddress!) }) else { return nil }
    return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
}

private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
}

private func u64(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) }
}

private func read(_ file: FileHandle, _ count: Int) -> Data? {
    let data = file.readData(ofLength: count)
    return data.count == count ? data : nil
}

private func inText(_ value: UInt64, _ info: SkyLightInfo) -> Bool {
    value >= info.textVM && value - info.textVM < info.textSize
}

private let performName = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

private func resolveValue(_ info: SkyLightInfo, cacheUUID: UUID) -> UInt64? {
    let statePath = NSHomeDirectory() + "/Library/Caches/move-window-space/bridged-nvalue.txt"
    if let state = try? String(contentsOfFile: statePath, encoding: .utf8) {
        let fields = state.split(whereSeparator: { $0.isWhitespace })
        if fields.count == 2, UUID(uuidString: String(fields[0])) == cacheUUID,
           let value = UInt64(fields[1]), inText(value, info) { return value }
    }

    let paths = ["/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e",
                 "/System/Library/dyld/dyld_shared_cache_arm64e"]
    files: for path in paths {
        guard let file = FileHandle(forReadingAtPath: path) else { continue }
        defer { try? file.close() }
        guard let header = read(file, 0x68),
              String(data: header.prefix(8), encoding: .ascii)?.hasPrefix("dyld_v1 ") == true,
              header.withUnsafeBytes({ UUID(uuid: $0.load(fromByteOffset: 0x58, as: uuid_t.self)) }) == cacheUUID else { continue }

        // dyld_cache_header mappingOffset@0x10, mappingCount@0x14;
        // dyld_cache_mapping_info address@0, fileOffset@16, stride 32.
        let mappingOffset = UInt64(u32(header, 0x10))
        let mappingCount = Int(u32(header, 0x14))
        guard mappingCount < 64 else { continue }
        file.seek(toFileOffset: mappingOffset)
        guard let mappings = read(file, mappingCount * 32),
              let mapping = (0..<mappingCount).first(where: { u64(mappings, $0 * 32) == info.linkeditVM }),
              info.symOff >= u64(mappings, mapping * 32 + 16) else { continue }

        let target = Data((performName + "\0").utf8)
        let stringEnd = info.strOff + info.strSize
        var stringIndex: UInt64?
        var position = info.strOff
        while position < stringEnd, stringIndex == nil {
            let step = min(UInt64(32 * 1024 * 1024), stringEnd - position)
            let count = Int(min(stringEnd - position, step + UInt64(target.count - 1)))
            file.seek(toFileOffset: position)
            guard let chunk = read(file, count) else { continue files }
            if let match = chunk.range(of: target) {
                stringIndex = position + UInt64(match.lowerBound) - info.strOff
            } else {
                position += step
            }
        }
        guard let stringIndex else { continue }

        file.seek(toFileOffset: info.symOff)
        guard let symbols = read(file, Int(info.symbolCount) * 16),
              let index = (0..<Int(info.symbolCount)).first(where: { u32(symbols, $0 * 16) == UInt32(stringIndex) }) else { continue }
        let offset = index * 16
        let value = u64(symbols, offset + 8)
        guard symbols[offset + 4] & UInt8(N_TYPE) == UInt8(N_SECT), inText(value, info) else { continue }

        let manager = FileManager.default
        try? manager.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(cacheUUID.uuidString) \(value)\n".write(toFile: statePath, atomically: true, encoding: .utf8)
        return value
    }
    return nil
}

private func resolveBridge() -> Bridge? {
    guard let info = liveSkyLight(), let cacheUUID = sharedCacheUUID(),
          let value = resolveValue(info, cacheUUID: cacheUUID),
          let operationClass: AnyClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return nil }
    let initializer = sel_registerName("initWithWindows:spaceID:")
    guard let method = class_getInstanceMethod(operationClass, initializer),
          let encoding = method_getTypeEncoding(method), String(cString: encoding) == "@32@0:8@16Q24",
          let address = UnsafeMutableRawPointer(bitPattern: UInt(value) + UInt(info.slide)) else { return nil }
    return Bridge(perform: unsafeBitCast(address, to: PerformFn.self), operationClass: operationClass, initializer: initializer)
}

private func frontWindow() -> CGWindowID? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for window in windows {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = window[kCGWindowOwnerPID as String] as? Int32, pid == app.processIdentifier else { continue }
        guard let number = window[kCGWindowNumber as String] as? Int, number != 0,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"], width > 0, height > 0 else { return nil }
        return CGWindowID(number)
    }
    return nil
}

private func windowSpaces(_ window: CGWindowID) -> [UInt64] {
    (copyWindowSpaces(connection, 0x7, [NSNumber(value: window)] as CFArray) as? [NSNumber])?.map(\.uint64Value) ?? []
}

private func displaySpaces() -> [[(id: UInt64, type: Int)]] {
    guard let displays = copyDisplaySpaces(connection) as? [[String: Any]] else { return [] }
    return displays.map { display in
        guard let raw = display["Spaces"] as? [[String: Any]] else { return [] }
        let spaces = raw.compactMap { space -> (id: UInt64, type: Int)? in
            guard let id = space["id64"] as? NSNumber, let type = space["type"] as? NSNumber else { return nil }
            return (id.uint64Value, type.intValue)
        }
        return spaces.count == raw.count ? spaces : []
    }
}

private func move(_ bridge: Bridge, window: CGWindowID, space: UInt64) {
    let send = symbol(defaultHandle, "objc_msgSend", UnsafeMutableRawPointer.self)
    let alloc = unsafeBitCast(send, to: (@convention(c) (AnyClass, Selector) -> AnyObject).self)
    let initialize = unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector, CFArray, UInt64) -> AnyObject?).self)
    guard let operation = initialize(alloc(bridge.operationClass, sel_registerName("alloc")), bridge.initializer,
                                     [NSNumber(value: window)] as CFArray, space) else {
        fail("cannot create window-management operation", status: 2)
    }
    bridge.perform(operation)
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1] == "next" || arguments[1] == "prev" else {
    fail("usage: move-window-space next|prev")
}
guard let bridge = resolveBridge() else { fail("incompatible SkyLight API", status: 2) }
guard let window = frontWindow() else { fail("no frontmost window found") }

let ownedSpaces = windowSpaces(window)
guard ownedSpaces.count == 1,
      let list = displaySpaces().first(where: { spaces in spaces.contains { $0.id == ownedSpaces[0] } }),
      let current = list.firstIndex(where: { $0.id == ownedSpaces[0] }) else {
    fail("window is sticky or unmanaged")
}
let direction = arguments[1] == "next" ? 1 : -1
let target = current + direction
guard list[current].type == 0, list.indices.contains(target), list[target].type == 0 else {
    fail("no adjacent desktop space on this display")
}
move(bridge, window: window, space: list[target].id)
