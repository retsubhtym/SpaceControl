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

    private static let activeInterval: TimeInterval = 0.1
    private static let idleInterval: TimeInterval = 0.25

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
        // AX and CGEvent share the same global top-left-origin coordinate space.
        // Park the cursor slightly below the center so it doesn't cover the window name shown there.
        let offset = min(44, thumbnail.frame.height * 0.25)
        let point = CGPoint(x: thumbnail.frame.midX, y: thumbnail.frame.midY + offset)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
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

        let current = monitor.thumbnails()
        guard !current.isEmpty else {
            deactivate()
            return
        }
        if !isActive {
            isActive = true
            schedule(interval: Self.activeInterval)
        }
        thumbnails = current
        layoutCloseButtons()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        isPreviewing = false
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
        let visibleThumbnails = isPreviewing ? [] : thumbnails
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
