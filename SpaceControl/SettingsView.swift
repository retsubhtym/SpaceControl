import SwiftUI

/// The Settings window, reused while open.
///
/// While it is open the app behaves like a normal app (Dock icon, ⌘Tab, menu bar); once it closes the app
/// goes back to being menu-bar only.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared)))
            window.title = "SpaceControl Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 680))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        // Activate after the policy change has taken effect, otherwise the window can open behind other apps.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate()
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let conflicts = settings.conflictingShortcuts
        Form {
            Section("General") {
                Toggle("Show icon in menu bar", isOn: $settings.showStatusItem)
                if !settings.showStatusItem {
                    Text("To open Settings while the icon is hidden, launch SpaceControl again from Finder, Spotlight or Launchpad.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(HotkeyAction.Group.allCases) { group in
                Section {
                    ForEach(HotkeyAction.allCases.filter { $0.group == group }) { action in
                        ShortcutRow(action: action, settings: settings, conflicts: conflicts)
                    }
                    if group == .spaces {
                        GoToSpaceRow(settings: settings, conflicts: conflicts)
                    }
                } header: {
                    Text(group.rawValue)
                } footer: {
                    if group == .spaces {
                        Text("⌃← / ⌃→ and ⌃1…⌃0 keep switching Spaces as usual. Space previews a window, Esc leaves Mission Control.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    if !conflicts.isEmpty {
                        Label("Some shortcuts are used more than once.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Restore Defaults") { settings.restoreDefaults() }
                }
            } footer: {
                Text("Shortcuts work only while Mission Control is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 500)
    }
}

private struct ShortcutRow: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    let conflicts: Set<Shortcut>

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                ForEach(0..<AppSettings.slotsPerAction, id: \.self) { slot in
                    let shortcut = settings.shortcut(for: action, slot: slot)
                    ShortcutRecorder(
                        shortcut: Binding(
                            get: { settings.shortcut(for: action, slot: slot) },
                            set: { settings.setShortcut($0, for: action, slot: slot) }
                        ),
                        isConflicting: shortcut.map(conflicts.contains) ?? false
                    )
                }
            }
        }
    }
}

private struct GoToSpaceRow: View {
    @ObservedObject var settings: AppSettings
    let conflicts: Set<Shortcut>

    var body: some View {
        let modifiers = settings.goToSpaceModifiers
        let isConflicting = KeyNames.digits.keys.contains { conflicts.contains(Shortcut(keyCode: $0, modifiers: modifiers)) }
        LabeledContent {
            goToSpaceControls(isConflicting: isConflicting)
        } label: {
            Text("Go to Space 1–10")
            if modifiers == .control {
                Text("⌃1…0 already switches Spaces natively. Choose another modifier.")
                    .foregroundStyle(.red)
            }
        }
    }

    private func goToSpaceControls(isConflicting: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach([(KeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")], id: \.1) { modifier, symbol in
                Toggle(symbol, isOn: Binding(
                    get: { settings.goToSpaceModifiers.contains(modifier) },
                    set: { isOn in
                        if isOn { settings.goToSpaceModifiers.insert(modifier) } else { settings.goToSpaceModifiers.remove(modifier) }
                    }
                ))
                .toggleStyle(.button)
            }
            Text("+ 1…0")
                .foregroundStyle(isConflicting ? .red : .secondary)
                .frame(minWidth: 44, alignment: .leading)
        }
    }
}

/// Click to record a shortcut: the next key press (with modifiers) is saved. Esc cancels, Delete clears.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let isConflicting: Bool
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(foreground)
                    .frame(width: 92)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .help(isRecording ? "Press a shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")

            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(shortcut == nil || isRecording ? 0 : 1)
            .disabled(shortcut == nil || isRecording)
            .help("Clear")
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Type shortcut" }
        return shortcut?.displayString ?? "—"
    }

    private var foreground: Color {
        if isRecording { return .accentColor }
        if isConflicting { return .red }
        return shortcut == nil ? .secondary : .primary
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let recorded = Shortcut(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags))
            switch (recorded.keyCode, recorded.modifiers.isEmpty) {
            case (KeyNames.escape, true):
                break // cancel
            case (KeyNames.delete, true), (KeyNames.forwardDelete, true):
                shortcut = nil
            default:
                // Space, Esc with modifiers, ⌃←/→ and ⌃1…0 belong to Mission Control: refuse and keep recording.
                guard !recorded.isReserved else {
                    NSSound.beep()
                    return nil
                }
                shortcut = recorded
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
