# WorkSwitch

One shortcut to everything you're working on, automatically ranked by how you actually work.

**Status: Milestone 2 — Chrome tabs.** Native macOS windows and Chrome tabs appear in one
ranked list.

## Quick start

```bash
make setup        # build + install app, build extension, install host manifest
make run          # launch
```

Then follow [Chrome setup](#chrome-setup) below, grant Accessibility permission when
prompted, and press **Ctrl-Space**.

| Command | What it does |
| --- | --- |
| `make build` | Compile the binaries only |
| `make app` | Build `build/WorkSwitch.app` |
| `make install` | Install to `~/Applications/WorkSwitch.app` |
| `make run` | Build, install, relaunch |
| `make setup` | Everything needed for a first run, app + extension + host manifest |
| `make extension` | Compile the extension's TypeScript |
| `make host-manifest` | Install the Chrome native messaging host manifest |
| `make dump` | Print enumerated native windows as JSON and exit |
| `make test` | Run the ranking and merge checks |
| `make bridge-status` | Show whether the bridge socket and connection are live |
| `make signing-identity` | Create the stable signing identity (once) |
| `make doctor` | Report signing identity, copies on disk, and trust state |
| `make reset-perms` | Clear a stale Accessibility grant |

## Keyboard

| Key | Action |
| --- | --- |
| `Ctrl-Space` | Open / close the switcher |
| Type | Filter by window title and app name |
| `↑` `↓` / `Tab` / `Ctrl-N` `Ctrl-P` | Move selection |
| `Cmd-↑` `Cmd-↓` | Jump to first / last |
| `Return` | Activate the selected window |
| `Esc` | Close and return to where you were |

## Chrome setup

Run `make setup` first, then:

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. Click **Load unpacked** and choose the `chrome-extension` folder in this repo
4. **Restart Chrome** so it picks up the native messaging host manifest

### Verifying the connection

Any of these confirms the bridge is live:

- **Menu bar** → the WorkSwitch icon shows *Chrome Extension: Connected (1 profile, N tabs)*
- **Terminal** → `make bridge-status`
- **Chrome** → `chrome://extensions` → WorkSwitch Tab Bridge → **Service worker** → the
  console logs `[WorkSwitch] Connected to native host` and `Sent inventory: N tabs`
- **Switcher** → press Ctrl-Space; tabs appear with a `Tab` badge and their domain

### How the connection works

Chrome launches a native messaging host as its own child process and talks to it over
stdin/stdout. WorkSwitch is a long-running menu-bar app that Chrome does not own, so it
cannot be that host itself. Instead:

```
Chrome extension  ──stdio──▶  workswitch-bridge  ──unix socket──▶  WorkSwitch.app
   (service worker)             (relay, in the bundle)              (menu bar app)
```

`workswitch-bridge` is a dumb byte pump. Native messaging framing (4-byte little-endian
length + JSON) is used on the socket too, so frames pass through untouched and all protocol
logic lives in the app.

The extension ID is pinned by a public key in `manifest.json`, generated once by
`scripts/gen_extension_key.sh`. Without that, an unpacked extension's ID depends on its
folder path and could not be named in the host manifest ahead of time.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| Menu bar says *Not Connected* | Chrome not restarted after `make host-manifest`, or the extension is not loaded |
| `Specified native messaging host not found` in the extension console | Host manifest missing — run `make host-manifest` |
| `Access to the specified native messaging host is forbidden` | Extension ID does not match `allowed_origins`; re-run `make host-manifest` |
| Tabs vanish but windows remain | The app was restarted; the extension reconnects within ~30s |
| Chrome windows appear twice | Extension disconnected mid-session, so native Chrome windows came back |

### Multiple Chrome profiles

Chrome launches a separate host process per profile, so each connects independently. Tab and
window IDs are only unique *within* a profile, so every connection gets its own namespace —
without that, tab 5 in two profiles would collide. Profile labels appear only when more than
one profile is connected. The extension is not granted a permission that would expose the
profile's display name, so labels are positional ("Profile 1", "Profile 2").

## Why Accessibility permission is required

Two reasons, both load-bearing:

1. **It is the only source of window titles.** On current macOS, `kCGWindowName` from
   CoreGraphics is gated behind Screen Recording and returns `nil` for essentially every
   window — measured on this machine as 1 title across 18 windows, and that one was the
   system menubar. A CoreGraphics-based switcher would show an untitled list.
2. **It is the only way to focus a specific window.** `AXUIElementPerformAction` with
   `kAXRaiseAction` targets one exact window; nothing else does.

CoreGraphics is still used, but only for on-screen state and front-to-back ordering. It also
over-reports: one Chrome window appears there as four separate compositing surfaces, while
Accessibility reports the single logical window.

WorkSwitch requests **no** Screen Recording permission and takes no screenshots.

Chrome tabs arrive over the extension bridge and need no Accessibility permission at all, so
they remain usable while that grant is still pending.

## Privacy

WorkSwitch indexes **where** you work, not **what** you write. It reads app names, window
titles, tab titles, URLs, and activation timestamps. It does not read window contents, page
contents, keystrokes, documents, or messages. Nothing leaves the device — Milestones 1 and 2
keep history in memory only, and Milestone 3 adds a local SQLite database.

The Chrome extension requests only `tabs` (metadata), `nativeMessaging` (to reach the app),
and `alarms` (to revive its service worker). It declares **no host permissions**, has **no
content scripts**, and cannot read page contents. Incognito tabs are filtered out explicitly
in `toPayload()` rather than relying on Chrome's default of withholding incognito access.

## Development notes

### No Xcode required

The project builds with Swift Package Manager against the Command Line Tools SDK.
`scripts/build_app.sh` assembles the `.app` bundle and ad-hoc signs it, replacing what
`xcodebuild` would otherwise do.

### Keeping the Accessibility grant stable across rebuilds

macOS ties a TCC grant to the app's **designated requirement**. With an ad-hoc signature that
requirement is literally the binary's cdhash:

```
designated => cdhash H"12d7c965a6190b959ddbabab5521e86a51295b60"
```

So every rebuild invalidates the grant. The symptom is confusing: System Settings still shows
WorkSwitch enabled, but `AXIsProcessTrusted()` returns false and the app asks for permission
it appears to already have.

The fix is a stable signing identity. `make signing-identity` creates a self-signed
code-signing certificate once, after which the requirement becomes:

```
designated => identifier "com.lorenzospellman.workswitch"
              and certificate leaf = H"a7f6686d..."
```

That depends on the certificate, not the binary, so it survives rebuilds. Normally this would
be an Apple Development certificate from Xcode; Xcode is not installed here, and a self-signed
certificate produces an equally stable requirement, trusted only on this machine.

`make install` warns loudly if it has to fall back to ad-hoc signing.

### Diagnosing permission problems

```bash
make doctor
```

Reports the signing identity, every copy of the app on disk with its identifier / signature /
cdhash / designated requirement, and what the app itself logged on its last launch.

The app writes its identity to `~/Library/Application Support/WorkSwitch/startup.log` on every
launch. Read the trust state from there, **not** by running the binary from a terminal: TCC
attributes a child process to whatever launched it, so a terminal run reports the *terminal's*
Accessibility grant, not the app's.

### Only ever run one copy

Different copies are different TCC identities, so launching the wrong one looks exactly like a
revoked permission.

- `~/Applications/WorkSwitch.app` is the canonical install. `make install` removes its own
  staging copy so a second bundle cannot linger.
- `.build/release/WorkSwitch` has a *different* signing identifier (`WorkSwitch`, not the
  bundle ID), so it is a separate TCC identity. Use it only for `--self-test`, `--diagnose`,
  and `--dump-destinations`.
- The app logs a warning at startup if it is running from a non-canonical path.

### If permission looks enabled but isn't active

```bash
tccutil reset Accessibility com.lorenzospellman.workswitch
make install && open ~/Applications/WorkSwitch.app
```

Then re-enable WorkSwitch in System Settings → Privacy & Security → Accessibility. The app
detects this state itself and shows the same instructions in its onboarding screen.

## Layout

```
Sources/
├── BridgeShared/                  Socket path + framing constants (app and relay)
├── WorkSwitchBridge/              Native messaging relay Chrome launches
└── WorkSwitch/
    ├── Model/Destination.swift    Normalized cross-app destination model
    ├── Sources/                   Enumeration + native/tab merging
    ├── Bridge/                    Socket server, protocol, tab store, coordinator
    ├── Activation/                Window focusing
    ├── Ranking/                   Fuzzy matching + ordering
    ├── UI/                        Panel, SwiftUI overlay, keyboard handling
    ├── Hotkey/                    Carbon global hot key
    ├── Permissions/               Accessibility trust + onboarding
    └── SelfTest.swift             Ranking and merge checks (--self-test)

chrome-extension/                  MV3 + TypeScript extension
Store/                             SQLite persistence (Milestone 3)
```

## Roadmap

- [x] **M1** Native windows, global shortcut, search, activation
- [x] **M2** Chrome extension + native messaging; tabs in the same list
- [ ] **M3** SQLite activation history; recency/frequency ranking
- [ ] **M4** Transition and co-usage scoring
- [ ] **M5** Automatic context detection
