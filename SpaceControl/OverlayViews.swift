import Cocoa
import QuartzCore

/// Borderless, non-activating panel that floats above Mission Control on every Space.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, view: NSView, ignoresMouse: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = ignoresMouse
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Round (x) button drawn in the style of the traffic-light close button.
/// Liquid Glass close button: a glass circle with an SF Symbol "xmark".
/// Hover tints it red with a small symbol bounce; pressing shrinks it slightly.
final class CloseButtonView: NSView {
    /// Diameter of the visible circle.
    static let diameter: CGFloat = 28
    /// Transparent margin around the circle so the glass edge and shadow are not clipped.
    static let margin: CGFloat = 4
    static var panelSize: CGFloat { diameter + margin * 2 }

    var onClick: (() -> Void)?

    private let background: NSView
    private let icon = NSImageView()
    private var isHovered = false { didSet { updateAppearance() } }
    private var isPressed = false { didSet { updateCircleFrame(animated: true) } }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Self.diameter / 2
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.diameter / 2
            blur.layer?.masksToBounds = true
            background = blur
        }
        super.init(frame: frameRect)

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        icon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close window")?
            .withSymbolConfiguration(configuration)
        icon.imageScaling = .scaleNone
        icon.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = icon
        } else {
            icon.frame = background.bounds
            background.addSubview(icon)
        }
        addSubview(background)
        updateCircleFrame(animated: false)
        updateAppearance()

        setAccessibilityRole(.button)
        setAccessibilityLabel("Close window")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            icon.addSymbolEffect(.bounce.down, options: .nonRepeating)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?() }
    }

    private func updateAppearance() {
        let tint: NSColor? = isHovered ? NSColor.systemRed.withAlphaComponent(0.85) : nil
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.tintColor = tint
        } else {
            background.layer?.backgroundColor = tint?.cgColor
        }
        icon.contentTintColor = isHovered ? .white : .labelColor
    }

    private func updateCircleFrame(animated: Bool) {
        let inset = Self.margin + (isPressed ? 1.5 : 0)
        let frame = bounds.insetBy(dx: inset, dy: inset)
        if let glass = background as? NSVisualEffectView {
            glass.layer?.cornerRadius = frame.width / 2
        } else if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = frame.width / 2
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            background.frame = frame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            background.animator().frame = frame
        }
    }
}
