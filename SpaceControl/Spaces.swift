import Cocoa
import ColorSync

/// Private SkyLight (window server) calls, looked up at runtime so a missing symbol never breaks
/// linking or launching. The same calls are used by yabai and Hammerspoon.
private enum SkyLight {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else {
            Log.error("SkyLight symbol \(name) not found")
            return nil
        }
        return unsafeBitCast(symbol, to: type)
    }

    static let mainConnectionID = function("SLSMainConnectionID", as: MainConnectionID.self)
    static let copyManagedDisplaySpaces = function("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    static let copySpacesForWindows = function("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)

    static var connection: Int32 { mainConnectionID?() ?? 0 }
}

/// Read-only information about Spaces from the window server.
enum SpacesInfo {
    /// ManagedSpaceIDs of the display's Spaces, in the same left-to-right order as the Spaces bar.
    static func spaceIDs(displayID: CGDirectDisplayID) -> [UInt64]? {
        guard let entry = displayEntry(displayID: displayID),
              let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
        return spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
    }

    /// The display's current Space according to the window server.
    static func currentSpaceID(displayID: CGDirectDisplayID) -> UInt64? {
        displayEntry(displayID: displayID).flatMap(currentSpace(of:))
    }

    private static func currentSpace(of display: [String: Any]) -> UInt64? {
        ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    /// Spaces a window currently belongs to (several for windows shown on all Spaces).
    static func spaces(ofWindow windowID: CGWindowID) -> [UInt64] {
        guard let copy = SkyLight.copySpacesForWindows,
              let result = copy(SkyLight.connection, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
        else { return [] }
        return ((result as NSArray) as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    private static func managedDisplays() -> [[String: Any]] {
        guard let copy = SkyLight.copyManagedDisplaySpaces else { return [] }
        return copy(SkyLight.connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func displayEntry(displayID: CGDirectDisplayID) -> [String: Any]? {
        let displays = managedDisplays()
        let uuid = displayUUID(displayID)
        return displays.first { display in
            guard let uuid, let identifier = display["Display Identifier"] as? String else { return false }
            return identifier.caseInsensitiveCompare(uuid) == .orderedSame
        }
            // With "Displays have separate Spaces" off there is a single entry named "Main".
            ?? (displays.count == 1 ? displays.first : nil)
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Changes Spaces through SkyLight's "bridged" window-management operations.
///
/// There is no public API for this. On macOS 27 the direct SkyLight calls (`SLSMoveWindowsToManagedSpace`,
/// the compat-ID workaround, add/remove) are ignored for normal apps, and yabai's
/// `SLSPerformAsynchronousBridgedWindowManagementOperation` no longer exists. What works is creating the
/// operation object and calling its `-performWithWMBridgeDelegate`, which hands the request to the system's
/// window-management bridge. Operations run asynchronously.
enum SpaceMover {
    /// Moves the window to `spaceID`.
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) -> Bool {
        let windows = [NSNumber(value: Int32(bitPattern: windowID))] as NSArray
        return perform("SLSBridgedMoveWindowsToManagedSpaceOperation", "initWithWindows:spaceID:", windows, spaceID)
    }

    /// Runs `[[className alloc] <initializer>object spaceID:spaceID]` and `-performWithWMBridgeDelegate`.
    /// Both operations used here take an object and a 64-bit Space ID.
    private static func perform(_ className: String, _ initializer: String, _ object: NSObject, _ spaceID: UInt64) -> Bool {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString(initializer)
        let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let cls = NSClassFromString(className),
              let allocMethod = class_getClassMethod(cls, allocSelector),
              class_respondsToSelector(cls, initSelector),
              let initIMP = class_getMethodImplementation(cls, initSelector) else {
            Log.error("\(className) is missing or has an unexpected interface")
            return false
        }

        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSObject, UInt64) -> Unmanaged<AnyObject>?
        let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls, allocSelector)
        // -init consumes the +1 from -alloc and returns a +1 object.
        guard let operation = unsafeBitCast(initIMP, to: Init.self)(allocated, initSelector, object, spaceID)?
            .takeRetainedValue() as? NSObject,
              operation.responds(to: performSelector) else {
            Log.error("could not create \(className)")
            return false
        }
        operation.perform(performSelector)
        return true
    }
}
