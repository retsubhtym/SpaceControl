import Cocoa

enum Direction {
    case left, right, up, down
}

/// Keeps the overlays in sync with Mission Control and implements the actions.
///
/// The selected window is always the one under the mouse, highlighted by Mission Control itself.
/// Keyboard navigation moves the cursor so the native hover highlight follows.
final class MissionControlController {
    var isEnabled = true {
        didSet { if !isEnabled { deactivate() } }
    }

    /// Read from the keyboard event tap: must be cheap.
    private(set) var isActive = false

    /// Space opens/closes Mission Control's Quick Look-style window preview; the (x) buttons hide meanwhile.
    private(set) var isPreviewing = false {
        didSet {
            if isPreviewing != oldValue { layoutCloseButtons() }
        }
    }

    private let monitor: MissionControlMonitor
    private var thumbnails: [Thumbnail] = []
    private var closePanels: [OverlayPanel] = []
    private var timer: Timer?
    /// Window to keep under the cursor after ⌘⌃←/→ switches Space, until its thumbnail appears or the deadline passes.
    private var followedWindow: (windowID: CGWindowID, spaceID: UInt64, deadline: Date)?

    /// Space-switch tracking: the (x) buttons stay hidden from the key press (or the detected change) until the
    /// Space Mission Control displays has changed and its switch animation has finished.
    private var isSwitchingSpace = false
    /// A Space-switch key was pressed, but Mission Control doesn't display another Space yet.
    private var isAwaitingSpaceChange = false
    private var lastDisplayedSpaces: Set<UInt64> = []
    private var spaceSwitchStart = Date.distantPast
    private var spaceSwitchDeadline = Date.distantPast
    private var showButtonsAt = Date.distantPast

    private static let activeInterval: TimeInterval = 0.1
    private static let idleInterval: TimeInterval = 0.25
    private static let switchingInterval: TimeInterval = 0.03
    /// Mission Control's Space-switch slide (about 0.5 s in a screen recording). Thumbnail frames don't move
    /// during it, so it can't be detected and is waited out instead.
    private static let switchAnimationDuration: TimeInterval = 0.5
    /// How long a key press may take to turn into a real Space change before the buttons come back anyway.
    private static let announcedSwitchTimeout: TimeInterval = 1.0

    init(monitor: MissionControlMonitor) {
        self.monitor = monitor
    }

    func start() {
        schedule(interval: Self.idleInterval)
    }

    // MARK: - Actions

    func closeSelected() {
        guard let target = thumbnailUnderMouse() else { return }
        close(target)
    }

    func minimizeSelected() {
        guard let target = thumbnailUnderMouse() else { return }
        WindowResolver.minimize(target)
        refreshSoon()
    }

    func hideSelectedApp() {
        guard let target = thumbnailUnderMouse() else { return }
        WindowResolver.hideApp(of: target)
        refreshSoon()
    }

    func quitSelectedApp() {
        guard let target = thumbnailUnderMouse() else { return }
        WindowResolver.quitApp(of: target)
        refreshSoon()
    }

    func openSelected() {
        guard let target = thumbnailUnderMouse() else { return }
        WindowResolver.open(target)
    }

    // MARK: - Spaces

    /// Adds a new desktop on the display under the mouse (the Spaces bar "+" button).
    func createSpace() {
        let displayID = NSScreen.underMouse?.displayID
        guard let addButton = monitor.spacesBar(displayID: displayID)?.addButton else {
            Log.error("createSpace: no add-desktop button found")
            NSSound.beep()
            return
        }
        if !addButton.perform(kAXPressAction) { Log.error("createSpace: pressing the add-desktop button failed") }
    }

    /// Switches to Space `number` (1-based) on the display under the mouse by pressing it in the Spaces bar.
    /// This closes Mission Control.
    func selectSpace(_ number: Int) {
        let displayID = NSScreen.underMouse?.displayID
        guard let spaces = monitor.spacesBar(displayID: displayID)?.spaces, spaces.indices.contains(number - 1) else {
            NSSound.beep()
            return
        }
        if !spaces[number - 1].perform(kAXPressAction) { Log.error("selectSpace: pressing Space \(number) failed") }
    }

