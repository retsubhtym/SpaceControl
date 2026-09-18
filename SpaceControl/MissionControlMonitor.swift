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
    /// Space the thumbnail belongs to (ManagedSpaceID), parsed from the same identifier ("… .space.3" → 3).
    let spaceID: UInt64?
    /// Frame in AX (top-left origin) global coordinates.
    let frame: CGRect

    func isSameElement(as other: Thumbnail) -> Bool {
        if let windowID, let otherID = other.windowID { return windowID == otherID }
        return CFEqual(element, other.element)
    }
}

/// What Mission Control currently shows.
struct MissionControlSnapshot {
    /// Thumbnails of the Spaces Mission Control is displaying.
    let thumbnails: [Thumbnail]
    /// The Space Mission Control is displaying on each display.
    let displayedSpaces: Set<UInt64>
}

/// The Spaces bar at the top of Mission Control for one display.
struct SpacesBar {
    /// One element per Space (desktops and full-screen apps), ordered left to right.
    let spaces: [AXUIElement]
    /// The "+" button that adds a new desktop.
    let addButton: AXUIElement?
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

    /// Reads what Mission Control shows: `nil` when it is not shown. The thumbnails are empty when it
    /// displays Spaces without windows.
    ///
    /// Each display group holds thumbnails of several Spaces at once (with overlapping frames), so only the
    /// thumbnails of the Space Mission Control is displaying on that display are kept.
    func snapshot() -> MissionControlSnapshot? {
        guard isMissionControlShown() else {
            displayGroups = []
            return nil
        }
        refreshDisplayGroups()
        var thumbnails: [Thumbnail] = []
        var displayedSpaces: Set<UInt64> = []
        for group in displayGroups {
            var groupThumbnails: [Thumbnail] = []
            collect(group, depth: 0, into: &groupThumbnails)
            guard let displayed = displayedSpace(in: group) else {
                thumbnails += groupThumbnails
                continue
            }
            displayedSpaces.insert(displayed)
            thumbnails += groupThumbnails.filter { thumbnail in
                if let spaceID = thumbnail.spaceID { return spaceID == displayed }
                guard let windowID = thumbnail.windowID else { return true }
                return SpacesInfo.spaces(ofWindow: windowID).contains(displayed)
            }
        }
        return MissionControlSnapshot(thumbnails: thumbnails, displayedSpaces: displayedSpaces)
    }

    /// The Space Mission Control displays in a "mc.display" group: the selected item of that display's
    /// Spaces bar, whose items are in the window server's order. Falls back to the window server's current Space.
    private func displayedSpace(in group: AXUIElement) -> UInt64? {
        guard let displayNumber: NSNumber = group.attribute("AXDisplayID") else { return nil }
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        if let list = descendant(of: group, withIdentifier: "mc.spaces.list"),
           let selected = (list.attribute(kAXSelectedChildrenAttribute) as [AXUIElement]?)?.first,
           let spaceIDs = SpacesInfo.spaceIDs(displayID: displayID) {
            let items = list.children
            if items.count == spaceIDs.count, let index = items.firstIndex(where: { CFEqual($0, selected) }) {
                return spaceIDs[index]
            }
        }
        return SpacesInfo.currentSpaceID(displayID: displayID)
    }

    /// Mission Control rebuilds its display groups when the Space changes, so look them up every time.
    /// Hit-testing is slow, so it is only used when the tree lookup fails and the cached groups are gone.
    private func refreshDisplayGroups() {
        var groups: [AXUIElement] = []
        if let wm = element(for: Self.windowManagerBundleID, cache: &windowManager) {
            searchTree(wm, depth: 0, into: &groups)
        }
        if !groups.isEmpty {
            displayGroups = groups
        } else if displayGroups.isEmpty || displayGroups.contains(where: { $0.role == nil }) {
            displayGroups = findDisplayGroups()
        }
    }

    // MARK: - Spaces bar

    /// Reads the Spaces bar ("mc.spaces" with "mc.spaces.list" and "mc.spaces.add") for a display.
    /// Falls back to any display's bar when "Displays have separate Spaces" is off and there is only one.
    func spacesBar(displayID: CGDirectDisplayID?) -> SpacesBar? {
        guard isMissionControlShown() else { return nil }
        refreshDisplayGroups()

        let preferred = displayGroups.first { group in
            guard let displayID, let id: NSNumber = group.attribute("AXDisplayID") else { return false }
            return id.uint32Value == displayID
        }
        let candidates = (preferred.map { [$0] } ?? []) + displayGroups.filter { group in
            preferred.map { !CFEqual($0, group) } ?? true
        }
        for group in candidates {
            if let bar = spacesBar(in: group) { return bar }
        }

        // The bar may live outside the display groups: hit-test the strip at the top of the screen.
        if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.main,
           let root = hitTestSpacesRoot(on: screen),
           let bar = spacesBar(in: root) {
            return bar
        }

        let summary = displayGroups.map { group in
            group.children.map { "\($0.role ?? "?")#\($0.identifier ?? "-")" }.joined(separator: ", ")
        }
        Log.error("Spaces bar not found; mc.display children: \(summary)")
        return nil
    }

    private func spacesBar(in root: AXUIElement) -> SpacesBar? {
        guard let list = descendant(of: root, withIdentifier: "mc.spaces.list") else { return nil }
        let spaces = list.children
            .filter { $0.frame != nil }
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        let container = list.attribute(kAXParentAttribute) as AXUIElement? ?? root
        let addButton = descendant(of: container, withIdentifier: "mc.spaces.add")
            ?? descendant(of: root, withIdentifier: "mc.spaces.add")
        return SpacesBar(spaces: spaces, addButton: addButton)
    }

    private func hitTestSpacesRoot(on screen: NSScreen) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = screen.frame
        for ix in 0..<8 {
            let x = Float(frame.minX + frame.width * (CGFloat(ix) + 0.5) / 8)
            let y = Float(primaryHeight - frame.maxY + 40)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, x, y, &hit) == .success, let hit else { continue }
            if let root = ancestor(of: hit, withIdentifier: "mc.spaces")
                ?? ancestor(of: hit, withIdentifier: "mc.spaces.list")?.attribute(kAXParentAttribute) as AXUIElement? {
                return root
            }
        }
        return nil
    }

    private func descendant(of element: AXUIElement, withIdentifier identifier: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if element.identifier == identifier { return element }
        for child in element.children {
            if let found = descendant(of: child, withIdentifier: identifier, depth: depth + 1) { return found }
        }
        return nil
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
            let parsed = Self.parse(identifier: identifier)
            result.append(Thumbnail(
                element: element,
                title: element.title ?? "",
                windowID: wid.map { CGWindowID($0.uint32Value) },
                bundleID: parsed?.bundleID,
                spaceID: parsed?.spaceID,
                frame: frame
            ))
            return
        }
        for child in element.children {
            collect(child, depth: depth + 1, into: &result)
        }
    }

    /// "md.obsidian.space.3" -> ("md.obsidian", 3)
    private static func parse(identifier: String) -> (bundleID: String?, spaceID: UInt64)? {
        guard let range = identifier.range(of: #"\.space\.\d+$"#, options: .regularExpression),
              let spaceID = UInt64(identifier[range].dropFirst(".space.".count)) else { return nil }
        let bundleID = String(identifier[..<range.lowerBound])
        return (bundleID.isEmpty ? nil : bundleID, spaceID)
    }
}
