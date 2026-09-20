import Cocoa
import ApplicationServices

/// Private but long-stable HIServices call mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Maps a Mission Control thumbnail to the real application window and acts on it.
enum WindowResolver {
    @discardableResult
    static func close(_ thumbnail: Thumbnail) -> Bool {
        guard let window = resolve(thumbnail) else {
            Log.error("close: no window found for thumbnail wid=\(thumbnail.windowID.map(String.init) ?? "-")")
            return false
        }
        guard let closeButton = elementAttribute(window, kAXCloseButtonAttribute) else {
            Log.error("close: window has no close button")
            return false
        }
        let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        if result != .success { Log.error("close: pressing the close button failed (\(result.rawValue))") }
        return result == .success
    }

    @discardableResult
    static func minimize(_ thumbnail: Thumbnail) -> Bool {
        guard let window = resolve(thumbnail) else {
            Log.error("minimize: no window found for thumbnail wid=\(thumbnail.windowID.map(String.init) ?? "-")")
            return false
        }
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if result != .success { Log.error("minimize: failed (\(result.rawValue))") }
        return result == .success
    }

    /// Hides the application that owns the window (like ⌘H inside the app).
    @discardableResult
    static func hideApp(of thumbnail: Thumbnail) -> Bool {
        owningApp(of: thumbnail)?.hide() ?? false
    }

    /// Asks the application that owns the window to quit (like ⌘Q inside the app, so it can still ask to save).
    @discardableResult
    static func quitApp(of thumbnail: Thumbnail) -> Bool {
        guard let app = owningApp(of: thumbnail),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        return app.terminate()
    }

    private static func owningApp(of thumbnail: Thumbnail) -> NSRunningApplication? {
        guard let pid = ownerPID(of: thumbnail), let app = NSRunningApplication(processIdentifier: pid) else {
            Log.error("no application found for thumbnail wid=\(thumbnail.windowID.map(String.init) ?? "-")")
            return nil
        }
        return app
    }

    private static func resolve(_ thumbnail: Thumbnail) -> AXUIElement? {
        guard let pid = ownerPID(of: thumbnail) else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let windows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) ?? []

        if let windowID = thumbnail.windowID {
            for window in windows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success, id == windowID { return window }
            }
        }
        // Fallback: a unique exact title match inside the owning app.
        let matches = windows.filter { !thumbnail.title.isEmpty && $0.title == thumbnail.title }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func ownerPID(of thumbnail: Thumbnail) -> pid_t? {
        if let windowID = thumbnail.windowID,
           let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t {
            return pid
        }
        if let bundleID = thumbnail.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.processIdentifier
        }
        return nil
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
