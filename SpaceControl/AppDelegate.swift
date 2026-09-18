import Cocoa
import Combine

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var permissionTimer: Timer?

    private let settings = AppSettings.shared
    private let settingsWindow = SettingsWindowController()
    private var statusItemObserver: AnyCancellable?

    private let monitor = MissionControlMonitor()
    private lazy var controller = MissionControlController(monitor: monitor)
    private lazy var keyboard = KeyboardInterceptor(controller: controller, settings: settings)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMainMenu()

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

    /// Launching the app again (Finder, Spotlight, Launchpad) opens Settings, the way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    private func start() {
        controller.start()
        keyboard.start()
        updateMenu()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Template image: macOS tints it for light/dark menu bars and the highlighted state.
        let icon = NSImage(named: "StatusBarIcon")
            ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "SpaceControl"
        statusItem.button?.image = icon

        let menu = NSMenu()
        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)

        permissionMenuItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SpaceControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        statusItemObserver = settings.$showStatusItem.sink { [weak self] isShown in
            self?.statusItem.isVisible = isShown
        }
    }

    /// The menu bar shown while Settings is open and the app is a regular app.
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SpaceControl", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SpaceControl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SpaceControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        mainMenu.addItem(withTitle: "SpaceControl", action: nil, keyEquivalent: "").submenu = appMenu
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openSettings() {
        settingsWindow.show()
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
