import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var permissionTimer: Timer?

    private let monitor = MissionControlMonitor()
    private lazy var controller = MissionControlController(monitor: monitor)
    private lazy var keyboard = KeyboardInterceptor(controller: controller)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        if Accessibility.isTrusted(prompt: true) {
            start()
        } else {
            // Wait until the user grants the permission in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard Accessibility.isTrusted(prompt: false) else { return }
                timer.invalidate()
                self?.start()
            }
        }
        updateMenu()
    }

    private func start() {
        controller.start()
        keyboard.start()
        updateMenu()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpaceControl")

        let menu = NSMenu()
        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)

        permissionMenuItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)

        menu.addItem(.separator())
        let help = NSMenuItem(title: "In Mission Control: ←↑↓→ / hjkl select · ⏎ open · ⌘W close · ⌘M minimize · ⌘H hide · ⌘Q quit", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SpaceControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func updateMenu() {
        let trusted = Accessibility.isTrusted(prompt: false)
        permissionMenuItem.isHidden = trusted
        enabledMenuItem.isEnabled = trusted
        enabledMenuItem.state = controller.isEnabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        controller.isEnabled.toggle()
        updateMenu()
    }

    @objc private func openAccessibilitySettings() {
        _ = Accessibility.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
