import Cocoa
import Combine

/// Modifier keys of a shortcut.
struct KeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ flags: CGEventFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        self = modifiers
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    /// In the standard macOS order: ⌃⌥⇧⌘.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key (hardware key code, independent of the keyboard layout) plus modifiers.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: KeyModifiers

    var displayString: String { modifiers.symbols + KeyNames.name(for: keyCode) }

    /// Space without modifiers: Mission Control's window preview.
    var isPreviewKey: Bool { keyCode == KeyNames.space && modifiers.isEmpty }
    /// Escape with any modifiers: leaves Mission Control / closes the preview.
    var isEscape: Bool { keyCode == KeyNames.escape }
    /// ⌃←, ⌃→ and ⌃1…⌃0: native Space switching.
    var isNativeSpaceSwitch: Bool {
        modifiers == .control
            && (keyCode == KeyNames.left || keyCode == KeyNames.right || KeyNames.digits[keyCode] != nil)
    }

    /// Keys Mission Control handles itself. They can't be recorded and are never bound to an action.
    var isReserved: Bool { isPreviewKey || isEscape || isNativeSpaceSwitch }
}

enum KeyNames {
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// Top-row digit key codes mapped to Space numbers (0 is Space 10).
    static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]

    private static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]

    static func name(for keyCode: UInt16) -> String { names[keyCode] ?? "Key \(keyCode)" }
}

/// Actions that can be bound to shortcuts inside Mission Control.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case closeWindow, minimizeWindow, hideApp, quitApp, openWindow
    case selectLeft, selectRight, selectUp, selectDown
    case newSpace, moveWindowLeft, moveWindowRight, moveWindowLeftAndFollow, moveWindowRightAndFollow

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case windows = "Windows"
        case selection = "Selection"
        case spaces = "Spaces"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .closeWindow, .minimizeWindow, .hideApp, .quitApp, .openWindow: return .windows
        case .selectLeft, .selectRight, .selectUp, .selectDown: return .selection
        case .newSpace, .moveWindowLeft, .moveWindowRight, .moveWindowLeftAndFollow, .moveWindowRightAndFollow: return .spaces
        }
    }

    var title: String {
        switch self {
        case .closeWindow: return "Close window"
        case .minimizeWindow: return "Minimize window"
        case .hideApp: return "Hide app"
        case .quitApp: return "Quit app"
        case .openWindow: return "Open window"
        case .selectLeft: return "Select window on the left"
        case .selectRight: return "Select window on the right"
        case .selectUp: return "Select window above"
        case .selectDown: return "Select window below"
        case .newSpace: return "New Space"
        case .moveWindowLeft: return "Move window to previous Space"
        case .moveWindowRight: return "Move window to next Space"
        case .moveWindowLeftAndFollow: return "Move window to previous Space and follow"
        case .moveWindowRightAndFollow: return "Move window to next Space and follow"
        }
    }

    /// Up to two default shortcuts (e.g. an arrow key and its vim key).
    var defaultShortcuts: [Shortcut] {
        func key(_ code: UInt16, _ modifiers: KeyModifiers = []) -> Shortcut { Shortcut(keyCode: code, modifiers: modifiers) }
        switch self {
        case .closeWindow: return [key(13, .command)]
        case .minimizeWindow: return [key(46, .command)]
        case .hideApp: return [key(4, .command)]
        case .quitApp: return [key(12, .command)]
        case .openWindow: return [key(36), key(76)]
        case .selectLeft: return [key(KeyNames.left), key(4)]
        case .selectRight: return [key(KeyNames.right), key(37)]
        case .selectUp: return [key(KeyNames.up), key(40)]
        case .selectDown: return [key(KeyNames.down), key(38)]
        case .newSpace: return [key(45, .command)]
        case .moveWindowLeft: return [key(KeyNames.left, .command)]
        case .moveWindowRight: return [key(KeyNames.right, .command)]
        case .moveWindowLeftAndFollow: return [key(KeyNames.left, [.command, .control])]
        case .moveWindowRightAndFollow: return [key(KeyNames.right, [.command, .control])]
        }
    }
}

