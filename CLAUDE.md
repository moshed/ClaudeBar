# ClaudeBar

Menu bar agent (macOS) that signals Claude Code activity by coloring, pulsing,
chiming its icon, and posting native notifications. Two alert states, each fully
configurable in a Settings window.

Packaged as a **signed `.app` bundle** (`ClaudeBar.app`, LSUIElement → menu bar
only, no Dock icon), built with `swiftc` + a hand-written `Info.plist`, ad-hoc
codesigned. The bundle is required so `UNUserNotificationCenter` will deliver
banners under our own bundle id + icon. (No Xcode project — `build.sh` assembles
and signs the bundle.)

## Architecture

```
Claude Code hook ──> ~/.claude/scripts/claudebar-event.py <state>
                          │ writes atomically
                          ▼
                   ~/.claude/claudebar.json   {"state","session","cwd","ts"}
                          │ polled every 0.4s
                          ▼
                   ClaudeBar  ──> per-state color tint + pulse + sound
```

## States
- `done`        — Stop hook. Default: green, pulse, "Glass", notify.
- `needs-input` — Notification hook (Claude waiting on input/permission).
                  Default: orange, pulse, "Submarine", notify.
- `active`      — UserPromptSubmit hook. Not an alert; **clears** the current one.

All per-state look/feel (color, pulse on/off, sound, **notification** on/off) lives
in `UserDefaults`, edited via the Settings window. Defaults seeded by
`Prefs.registerDefaults()`.

