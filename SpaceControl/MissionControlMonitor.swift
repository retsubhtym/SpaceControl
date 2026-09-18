import Cocoa
import ApplicationServices

/// A window thumbnail shown inside Mission Control.
struct Thumbnail {
    let element: AXUIElement
    let title: String
    /// CGWindowID of the real window (the thumbnail's "wid" attribute).
    let windowID: CGWindowID?
    /// Bundle identifier of the owning app, parsed from an identifier like "md.obsidian.space.3".
    let bundleID: String?
    /// Frame in AX (top-left origin) global coordinates.
    let frame: CGRect

    func isSameElement(as other: Thumbnail) -> Bool {
        if let windowID, let otherID = other.windowID { return windowID == otherID }
        return CFEqual(element, other.element)
    }
}

/// Detects Mission Control and reads its window thumbnails.
///
/// Since macOS 27 the Dock only keeps an empty "mc" placeholder group while Mission Control is shown;
/// the real UI (groups "mc.display" with one AXButton per window) belongs to WindowManager.app.
final class MissionControlMonitor {
    private static let dockBundleID = "com.apple.dock"
    private static let windowManagerBundleID = "com.apple.WindowManager"

    private var dock: (app: NSRunningApplication, element: AXUIElement)?
    private var windowManager: (app: NSRunningApplication, element: AXUIElement)?
    /// "mc.display" groups found for the current Mission Control session.
    private var displayGroups: [AXUIElement] = []

    /// Reads the current window thumbnails. Empty when Mission Control is not shown.
    func thumbnails() -> [Thumbnail] {
        guard isMissionControlShown() else {
            displayGroups = []
            return []
        }
        if displayGroups.isEmpty || displayGroups.contains(where: { $0.role == nil }) {
            displayGroups = findDisplayGroups()
        }
        var result: [Thumbnail] = []
        for group in displayGroups {
            collect(group, depth: 0, into: &result)
        }
        return result
    }

    private func isMissionControlShown() -> Bool {
        if let dockElement = element(for: Self.dockBundleID, cache: &dock),
           dockElement.children.contains(where: { $0.identifier == "mc" }) {
            return true
        }
        if let wm = element(for: Self.windowManagerBundleID, cache: &windowManager),
           wm.children.contains(where: { ($0.identifier ?? "").hasPrefix("mc") }) {
            return true
        }
        return false
    }

    private func element(for bundleID: String, cache: inout (app: NSRunningApplication, element: AXUIElement)?) -> AXUIElement? {
        if let cached = cache, !cached.app.isTerminated { return cached.element }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            cache = nil
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        cache = (app, element)
        return element
    }

    // MARK: - Finding "mc.display" groups

    private func findDisplayGroups() -> [AXUIElement] {
        var groups: [AXUIElement] = []
        if let wm = element(for: Self.windowManagerBundleID, cache: &windowManager) {
            searchTree(wm, depth: 0, into: &groups)
        }
        if !groups.isEmpty { return groups }

        // The application element may not list the Mission Control UI: hit-test the screens instead.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let frame = screen.frame
            var foundOnScreen = false
            for iy in 1..<6 where !foundOnScreen {
                for ix in 0..<8 where !foundOnScreen {
                    let x = Float(frame.minX + frame.width * (CGFloat(ix) + 0.5) / 8)
                    let y = Float(primaryHeight - (frame.minY + frame.height * CGFloat(iy) / 6))
                    var hit: AXUIElement?
                    guard AXUIElementCopyElementAtPosition(systemWide, x, y, &hit) == .success, let hit else { continue }
                    var pid: pid_t = 0
                    AXUIElementGetPid(hit, &pid)
                    guard pid != ownPID, let group = ancestor(of: hit, withIdentifier: "mc.display") else { continue }
                    if !groups.contains(where: { CFEqual($0, group) }) { groups.append(group) }
                    foundOnScreen = true
                }
            }
        }
        return groups
    }

    private func searchTree(_ element: AXUIElement, depth: Int, into groups: inout [AXUIElement]) {
        guard depth < 6 else { return }
        if element.identifier == "mc.display" {
            groups.append(element)
            return
        }
        for child in element.children {
            searchTree(child, depth: depth + 1, into: &groups)
        }
    }

    private func ancestor(of element: AXUIElement, withIdentifier identifier: String) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { return nil }
            if node.identifier == identifier { return node }
            current = node.attribute(kAXParentAttribute) as AXUIElement?
        }
        return nil
    }

    // MARK: - Collecting thumbnails

    private func collect(_ element: AXUIElement, depth: Int, into result: inout [Thumbnail]) {
        guard depth < 8 else { return }
        let identifier = element.identifier ?? ""
        // Skip the Spaces bar at the top of Mission Control.
        if identifier.hasPrefix("mc.spaces") { return }

        if element.role == kAXButtonRole, let frame = element.frame, frame.width > 20, frame.height > 20 {
            let wid: NSNumber? = element.attribute("wid")
            result.append(Thumbnail(
                element: element,
                title: element.title ?? "",
                windowID: wid.map { CGWindowID($0.uint32Value) },
                bundleID: Self.bundleID(fromIdentifier: identifier),
                frame: frame
            ))
            return
        }
        for child in element.children {
            collect(child, depth: depth + 1, into: &result)
        }
    }

    /// "md.obsidian.space.3" -> "md.obsidian"
    private static func bundleID(fromIdentifier identifier: String) -> String? {
        guard let range = identifier.range(of: #"\.space\.\d+$"#, options: .regularExpression) else { return nil }
        let bundleID = String(identifier[..<range.lowerBound])
        return bundleID.isEmpty ? nil : bundleID
    }
}
