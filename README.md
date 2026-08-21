# MrTab

A window switcher for macOS, in the spirit of [AltTab](https://github.com/lwouis/alt-tab-macos).
It lists every open window — not every app — and switches to the one you pick.

The single design goal is that **pressing the shortcut shows the list instantly**. Everything below
follows from that.

```
⌥ Tab      open the switcher, select the previous window
⌥ ⇧ Tab    open it going backwards
⌥ held     keep pressing Tab / ⇧Tab, or use the arrow keys
⌥ release  switch to the highlighted window
Esc        cancel and stay where you are
Return     switch immediately
W          close the highlighted window
```

`⌘ Tab` is left alone — the macOS app switcher keeps working as it always did.

## How it stays fast

There is no work on the hotkey path. When you press the shortcut, MrTab reads an array that is
already sitting in memory and calls `orderFront` on a window that already exists.

- **The window list is built ahead of time.** Enumerating windows means Accessibility IPC to every
  running app, which is far too slow to do on demand. Instead a background queue keeps a live list
  and republishes an immutable snapshot to the main thread. The hotkey handler only ever reads that
  snapshot.
- **The list is maintained by observers, not polling.** `AXObserver` notifications (window created,
  destroyed, minimized, retitled, focus changed) plus `NSWorkspace` app launch/activate/quit
  notifications keep it current. A full rescan runs every 15s purely to heal any drift.
- **The panel is created once and pre-warmed at launch.** It is drawn off-screen immediately after
  startup so the window server has already allocated its backing store and run a first draw pass.
  The first invocation costs the same as the thousandth.
- **The list is drawn by hand.** One custom `NSView` drawing a dozen rows, rather than a table view
  or a SwiftUI hierarchy that would need to be built and laid out on first display.
- **Icons are rasterised in advance.** Scaled once when a snapshot lands, cached by pid.
- **Accessibility calls are timeout-capped at 250ms** and never run on the main thread, so an app
  that is beachballing cannot stall the switcher.

## Build

Requires the Xcode command line tools. No Xcode project, no dependencies.

```sh
./build.sh          # produces build/MrTab.app
./build.sh --run    # build, then launch it
./build.sh --debug  # unoptimised build
```

## First run

MrTab needs **Accessibility** access to list windows and raise one. On first launch macOS will
prompt; grant it under System Settings → Privacy & Security → Accessibility. The app polls for the
grant and starts working the moment it is given — no restart needed.

It runs as a menu bar item (no Dock icon). The menu shows the active shortcut and offers a manual
rescan, the config file, and Quit.

### Rebuilding silently revokes the permission

This will bite you, so it is worth understanding. Without a signing identity the bundle is
**ad-hoc signed**, and TCC then records the grant against the binary's `cdhash`. Any rebuild that
changes the code changes that hash, and macOS stops honouring the grant — **while still showing the
toggle as switched on**. The symptom is a switcher that does nothing, and a log line reading
`trusted=false`.

The fix is to clear the stale entry and grant it again:

```sh
./build.sh --reset-permission
open build/MrTab.app          # prompts fresh; re-add MrTab in System Settings
```

To stop it happening at all, sign with a stable identity. Create a self-signed code signing
certificate once (Keychain Access → Certificate Assistant → Create a Certificate → name it
`MrTab-dev`, type *Code Signing*), then:

```sh
MRTAB_SIGN_IDENTITY=MrTab-dev ./build.sh
```

TCC keys the grant on the certificate rather than the binary hash, so it survives rebuilds.

### Diagnosing

MrTab logs to `~/Library/Logs/MrTab.log`. It records the trust state at launch, the result of hot
key registration, every time the shortcut fires, and how many windows each invocation found —
which is enough to tell "not trusted", "shortcut taken by another app" and "no windows" apart.

```sh
tail -f ~/Library/Logs/MrTab.log
```

## Configuration

`~/.config/mrtab/config.json`, written with defaults on first launch. Restart MrTab to apply.

| Key | Default | Meaning |
| --- | --- | --- |
| `modifier` | `"option"` | Hold-to-browse modifier: `option`, `command`, `control`, `shift` |
| `key` | `"tab"` | Trigger key: `tab`, `space`, `` ` ``, `escape` |
| `includeMinimized` | `true` | List minimized windows |
| `includeHidden` | `true` | List windows of hidden apps |
| `showAllSpaces` | `true` | When `false`, only windows on the current Space |
| `panelWidth` | `620` | Panel width in points |
| `rowHeight` | `36` | Row height in points |
| `maxVisibleRows` | `12` | Rows shown before the list scrolls |
| `fullRefreshInterval` | `15` | Seconds between safety-net rescans |

Setting `modifier` to `"command"` makes MrTab compete with the system switcher rather than replace
it — macOS wins that fight for `⌘ Tab`. Replacing `⌘ Tab` outright needs a `CGEventTap` and Input
Monitoring permission, which is not implemented here.

## Layout

| File | Role |
| --- | --- |
| `WindowStore.swift` | Background window tracking, AX observers, MRU ordering, snapshot publishing |
| `SwitcherController.swift` | Show / step / commit / cancel, modifier-release detection |
| `SwitcherPanel.swift` | The floating `NSPanel`, created once and pre-warmed |
| `SwitcherView.swift` | Hand-drawn row rendering |
| `HotKey.swift` | Carbon `RegisterEventHotKey` registration |
| `WindowStore` ↔ `AXHelpers.swift` | Typed wrappers over the Accessibility C API |
| `IconCache.swift` | Pre-scaled app icons by pid |
| `Config.swift` | JSON settings and shortcut translation |
| `Log.swift` | Append-only log; an agent app has no console to fail loudly in |
| `SelfTest.swift` | `MRTAB_RENDER=x.png` renders the list offscreen, no permissions needed |

### A note on legibility

The panel is translucent, so anything drawn at partial opacity competes with whatever is behind
it. Row text is therefore drawn at full strength and the app name is distinguished from the window
title by *weight* rather than opacity, over a scrim that keeps the base tone constant. The panel
also pins itself to a dark appearance rather than following the system theme — like the system
Command-Tab switcher — so the vibrancy material and the dynamic text colours can never disagree
about which of them is dark.

`SelfTest` renders over a stand-in for colourful wallpaper for this reason. A flat backdrop
flatters the design and hides exactly the contrast failures that matter.

## Known limitations

- No live window thumbnails. Icons and titles only — a deliberate choice, since thumbnails need
  Screen Recording permission and capture costs real time. `SwitcherView.Row` is the seam to add
  them behind.
- No type-to-filter.
- `⌘ Tab` cannot be replaced (see above).
- Windows on other Spaces are listed by default; switching to one moves you to that Space.