    /// Moves the window under the mouse to the Space left/right of the one it is on.
    /// With `follow`, Mission Control also switches to that Space and the window stays selected,
    /// so repeating the shortcut carries it further (Space 1 → 2 → 3).
    func moveSelectedWindowToSpace(_ direction: Direction, follow: Bool = false) {
        guard let target = thumbnailUnderMouse() else { return }
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        guard let windowID = target.windowID,
              let displayID = NSScreen.containing(globalPoint: center)?.displayID,
              let spaceIDs = SpacesInfo.spaceIDs(displayID: displayID) else {
            NSSound.beep()
            return
        }
        // Windows shown on all Spaces belong to several Spaces and can't be moved.
        let windowSpaces = SpacesInfo.spaces(ofWindow: windowID)
        guard windowSpaces.count == 1, let index = spaceIDs.firstIndex(of: windowSpaces[0]) else {
            NSSound.beep()
            return
        }
        let targetIndex = direction == .left ? index - 1 : index + 1
        guard spaceIDs.indices.contains(targetIndex),
              SpaceMover.moveWindow(windowID, toSpace: spaceIDs[targetIndex]) else {
            NSSound.beep()
            return
        }
        if follow {
            let targetSpaceID = spaceIDs[targetIndex]
            followedWindow = (windowID, targetSpaceID, Date().addingTimeInterval(2))
            spaceSwitchWillBegin()
            // Let the asynchronous move reach WindowManager before asking Mission Control to follow it. Posting
            // its native Control-arrow shortcut keeps Mission Control open; the private SetCurrentSpace operation
            // must not be used because it desynchronizes WindowManager/Dock from the window server.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard self?.isActive == true else { return }
                Self.postSpaceSwitch(direction)
            }
        }
        refreshSoon()
    }

    private static func postSpaceSwitch(_ direction: Direction) {
        let keyCode: CGKeyCode = direction == .left ? 123 : 124
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            Log.error("could not create the Space-switch keyboard event")
            return
        }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// After a move with `follow`, puts the cursor back on the window once its thumbnail shows up on the new Space.
    private func hoverFollowedWindow() {
        guard let followed = followedWindow else { return }
        if lastDisplayedSpaces.contains(followed.spaceID),
           let thumbnail = thumbnails.first(where: { $0.windowID == followed.windowID }) {
            followedWindow = nil
            hover(thumbnail)
        } else if Date() > followed.deadline {
            followedWindow = nil
        }
    }

    func togglePreview() {
        isPreviewing.toggle()
    }

    func endPreview() {
        isPreviewing = false
    }

    func moveSelection(_ direction: Direction) {
        guard !thumbnails.isEmpty else { return }
        guard let current = thumbnailUnderMouse() else {
            if let first = thumbnails.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
                hover(first)
            }
            return
        }

        let from = CGPoint(x: current.frame.midX, y: current.frame.midY)
        var best: (thumbnail: Thumbnail, score: CGFloat)?
        for thumbnail in thumbnails where !thumbnail.isSameElement(as: current) {
            let dx = thumbnail.frame.midX - from.x
            let dy = thumbnail.frame.midY - from.y // AX coordinates: y grows downwards
            let (primary, secondary): (CGFloat, CGFloat)
            switch direction {
            case .left: (primary, secondary) = (-dx, dy)
            case .right: (primary, secondary) = (dx, dy)
            case .up: (primary, secondary) = (-dy, dx)
            case .down: (primary, secondary) = (dy, dx)
            }
            guard primary > 1 else { continue }
            let score = primary + abs(secondary) * 2
            if best == nil || score < best!.score {
                best = (thumbnail, score)
            }
        }
        if let best { hover(best.thumbnail) }
    }

    private func close(_ target: Thumbnail) {
        WindowResolver.close(target)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.tick() }
    }

    /// Moves the cursor onto the thumbnail with a real mouse-moved event,
    /// so Mission Control draws its own hover highlight there.
    private func hover(_ thumbnail: Thumbnail) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: Self.pointerPoint(on: thumbnail), mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Where the cursor goes on a thumbnail: slightly below the center, so it doesn't cover the window name shown there.
    /// AX and CGEvent share the same global top-left-origin coordinate space.
    private static func pointerPoint(on thumbnail: Thumbnail) -> CGPoint {
        let offset = min(44, thumbnail.frame.height * 0.25)
        return CGPoint(x: thumbnail.frame.midX, y: thumbnail.frame.midY + offset)
    }

    // MARK: - Refresh loop

    private func schedule(interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isEnabled else { return }

        guard let snapshot = monitor.snapshot() else {
            deactivate()
            return
        }
        if !isActive {
            isActive = true
            lastDisplayedSpaces = snapshot.displayedSpaces
            schedule(interval: Self.activeInterval)
        }

        // Mission Control shows another Space: after a Space-switch key, or a click in the Spaces bar, etc.
        if snapshot.displayedSpaces != lastDisplayedSpaces {
            lastDisplayedSpaces = snapshot.displayedSpaces
            displayedSpaceDidChange()
        }

        thumbnails = snapshot.thumbnails
        if isSwitchingSpace { updateSpaceSwitch() }
        layoutCloseButtons()
        hoverFollowedWindow()
    }

    /// Called from the keyboard tap when a Space-switching key (⌃←/→, ⌃1…) is pressed in Mission Control:
    /// hides the (x) buttons at once, before the switch animation starts.
    func spaceSwitchWillBegin() {
        guard isActive else { return }
        isSwitchingSpace = true
        isAwaitingSpaceChange = true
        spaceSwitchStart = Date()
        // The key may not switch at all (e.g. ⌃→ on the last Space): then the buttons come back after this.
        spaceSwitchDeadline = Date().addingTimeInterval(Self.announcedSwitchTimeout)
        layoutCloseButtons()
        schedule(interval: Self.switchingInterval)
    }

    /// The buttons stay hidden until the switch animation, which started at the key press (or now), has finished.
    private func displayedSpaceDidChange() {
        if !isSwitchingSpace { spaceSwitchStart = Date() }
        isSwitchingSpace = true
        isAwaitingSpaceChange = false
        showButtonsAt = max(spaceSwitchStart.addingTimeInterval(Self.switchAnimationDuration), Date())
        layoutCloseButtons()
        schedule(interval: Self.switchingInterval)
    }

    private func updateSpaceSwitch() {
        let now = Date()
        let finished = isAwaitingSpaceChange ? now > spaceSwitchDeadline : now >= showButtonsAt
        if finished {
            isSwitchingSpace = false
            isAwaitingSpaceChange = false
            schedule(interval: Self.activeInterval)
        }
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        isPreviewing = false
        isSwitchingSpace = false
        followedWindow = nil
        thumbnails = []
        closePanels.forEach { $0.orderOut(nil) }
        schedule(interval: Self.idleInterval)
    }

    private func thumbnailUnderMouse() -> Thumbnail? {
        let mouse = NSEvent.mouseLocation
        return thumbnails.first { $0.frame.flippedToCocoa.contains(mouse) }
    }

    // MARK: - Overlays

    private func layoutCloseButtons() {
        let size = CloseButtonView.panelSize
        let visibleThumbnails = isPreviewing || isSwitchingSpace ? [] : thumbnails
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, thumbnail) in visibleThumbnails.enumerated() {
            let panel: OverlayPanel
            if index < closePanels.count {
                panel = closePanels[index]
            } else {
                let view = CloseButtonView(frame: NSRect(x: 0, y: 0, width: size, height: size))
                panel = OverlayPanel(contentRect: view.frame, view: view, ignoresMouse: false)
                closePanels.append(panel)
            }
            (panel.contentView as? CloseButtonView)?.onClick = { [weak self] in self?.close(thumbnail) }

            // Circle center sits just inside the thumbnail's top-left corner, overlapping the edge.
            let frame = thumbnail.frame.flippedToCocoa
            let inset = CloseButtonView.diameter / 6
            let origin = NSPoint(x: frame.minX + inset - size / 2, y: frame.maxY - inset - size / 2)
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            if !panel.isVisible {
                panel.alphaValue = reduceMotion ? 1 : 0
                panel.orderFrontRegardless()
                if !reduceMotion {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        panel.animator().alphaValue = 1
                    }
                }
            }
        }
        for panel in closePanels.dropFirst(visibleThumbnails.count) where panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
