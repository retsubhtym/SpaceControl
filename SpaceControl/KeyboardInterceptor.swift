import Cocoa
import Combine

/// Global key-down event tap. Only consumes keys while Mission Control is shown.
final class KeyboardInterceptor {
    private let controller: MissionControlController
    private let settings: AppSettings
    private var eventTap: CFMachPort?
    /// Shortcut → action, rebuilt whenever the settings change. Read from the event tap on the main thread.
    private var bindings: [Shortcut: () -> Void] = [:]
    private var settingsObserver: AnyCancellable?

    init(controller: MissionControlController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
    }

    func start() {
        guard eventTap == nil else { return }
        settingsObserver = Publishers.CombineLatest(settings.$shortcuts, settings.$goToSpaceModifiers)
            .sink { [weak self] shortcuts, goToSpaceModifiers in
                self?.rebuildBindings(shortcuts: shortcuts, goToSpaceModifiers: goToSpaceModifiers)
            }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("failed to create keyboard event tap (Accessibility permission missing?)")
            return
        }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func rebuildBindings(shortcuts: [HotkeyAction: [Shortcut?]], goToSpaceModifiers: KeyModifiers) {
        // Fixed order, first binding wins, reserved shortcuts left out (see `AppSettings.orderedBindings`).
        var bindings: [Shortcut: () -> Void] = [:]
        let controller = controller
        for (shortcut, command) in AppSettings.orderedBindings(shortcuts: shortcuts, goToSpaceModifiers: goToSpaceModifiers) {
            switch command {
            case .action(let action): bindings[shortcut] = perform(action)
            case .goToSpace(let number): bindings[shortcut] = { controller.selectSpace(number) }
            }
        }
        self.bindings = bindings
    }

    private func perform(_ action: HotkeyAction) -> () -> Void {
        let controller = controller
        switch action {
        case .closeWindow: return controller.closeSelected
        case .minimizeWindow: return controller.minimizeSelected
        case .hideApp: return controller.hideSelectedApp
        case .quitApp: return controller.quitSelectedApp
        case .openWindow: return controller.openSelected
        case .selectLeft: return { controller.moveSelection(.left) }
        case .selectRight: return { controller.moveSelection(.right) }
        case .selectUp: return { controller.moveSelection(.up) }
        case .selectDown: return { controller.moveSelection(.down) }
        case .newSpace: return controller.createSpace
        case .moveWindowLeft: return { controller.moveSelectedWindowToSpace(.left) }
        case .moveWindowRight: return { controller.moveSelectedWindowToSpace(.right) }
        case .moveWindowLeftAndFollow: return { controller.moveSelectedWindowToSpace(.left, follow: true) }
        case .moveWindowRightAndFollow: return { controller.moveSelectedWindowToSpace(.right, follow: true) }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, controller.isEnabled, controller.isActive else {
            return Unmanaged.passUnretained(event)
        }

        let shortcut = Shortcut(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: KeyModifiers(event.flags)
        )

        // Keys Mission Control handles itself (`Shortcut.isReserved`): only observe them, never consume.
        if shortcut.isReserved {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if shortcut.isPreviewKey, !isRepeat {
                DispatchQueue.main.async { self.controller.togglePreview() }
            } else if shortcut.isEscape {
                DispatchQueue.main.async { self.controller.endPreview() }
            } else if shortcut.isNativeSpaceSwitch {
                // Hide the (x) buttons right away until the new Space settles.
                DispatchQueue.main.async { self.controller.spaceSwitchWillBegin() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let action = bindings[shortcut] else { return Unmanaged.passUnretained(event) }
        // Return quickly from the tap; AX calls may take a moment.
        DispatchQueue.main.async(execute: action)
        return nil
    }
}