## Menu bar icon
- **Idle:** `claude_template{,@2x,@3x}.png` (Claude.app's TrayIconTemplate burst) drawn
  as a **template** at 22pt (`idleImage()`) → macOS renders it black on a light menu bar,
  white on a dark one, automatically.
- **Alert:** a **pulsing pill badge** in the per-state color with a white burst on top
  (`alertBadge(color:alpha:)`): 38×22, `cornerRadius = height/2` (full pill), 19pt white
  burst (`whiteBurst`, the template recolored white via `sourceAtop`). The badge is
  **composited into the image** and swapped each pulse frame — `NSStatusBarButton`'s own
  `layer.backgroundColor` does NOT render reliably (AppKit draws over it), so don't try to
  color the button background directly. Pulse fades the badge alpha ~0.35→0.9.
- `claude_coral*.png` (coral recolor) is no longer used by the app — kept as an asset.
- Sizes are easy to tweak in `idleImage()` / `makeWhiteBurst()` / `alertBadge()`.

## Notifications
Native **`UNUserNotificationCenter`** (no terminal-notifier). The app requests
authorization at launch (one-time system prompt → must Allow; otherwise enable in
System Settings ▸ Notifications ▸ ClaudeBar).
- App + notification icon = `AppIcon.icns` (copied from Claude.app's electron.icns).
- **Title = tab/session name; body = summary** of what Claude did (see below).
- **No actions added → plain auto-dismissing banner** (no "Show" button).
- **Fires on every "done", no matter what:** each notification uses a **unique id**
  (`UUID`) so it always pops a fresh banner — a *fixed* id would make macOS silently
  update an existing, still-present notification and skip the alert.
- **One shared group, one-per-tab:** `threadIdentifier = "ClaudeBar"` (a constant) so
  ALL notifications collapse into a single group in Notification Center — not a separate
  stack per tab. The originating tab/session is carried in `userInfo["session"]`; before
  posting, `getDeliveredNotifications` removes prior delivered notifications whose
  `userInfo["session"]` matches, so a newer notification from a tab **replaces** that
  tab's older one while other tabs keep their latest. To have banners linger on-screen
  instead of auto-dismissing, set ClaudeBar to **Alerts** (not Banners) in System
  Settings ▸ Notifications ▸ ClaudeBar — that style is user-controlled, not settable by
  the app.
- **`interruptionLevel = .timeSensitive`** to break through Focus / Do Not Disturb
  (user may need to allow Time Sensitive for ClaudeBar in System Settings).
- Only the **Stop** hook posts notifications now — the Notification (needs-input) hook
  was removed because it double-alerted; "done" already means "waiting for you".
- **Click handler** (`didReceive`) reads `tty` from the notification's `userInfo` and
  runs `~/.claude/scripts/focus-terminal.sh <tty>`, which brings the originating
  Terminal.app window/tab to the front (matched by `tty of <tab>`; Apple Terminal
  only — iTerm/Ghostty would need their own matcher). `willPresent` returns `.banner`
  so it shows even though we're a background agent.
  - **`sleep 0.4` in focus-terminal.sh is load-bearing:** after a notification click
    macOS restores focus to whatever tab was front when you clicked, *after* the click
    handler runs. Without the delay the target tab flashes then reverts; the delay lets
    the restore finish, then we steal focus and it sticks.
  - Requires ClaudeBar to have Automation control of Terminal (System Settings ▸
    Privacy & Security ▸ Automation) — granted on first click. Debug log:
    `~/.claude/claudebar-focus.log` (each click logs tty + matched/no-match).

### Title summary + tty capture (the hooks)
`claudebar-event.py <state> [tty]`:
- tty comes from the hook command as `$(ps -o tty= -p $$ | tr -d ' ')`, normalized to
  `/dev/ttysNNN`.
- summary: for `done`, the first line of Claude's last assistant message in
  `transcript_path`; for `needs-input`, the Notification hook's own `message`.
Both are written into claudebar.json for the app to read.

## Files
- **`Prefs.swift`** — `AlertState` enum + `Prefs` (UserDefaults-backed color/pulse/sound,
  with `registerDefaults()`). Color stored as `[r,g,b,a]` doubles in sRGB.
- **`Settings.swift`** — `SettingsWindowController`: programmatic AppKit window
  (NSStackView), one section per state with an `NSColorWell`, a "Pulse" checkbox,
  and a sound `NSPopUpButton` (previews the sound on selection). No storyboard.
- **`main.swift`** — `AppDelegate`: status item (Claude burst template via
  `menuBarImage()`), 0.4s poll of the state file, `applyAlert(_:session:)` /
  `stopAlert()`, pulse via a 0.05s sine-driven `alphaValue` timer,
  `postNotification(_:session:)` (terminal-notifier). Menu: header, Clear alert,
  Settings…, Test alert (submenu per state), Quit.
- **`build.sh`** — `xcrun swiftc -O Prefs.swift Settings.swift main.swift -o ClaudeBar`
  (must list all three files).

## State file (`~/.claude/claudebar.json`)
`{"state": "done"|"needs-input"|"active", "session": "<name>", "cwd": "<dir>", "ts": <epoch ms>}`
App seeds `lastTs` from this at launch so it never fires on a stale event. Single
**global** indicator — last event across all sessions/terminals wins.

## Hooks (in `~/.claude/settings.json`)
- `Stop`             → `claudebar-event.py done`
- `Notification`     → `claudebar-event.py needs-input`
- `UserPromptSubmit` → `claudebar-event.py active`

`session` name resolved from `~/.claude/sessions/<pid>.json` (by `sessionId`),
falling back to the cwd basename.

## Run / manage
- LaunchAgent: `~/Library/LaunchAgents/com.dnz.claudebar.plist` (RunAtLoad + KeepAlive →
  starts at login). Runs `ClaudeBar.app/Contents/MacOS/ClaudeBar`.
- Start:    `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dnz.claudebar.plist`
- Stop:     `launchctl bootout gui/$(id -u)/com.dnz.claudebar`  (or "Quit ClaudeBar")
- Rebuild:  `./build.sh` (assembles + ad-hoc signs the bundle), then
  `launchctl kickstart -k gui/$(id -u)/com.dnz.claudebar`. After the first build,
  `open ./ClaudeBar.app` once so LaunchServices registers the bundle id/icon.
- Tweak look/feel: ClaudeBar menu → **Settings…**. **Test alert** submenu previews each state.

## Related (same session-name plumbing)
- `~/.claude/scripts/set-terminal-title.sh` + `cc-title-watcher.py` — syncs the
  **terminal window title** to the session name live. SessionStart hook launches the
  watcher with just the session id. The watcher finds the session's `claude` pid (via
  `~/.claude/sessions/<pid>.json`) and derives **that pid's** controlling tty with
  `ps` — NOT the hook shell's tty (the hook shell has none, which silently broke an
  earlier version). Writes `\033]0;<name>\007` to that tty every ~1.5s; exits when the
  claude process dies. Per-session (one watcher each), not a login item — unlike
  ClaudeBar.app which is a login LaunchAgent.

## Ideas / not done
- Per-session icons / a list of active sessions in the menu.
- A master enable/disable toggle in Settings.
- More granular `Notification` filtering (it currently fires for any Claude notification).
