# SpaceControl — extra controls for Mission Control

A menu-bar app that adds these controls to macOS Mission Control:

- an **(x)** button on every window thumbnail that closes the window
- **⌘W** closes the selected window, which is the one Mission Control highlights under the mouse
- **← ↑ ↓ →** or **h j k l** move the selection between windows. The cursor moves to the next window, and Mission Control's own hover highlight follows it.
- **⌘M** minimizes the selected window
- **⌘H** hides the selected window's app
- **⌘Q** quits the selected window's app. Apps can still ask to save changes.
- **Return** opens the selected window
- **Space** previews the window as usual, and the (x) buttons hide while the preview is open

Spaces controls, also inside Mission Control:

- **⌘N** creates a new Space on the display under the mouse
- **⌘1 … ⌘9**, **⌘0** go to Space 1–10 on the display under the mouse. This closes Mission Control.
- **⌘← / ⌘→** move the selected window to the previous or next Space. There is no public API for this. SpaceControl uses SkyLight's private `SLSBridgedMoveWindowsToManagedSpaceOperation`, which works on macOS 27, and may break in future macOS versions.
- **⌘⌃← / ⌘⌃→** move the selected window to the previous or next Space and switch to that Space, with the window still selected. Press it again to carry the window further, for example from Space 1 to Space 3.

These are the default shortcuts. All of them can be changed in **Settings…** (menu-bar icon → Settings…, or ⌘,),
which also lets you hide the menu-bar icon. While the icon is hidden, launch SpaceControl again to open Settings.

## Requirements

Tested on macOS 27. The app reads Mission Control through its accessibility tree,
which isn't a public API. Other macOS versions arrange that tree differently, so the app may not work there.

## Build

```sh
xcodegen generate                 # regenerate SpaceControl.xcodeproj after editing project.yml
open SpaceControl.xcodeproj       # or:
xcodebuild -scheme SpaceControl -configuration Debug -derivedDataPath build build
```

The app is signed ad-hoc ("Sign to Run Locally"), so no Apple Developer account is needed.

## Permissions

On first launch, grant **Accessibility** access in System Settings → Privacy & Security → Accessibility.
The app needs it to read Mission Control's window thumbnails, act on windows, and handle keys.

With ad-hoc signing, every rebuild changes the code signature, so macOS may stop trusting the app.
If the buttons stop appearing, remove SpaceControl from the Accessibility list and add it again.
To avoid this, create a self-signed certificate in Keychain Access
(Certificate Assistant → Create a Certificate → type "Code Signing") and put its name in
`CODE_SIGN_IDENTITY` in `project.yml`.

## How it works

- `MissionControlMonitor` checks for the Dock's `mc` placeholder group to detect Mission Control.
  On macOS 27 the thumbnails themselves belong to `WindowManager.app`.
  They are `AXButton` elements inside `mc.display` groups, each with a `wid` attribute (the window's `CGWindowID`).
- `MissionControlController` refreshes about 10 times a second while Mission Control is open.
  It places the close-button panels above Mission Control.
- `WindowResolver` finds the real window by its `wid`, using `_AXUIElementGetWindow`.
  It presses that window's close button through the Accessibility API.
- `KeyboardInterceptor` is a `CGEventTap` that only takes key presses while Mission Control is open.
- Errors are written to the system log. In Console.app, filter by `SpaceControl`.

## License

MIT. See [LICENSE](LICENSE).
