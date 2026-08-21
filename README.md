# MrTab

A window switcher for macOS, in the spirit of [AltTab](https://github.com/lwouis/alt-tab-macos).
It lists every open window — not every app — and switches to the one you pick.

The single design goal is that **pressing the shortcut shows the list instantly**. Most of what
follows is a consequence of that.

## Install

```sh
curl -L https://github.com/andrecarlucci/mrtab/releases/latest/download/MrTab.tar.gz | tar -xz -C /Applications
open /Applications/MrTab.app
```

MrTab opens its **Settings** window when you launch it, which is also how it reports whether it can
work at all:

1. The banner at the top will be **amber**, saying Accessibility has not been granted.
2. Click **Open System Settings**, then add and enable MrTab under
   Privacy & Security → Accessibility.
3. The banner turns **green** on its own — no restart, no reopening. The shortcut is live from that
   moment.

Then hold **⌥** and tap **Tab**.

Universal (Apple Silicon and Intel), macOS 13 or later. MrTab lives in the menu bar and has no Dock
icon.

> **Unpack with `tar` as above** rather than double-clicking a downloaded archive. MrTab is ad-hoc
> signed rather than notarised, and Archive Utility stamps whatever it extracts with
> `com.apple.quarantine`, which Gatekeeper then blocks — reporting it as *"damaged and can't be
> opened"*, which means unsigned, not corrupt. `tar` does not propagate the flag. If you end up
> with a blocked copy: `xattr -dr com.apple.quarantine /Applications/MrTab.app`.

### Accessibility is not optional

MrTab has no way to enumerate windows or raise one without it, and the failure is silent: the
shortcut simply does nothing. If the switcher ever stops responding, open Settings and read the
banner before assuming anything else is wrong.

## Using it

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

The panel has a header carrying the app icon, its name, and a gear on the far right. Clicking the
gear dismisses the switcher and opens Settings.

## Settings

Reachable three ways: the gear in the panel header, **Settings…** (⌘,) on the menu bar item, or
simply opening MrTab again from Applications or the Dock.

It covers the shortcut, which windows get listed, the panel's proportions, and whether MrTab opens
at login. There is no OK or Cancel — changes apply the moment you make them and are written
straight to disk, which suits a utility whose whole surface is a handful of toggles.

**Changing the shortcut.** Click the shortcut field and press the combination you want. It has to
include ⌘, ⌥ or ⌃: the modifier is not decoration, it is what holds the switcher open while you
browse. Shift alone will not do, because Shift already means "step backwards". Esc leaves the
field unchanged.

**Open at Login** is also a toggle on the menu bar item. It uses `SMAppService`, which registers
the bundle at its current path — move MrTab and you need to switch it off and on again.

Settings appears when *you* open MrTab, but not when macOS launches it at login. macOS offers no
dependable way to tell those apart — `XPC_SERVICE_NAME` is set for an ordinary Finder launch too —
so MrTab stays quiet only when it is both registered as a login item *and* the machine has just
come up. Logging out and back in without rebooting will show Settings once.

## Configuration

Settings writes `~/.config/mrtab/config.json`. You can edit it directly instead, in which case
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

Key codes are positional rather than characters, which is why the shortcut field is the easier way
to set this. The older `{"modifier": "option", "key": "tab"}` form is still read, and is rewritten
to the structured form the first time settings are saved.

Choosing `⌘ Tab` makes MrTab compete with the system switcher rather than replace it — macOS wins
that fight. Replacing `⌘ Tab` outright needs a `CGEventTap` and Input Monitoring permission, which
is not implemented here.

## How it stays fast

There is no work on the hotkey path. When you press the shortcut, MrTab reads an array that is
already sitting in memory and calls `orderFront` on a window that already exists.

- **The window list is built ahead of time.** Enumerating windows means Accessibility IPC to every
  running app, which is far too slow to do on demand. A background queue keeps a live list and
  republishes an immutable snapshot to the main thread. The hotkey handler only ever reads that
  snapshot.
- **The list is maintained by observers, not polling.** `AXObserver` notifications (window created,
  destroyed, minimized, retitled, focus changed) plus `NSWorkspace` app launch/activate/quit
  notifications keep it current. A full rescan runs every 15s purely to heal any drift.
- **The panel is created once and pre-warmed at launch.** It is drawn off-screen immediately after
  startup so the window server has already allocated its backing store and run a first draw pass.
  The first invocation costs the same as the thousandth.
- **The list is drawn by hand.** One custom `NSView` drawing a dozen rows, rather than a table view
  or a SwiftUI hierarchy that would need building and laying out on first display.
- **Icons are rasterised in advance.** Scaled once when a snapshot lands, cached by pid.
- **Accessibility calls are timeout-capped at 250ms** and never run on the main thread, so an app
  that is beachballing cannot stall the switcher.

## Building from source

Requires the Xcode command line tools. No Xcode project, no dependencies.

```sh
./build.sh              # produces build/MrTab.app
./build.sh --run        # build, then launch it
./build.sh --debug      # unoptimised build
./build.sh --universal  # fat binary for both Apple Silicon and Intel
./build.sh --package    # also produce build/MrTab.tar.gz
```

A plain build targets only the machine that built it. `--universal` cross-compiles both slices and
`lipo`s them together; it needs nothing beyond the command line tools, because it spells out the
target triples rather than using `swift build --arch`, which would require a full Xcode install.

The app icon is drawn in code by `IconGenerator` and turned into an `.icns` during the build, so
the artwork is source you can diff rather than a checked-in binary.

### Rebuilding silently revokes the permission

This will bite you, so it is worth understanding. Without a signing identity the bundle is
**ad-hoc signed**, and TCC records the grant against the binary's `cdhash`. Any rebuild that
changes the code changes that hash, and macOS stops honouring the grant — **while still showing the
toggle as switched on**. The symptom is a switcher that does nothing, and `trusted=false` in the
log.

Clear the stale entry and grant it again:

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

TCC then keys the grant on the certificate rather than the binary hash, so it survives rebuilds.

## Releases

Every push to `main` builds on a GitHub Actions macOS runner and publishes a universal bundle as
`v0.1.<run number>`, with both a versioned tarball and an unversioned one so
`releases/latest/download/MrTab.tar.gz` is a stable URL.

CI builds the real artefact rather than a reduced one — macOS runners ship the whole toolchain, and
ad-hoc signing needs no keychain or secrets. What it cannot do is notarise, which needs the paid
Developer ID certificate, or exercise the hotkey path, which needs an Accessibility grant no runner
can give. The verify step therefore checks what is checkable: both architectures present, signature
valid, icon present, version stamped.

## Running it on another Mac

Building from source there is the least friction, since it settles architecture, signing and
Gatekeeper in one go:

```sh
xcode-select --install    # if the command line tools are missing
git clone https://github.com/andrecarlucci/mrtab.git
cd mrtab
./build.sh --run
```

Otherwise use the install command at the top of this file, or copy a `--universal` build across.
Quarantine is applied by the *receiving* program, not by macOS in general, so how it arrives
decides whether Gatekeeper objects:

| Transfer | Quarantined? |
| --- | --- |
| Built locally, or `curl` + `tar -xz` | No |
| `scp` / `rsync` over SSH, USB drive | No |
| AirDrop, browser download, Mail, Messages | **Yes** |
| Double-clicking a downloaded archive | **Yes** |

Nothing else travels with the app: `~/.config/mrtab/config.json` and `~/Library/Logs/MrTab.log` are
per-machine, and Accessibility has to be granted separately on each Mac.

## Diagnosing

MrTab logs to `~/Library/Logs/MrTab.log`. It records the trust state at launch, the result of hot
key registration, every time the shortcut fires, and how many windows each invocation found — which
is enough to tell "not trusted", "shortcut taken by another app" and "no windows" apart.

```sh
tail -f ~/Library/Logs/MrTab.log
```

Each line is tagged with its process id, which matters because **two copies of MrTab cannot
coexist**. A build in the repo and a copy in `/Applications` share a bundle identifier, so they
compete for the same Accessibility grant and the same hot key. The failure is quiet and misleading:
the older instance keeps the hot key, but granting access to the newer one revokes the older one's,
so the switcher still opens and lists almost nothing — and both processes write to one log, which
then reads as a single app contradicting itself.

MrTab terminates any earlier instance on launch, so the most recently opened copy wins. If you
suspect a leftover, `pgrep -xl MrTab` should print exactly one line.

## Layout

| File | Role |
| --- | --- |
| `AppDelegate.swift` | Wiring, menu bar item, launch behaviour, single-instance guard |
| `WindowStore.swift` | Background window tracking, AX observers, MRU ordering, snapshot publishing |
| `SwitcherController.swift` | Show / step / commit / cancel, modifier-release detection |
| `SwitcherPanel.swift` | The floating `NSPanel`, created once and pre-warmed |
| `SwitcherView.swift` | Hand-drawn header and row rendering |
| `HotKey.swift` | Carbon `RegisterEventHotKey` registration |
| `AXHelpers.swift` | Typed wrappers over the Accessibility C API |
| `Permissions.swift` | Accessibility trust checks and polling |
| `IconCache.swift` | Pre-scaled app icons by pid |
| `Config.swift` | JSON settings, loading and saving |
| `Shortcut.swift` | Modifier+key model, Carbon translation, key code names |
| `SettingsWindowController.swift` | Settings window and the permission banner |
| `ShortcutRecorderView.swift` | Click-then-press shortcut field |
| `LoginItem.swift` | Launch at login via `SMAppService` |
| `IconGenerator.swift` | Draws the app icon; `build.sh` pipes it through `iconutil` |
| `Log.swift` | Append-only log; an agent app has no console to fail loudly in |
| `SelfTest.swift` | `MRTAB_RENDER=x.png` renders the switcher and Settings offscreen |

### Checking the UI without running it

`MRTAB_RENDER=/tmp/shot.png build/MrTab.app/Contents/MacOS/MrTab` writes the switcher and the
settings pane to PNGs and exits. It needs no Accessibility and no Screen Recording, so it works in
any context, and it is how the layout gets checked.

The switcher is rendered over a stand-in for colourful wallpaper rather than a flat fill. A flat
backdrop flatters the design and hides the only contrast that matters — the panel is translucent,
so anything drawn at partial opacity competes with whatever is behind it. Row text is therefore
drawn at full strength, with the app name distinguished from the window title by *weight* rather
than opacity, over a scrim that keeps the base tone constant. The panel also pins itself to a dark
appearance rather than following the system theme — like the system Command-Tab switcher — so the
vibrancy material and the dynamic text colours can never disagree about which of them is dark.

## Known limitations

- No live window thumbnails. Icons and titles only — a deliberate choice, since thumbnails need
  Screen Recording permission and capture costs real time. `SwitcherView.Row` is the seam to add
  them behind.
- No type-to-filter.
- `⌘ Tab` cannot be replaced (see [Configuration](#configuration)).
- Windows on other Spaces are listed by default; switching to one moves you to that Space.
- Not notarised, so a downloaded copy needs `tar` or `xattr` as described above. Notarisation
  requires the paid Apple Developer Program; there is no free route to it.