/// User settings, saved in UserDefaults. Used from the main thread only.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Two slots per action; `nil` means unassigned.
    @Published var shortcuts: [HotkeyAction: [Shortcut?]] { didSet { save() } }
    /// Modifiers held with 1…9, 0 to go to Space 1–10.
    @Published var goToSpaceModifiers: KeyModifiers { didSet { save() } }
    @Published var showStatusItem: Bool { didSet { save() } }

    static let slotsPerAction = 2
    static let defaultGoToSpaceModifiers: KeyModifiers = .command

    private let defaults = UserDefaults.standard
    private enum Key {
        static let shortcuts = "shortcuts"
        static let goToSpaceModifiers = "goToSpaceModifiers"
        static let showStatusItem = "showStatusItem"
    }

    private init() {
        let stored = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode([String: [Shortcut?]].self, from: $0) } ?? [:]
        var shortcuts: [HotkeyAction: [Shortcut?]] = [:]
        for action in HotkeyAction.allCases {
            shortcuts[action] = Self.padded(stored[action.rawValue] ?? action.defaultShortcuts)
        }
        self.shortcuts = shortcuts
        goToSpaceModifiers = defaults.object(forKey: Key.goToSpaceModifiers)
            .flatMap { ($0 as? NSNumber).map { KeyModifiers(rawValue: $0.uint8Value) } } ?? Self.defaultGoToSpaceModifiers
        showStatusItem = defaults.object(forKey: Key.showStatusItem) as? Bool ?? true
    }

    func shortcut(for action: HotkeyAction, slot: Int) -> Shortcut? {
        shortcuts[action]?[slot] ?? nil
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction, slot: Int) {
        var slots = shortcuts[action] ?? Self.padded([])
        slots[slot] = shortcut
        shortcuts[action] = slots
    }

    func restoreDefaults() {
        var shortcuts: [HotkeyAction: [Shortcut?]] = [:]
        for action in HotkeyAction.allCases {
            shortcuts[action] = Self.padded(action.defaultShortcuts)
        }
        self.shortcuts = shortcuts
        goToSpaceModifiers = Self.defaultGoToSpaceModifiers
    }

    /// Shortcuts that won't work as configured: used by more than one binding (including the ten "go to Space"
    /// digits), or reserved for Mission Control (e.g. saved by an older version, or ⌃ alone for "go to Space").
    var conflictingShortcuts: Set<Shortcut> {
        var counts: [Shortcut: Int] = [:]
        for slots in shortcuts.values {
            for case let shortcut? in slots { counts[shortcut, default: 0] += 1 }
        }
        for keyCode in KeyNames.digits.keys {
            counts[Shortcut(keyCode: keyCode, modifiers: goToSpaceModifiers), default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 || $0.key.isReserved }.keys)
    }

    /// Bindings in a fixed order: actions as listed in Settings, each action's slots in order, then the ten
    /// "go to Space" digits. On a duplicate the first binding wins, so the result doesn't depend on dictionary order.
    /// Reserved shortcuts are left out.
    var orderedBindings: [(shortcut: Shortcut, command: Command)] {
        Self.orderedBindings(shortcuts: shortcuts, goToSpaceModifiers: goToSpaceModifiers)
    }

    /// Takes the values explicitly: `@Published` observers are called before the properties change.
    static func orderedBindings(
        shortcuts: [HotkeyAction: [Shortcut?]], goToSpaceModifiers: KeyModifiers
    ) -> [(shortcut: Shortcut, command: Command)] {
        var result: [(Shortcut, Command)] = []
        var used: Set<Shortcut> = []
        func add(_ shortcut: Shortcut, _ command: Command) {
            guard !shortcut.isReserved, used.insert(shortcut).inserted else { return }
            result.append((shortcut, command))
        }
        for action in HotkeyAction.allCases {
            for case let shortcut? in shortcuts[action] ?? [] { add(shortcut, .action(action)) }
        }
        for (keyCode, number) in KeyNames.digits.sorted(by: { $0.value < $1.value }) {
            add(Shortcut(keyCode: keyCode, modifiers: goToSpaceModifiers), .goToSpace(number))
        }
        return result
    }

    enum Command {
        case action(HotkeyAction)
        case goToSpace(Int)
    }

    private static func padded(_ shortcuts: [Shortcut?]) -> [Shortcut?] {
        Array((shortcuts + Array(repeating: nil, count: slotsPerAction)).prefix(slotsPerAction))
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) { defaults.set(data, forKey: Key.shortcuts) }
        defaults.set(goToSpaceModifiers.rawValue, forKey: Key.goToSpaceModifiers)
        defaults.set(showStatusItem, forKey: Key.showStatusItem)
    }
}
