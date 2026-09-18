import Cocoa

/// Global key-down event tap. Only consumes keys while Mission Control is shown.
final class KeyboardInterceptor {
    private let controller: MissionControlController
    private var eventTap: CFMachPort?

    private enum KeyCode {
        static let w: Int64 = 13
        static let m: Int64 = 46
        static let q: Int64 = 12
        static let h: Int64 = 4
        static let j: Int64 = 38
        static let k: Int64 = 40
        static let l: Int64 = 37
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let space: Int64 = 49
        static let escape: Int64 = 53
        static let n: Int64 = 45
        /// Top-row digit key codes mapped to Space numbers (⌘0 is Space 10).
        static let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]
    }

    init(controller: MissionControlController) {
        self.controller = controller
    }

    func start() {
        guard eventTap == nil else { return }
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, controller.isEnabled, controller.isActive else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        // Keys Mission Control handles itself: only observe them, never consume.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if keyCode == KeyCode.space, modifiers.isEmpty, !isRepeat {
            DispatchQueue.main.async { self.controller.togglePreview() }
            return Unmanaged.passUnretained(event)
        }
        if keyCode == KeyCode.escape {
            DispatchQueue.main.async { self.controller.endPreview() }
            return Unmanaged.passUnretained(event)
        }
        // Native Space switching (⌃←/→, ⌃1…): hide the (x) buttons right away until the new Space settles.
        if modifiers == [.maskControl],
           keyCode == KeyCode.left || keyCode == KeyCode.right || KeyCode.digits[keyCode] != nil {
            DispatchQueue.main.async { self.controller.spaceSwitchWillBegin() }
            return Unmanaged.passUnretained(event)
        }

        let action: (() -> Void)?
        switch (keyCode, modifiers) {
        case (KeyCode.w, [.maskCommand]):
            action = controller.closeSelected
        case (KeyCode.m, [.maskCommand]):
            action = controller.minimizeSelected
        case (KeyCode.h, [.maskCommand]):
            action = controller.hideSelectedApp
        case (KeyCode.q, [.maskCommand]):
            action = controller.quitSelectedApp
        case (KeyCode.n, [.maskCommand]):
            action = controller.createSpace
        case (KeyCode.left, [.maskCommand]):
            action = { self.controller.moveSelectedWindowToSpace(.left) }
        case (KeyCode.right, [.maskCommand]):
            action = { self.controller.moveSelectedWindowToSpace(.right) }
        case (KeyCode.left, [.maskCommand, .maskControl]):
            action = { self.controller.moveSelectedWindowToSpace(.left, follow: true) }
        case (KeyCode.right, [.maskCommand, .maskControl]):
            action = { self.controller.moveSelectedWindowToSpace(.right, follow: true) }
        case (_, [.maskCommand]) where KeyCode.digits[keyCode] != nil:
            let number = KeyCode.digits[keyCode]!
            action = { self.controller.selectSpace(number) }
        case (KeyCode.left, []), (KeyCode.h, []):
            action = { self.controller.moveSelection(.left) }
        case (KeyCode.right, []), (KeyCode.l, []):
            action = { self.controller.moveSelection(.right) }
        case (KeyCode.up, []), (KeyCode.k, []):
            action = { self.controller.moveSelection(.up) }
        case (KeyCode.down, []), (KeyCode.j, []):
            action = { self.controller.moveSelection(.down) }
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []):
            action = controller.openSelected
        default:
            action = nil
        }

        guard let action else { return Unmanaged.passUnretained(event) }
        // Return quickly from the tap; AX calls may take a moment.
        DispatchQueue.main.async(execute: action)
        return nil
    }
}
