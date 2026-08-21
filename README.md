# MrTab

A window switcher for macOS, in the spirit of [AltTab](https://github.com/lwouis/alt-tab-macos).
It lists every open window — not every app — and switches to the one you pick.

The single design goal is that **pressing the shortcut shows the list instantly**. Everything below
follows from that.

```
⌥ Tab      open the switcher, select the previous window
⌥ held     tap Tab to move down the list, tap ⇧ to move back up
           the arrow keys work too
⌥ release  switch to the highlighted window
Esc        cancel and stay where you are
Return     switch immediately
W          close the highlighted window
```

The shortcut is whatever you set it to; `⌥ Tab` is only the default.

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
./build.sh              # produces build/MrTab.app
./build.sh --run        # build, then launch it
./build.sh --debug      # unoptimised build
./build.sh --universal  # fat binary for both Apple Silicon and Intel
```

The app icon is drawn in code by `IconGenerator` and turned into an `.icns` during the build, so
the artwork is source you can diff rather than a checked-in binary.

A plain build targets only the machine that built it. `--universal` cross-compiles both slices and
`lipo`s them together; it needs nothing beyond the command line tools, since it spells out the
target triples rather than using `swift build --arch`, which would require a full Xcode install.

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

## Releases

Every push to `main` builds on a GitHub Actions macOS runner and publishes a universal bundle as
`v0.1.<run number>`. Installing the latest release:

```sh
curl -L https://github.com/andrecarlucci/mrtab/releases/latest/download/MrTab.tar.gz | tar -xz -C /Applications
open /Applications/MrTab.app
```

CI builds the real artefact rather than a reduced one — macOS runners ship the whole toolchain, and
ad-hoc signing needs no keychain or secrets. What it cannot do is notarise, which needs the paid
Developer ID certificate, or exercise the hotkey path, which needs an Accessibility grant no runner
can give. So the verify step checks what is checkable: both architectures present, signature valid,
icon present, version stamped.

## Running it on another Mac

Building from source there is the least friction, because it settles architecture, signing and
Gatekeeper in one go:

```sh
xcode-select --install    # if the command line tools are missing
git clone https://github.com/andrecarlucci/mrtab.git
cd mrtab
./build.sh --run
```

Then grant Accessibility as above. macOS 13 or later.

To copy the built app across instead, build it for both architectures first — otherwise it will
not launch on a Mac with a different chip:

```sh
./build.sh --universal
```

Move `build/MrTab.app` over, then **clear the quarantine flag on the receiving Mac**:

```sh
xattr -dr com.apple.quarantine /Applications/MrTab.app
```

Without that it will not open. The app is ad-hoc signed and not notarised, so anything arriving by
AirDrop, download or shared folder is quarantined on landing, and Gatekeeper blocks it. The message
macOS shows is misleading — "damaged and can't be opened" means unsigned by a known developer, not
corrupt.

Nothing else travels with the app: `~/.config/mrtab/config.json` and `~/Library/Logs/MrTab.log` are
per-machine, and Accessibility has to be granted separately on each Mac.

## Settings

The panel has a header with the app icon, its name, and a gear on the far right; clicking the gear
dismisses the switcher and opens Settings. The same window is on the menu bar item under
**Settings…** (⌘,), which is the way in when the switcher is not open.

Settings covers the shortcut, which windows get listed, the panel's proportions, and whether MrTab
opens at login. There is no OK or Cancel — changes apply the moment you make them and are written
straight to disk, which suits a utility whose whole surface is a handful of toggles.

To change the shortcut, click the shortcut field and press the combination you want. It has to
include ⌘, ⌥ or ⌃: the modifier is not decoration, it is what holds the switcher open, and Shift
alone will not do because Shift already means "step backwards". Esc leaves the field alone.

**Open at Login** is also a toggle on the menu bar item. It uses `SMAppService`, which registers
the bundle at its current path — move MrTab and you need to switch it off and on again.

## Configuration

Settings writes `~/.config/mrtab/config.json`; you can also edit it directly, in which case
restart MrTab to apply.

| Key | Default | Meaning |
| --- | --- | --- |
| `shortcut` | `{"keyCode": 48, "modifiers": ["option"]}` | Virtual key code plus modifier names |
| `includeMinimized` | `true` | List minimized windows |
| `includeHidden` | `true` | List windows of hidden apps |
| `showAllSpaces` | `true` | When `false`, only windows on the current Space |
| `panelWidth` | `620` | Panel width in points |
| `rowHeight` | `36` | Row height in points |
| `maxVisibleRows` | `12` | Rows shown before the list scrolls |
| `fullRefreshInterval` | `15` | Seconds between safety-net rescans |

Key codes are positional rather than characters, which is why the shortcut UI is the easier way to
set this. The older `{"modifier": "option", "key": "tab"}` form is still read, and is rewritten to
the structured form the first time settings are saved.

Choosing `⌘ Tab` makes MrTab compete with the system switcher rather than replace it — macOS wins
that fight. Replacing `⌘ Tab` outright needs a `CGEventTap` and Input Monitoring permission, which
is not implemented here.

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
| `Config.swift` | JSON settings, loading and saving |
| `Shortcut.swift` | Modifier+key model, Carbon translation, key code names |
| `SettingsWindowController.swift` | The settings window |
| `ShortcutRecorderView.swift` | Click-then-press shortcut field |
| `LoginItem.swift` | Launch at login via `SMAppService` |
| `IconGenerator.swift` | Draws the app icon; `build.sh` pipes it through `iconutil` |
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
