# ClaudeBar

Menu bar agent (macOS) that signals Claude Code activity by coloring, pulsing,
chiming its icon, and posting native notifications. Two alert states, each fully
configurable in a Settings window.

Packaged as a **signed `.app` bundle** (`ClaudeBar.app`, LSUIElement → menu bar
only, no Dock icon), built with `swiftc` + a hand-written `Info.plist`, signed with
the "Apple Development: Moshe Dancykier (49U8YN8HSJ)" identity (was ad-hoc until
2026-09-10 — see Signing below). The bundle is required so `UNUserNotificationCenter` will deliver
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

## Menu bar icon (`Icons.swift`, three styles — Settings ▸ "Menu bar icon")
`Prefs.iconStyle` (`IconStyle`: `badge` / `tint` / `mascot`, default `badge`). A change posts
`.claudeBarIconStyle`; `AppDelegate.redrawIcon()` redraws at once, alert or idle.
- **badge** (original): pill in the alert color, white burst on top, 38×22. The pill is
  **composited into the image** — `NSStatusBarButton`'s `layer.backgroundColor` does NOT
  render reliably. Pulse fades the pill alpha ~0.35→0.9.
- **tint**: no pill. The burst itself takes the alert color; pulse fades the WHOLE image
  (`draw(fraction:)`). Fading the color instead comes out dark over the black template.
- **mascot**: the Claude Code mascot, drawn from a pixel grid copied from the CLI welcome
  art (` ▐▛███▜▌ / ▝▜█████▛▘ / ▘▘ ▝▝ `), one cell per quarter character, 1.25×2.5 pt
  cells (terminal pixels are twice as tall as wide). Pulse = 4-frame loop, a new pose
  every ~0.36 s: stand, arms up + hop, stand, arms up + hop with the other step.
- Idle is a **template** in every style (black on a light menu bar, white on a dark one).
- Preview all styles without a restart: compile `Prefs.swift Icons.swift` with a small
  `main.swift` that draws `Icons.idle/alert` into a PNG.

## Plan usage in the menu (`Usage.swift`)
Session (5-hour) and weekly usage, with bars and reset times, at the top of the menu.
- `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`
  and `anthropic-beta: oauth-2025-04-20`. Use the `limits[]` array (`session`, `weekly_all`,
  `weekly_scoped` shown only when > 0); falls back to `five_hour` / `seven_day`.
- Token = Claude Code's own OAuth token, keychain item `Claude Code-credentials`,
  **account = the Mac user name** (`moshe`). An older item with account `unknown` has an
  EMPTY token — read the wrong one and you get "x-api-key header is required".
  Read through `/usr/bin/security` (no keychain dialog). Never refresh the token;
  Claude Code does that. 401 → menu says "sign-in expired".
- **Extra usage** (pay-as-you-go after the plan runs out) = `extra_usage`, shown only when
  `is_enabled`. Amounts are minor units (`decimal_places` 2): `used_credits` 3794 /
  `monthly_limit` 6000 = $37.94 / $60.00. No reset time in the response, so the caption
  says "This month" (or "Monthly limit reached" on `spend_limit_reached`).
- Fetched at launch, every 5 min, and on menu open (if older than 30 s).
- Bars are drawn Capsules, not `ProgressView`: a ProgressView in a menu turns gray
  because the menu window is never key. Blue < 75%, orange ≥ 75%, red ≥ 90%.

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
- **`Switcher.swift`** — the ⌃⌥Tab tab switcher (see below): `TabTracker` (recency
  store), `ClaudeTabs` (live sessions → ttys), `Transcript` (last typed prompt),
  `GlobalHotKeys` (Carbon), `SwitcherPanel` + SwiftUI `SwitcherView`, `SwitcherController`.
- **`Icons.swift`** — all menu bar icon art (badge / tint / mascot), see above.
- **`Usage.swift`** — `UsageModel` (fetch + parse) and the SwiftUI `UsageMenuView`.
- **`build.sh`** — `xcrun swiftc -O Prefs.swift Icons.swift Usage.swift Settings.swift
  Switcher.swift main.swift` (must list all six files), then `codesign` with the Apple Development identity.

## Tab switcher (⌃⌥Tab)
All Claude sessions live as tabs of ONE Terminal window (global `AppleWindowTabbingMode
= always`). **⌃⌥Tab** opens a Spotlight-style panel listing every live Claude tab,
most recently used first. **⌃⌥Tab again / Tab / ↓** = next, **⇧Tab / ↑ / ⌃⌥⇧Tab** = back,
**Return** or click = jump to that tab, **Esc** or click outside = close, **typing**
filters (name prefix first, then contains). Like ⌘Tab it opens on the tab BEFORE the
current one. Menu item "Switch Claude tab…" does the same.

- **Why a switcher, not a real re-sort:** Terminal cannot move a tab to a position by
  script or menu. The only trick is "Move Tab to New Window" + "Merge All Windows" for
  every tab, which flashes all ~20 tabs. Moshe chose the switcher (2026-09-10).
- **Rows** come from `~/.claude/sessions/*.json` (live pid, `kind` interactive), tty via
  one `ps -o pid=,tty= -p …` call, one row per tty (newest `updatedAt` wins).
  Name = session `name`, else cwd basename. Spinner = session `status == "busy"`.
  Green dot = `status == "idle"` and `statusUpdatedAt` is newer than the last time the
  tab was in front (Claude finished, you have not looked). Session `status` is only
  ever `busy` / `idle` — there is no "needs permission" value.
- **"Used"** = max(last time the tab was frontmost, last prompt sent in it).
  Frontmost: a 1 s timer runs `tty of selected tab of front window` via NSAppleScript,
  ONLY while Terminal is the frontmost app. Prompt: the `active` event in
  `claudebar.json` (UserPromptSubmit carries the tty), so phone / Remote Control
  prompts count too. First sight of a tab with no record: seeded from the last typed
  prompt in its transcript (`~/.claude/projects/*/<sessionId>.jsonl`, tail 2 MB,
  skips tool results and `<…>` system text).
- Store: `~/.claude/claudebar-mru.json` `{since, focus{tty:t}, prompt{tty:t}}`. Keyed by
  tty, because a /rename changes the name and a resume changes the pid but not the tab.
  `since` = first launch; nothing older shows as unseen, so no green flood on day one.
- **Panel:** borderless `.nonactivatingPanel` with `canBecomeKey = true`, level
  `.popUpMenu`, `.canJoinAllSpaces + .fullScreenAuxiliary`. It takes the keyboard
  WITHOUT activating ClaudeBar, so Esc leaves Terminal exactly as it was. Keys come
  through a local `NSEvent` monitor. The panel height is computed from the row count
  (`Layout`), not from `fittingSize`, which lags a SwiftUI state change.
- **All AppleScript runs on one serial queue** (`Terminal.queue`) — NSAppleScript is not
  thread-safe. `inFlight` stops polls piling up if one blocks (e.g. on a TCC prompt).
- Hotkey = Carbon `RegisterEventHotKey` → no Accessibility permission needed. ⌃⌥Tab
  was free: Leap owns ⌘Tab, Window Manager uses ⌃⌥⌘ + arrows/letters.
- **Test it for real** by driving the hotkey: `osascript -e 'tell application "System
  Events" to key code 48 using {control down, option down}'`, find the 460-pt-wide
  ClaudeBar window with `CGWindowListCopyWindowInfo`, `screencapture -l <id>`.
  **Abort if the panel is not there before sending more keys** — otherwise the keys
  land in whatever app is in front (happened once, 2026-09-10).

## Resumed sessions lose their name — fall back to the transcript
`claude --continue` / `--resume` does NOT restore the name `/rename` gave the session. The
record comes back as `nameSource: "derived"` with a throwaway name (`moshe-d3`). The real
name is still in the transcript, as the last `"customTitle"` entry, so all three readers
prefer it when the live session was not renamed again:
- `cc-title-watcher.py` → `display_name()` / `transcript_title()` (30 s cache)
- `claudebar-event.py` → `transcript_title()` (notification titles)
- `Switcher.swift` → `Transcript.customTitle()` (switcher rows)
Order everywhere: a name set in THIS session (`nameSource == "custom"`) wins, then the
stored `customTitle`, then the derived name. Verified 2026-09-16: a resumed Sports Alerts
session reported `moshe-d3` and the tab still read "Sports Alerts".

## Signing
`build.sh` signs with the first **Apple Development** identity in the keychain, not
ad-hoc. It no longer names one: the original cert left the keychain on 2026-10-15, and
an API-made replacement carries the App Store Connect key id in its name, which does not
belong in a public repo. A change of identity means macOS asks once more for
"ClaudeBar may control Terminal".
An ad-hoc signature is a new cdhash every build, so macOS forgets the "ClaudeBar may
control Terminal" (Automation) grant and asks again after every rebuild. A real
identity keeps the grant. No hardened runtime (it would need the Apple Events
entitlement).
- **Gotcha seen on the switch:** the FIRST launch after changing the identity was
  SIGKILLed — `Launch Constraint Violation` / `OS_REASON_CODESIGNING` (the LaunchAgent is
  BTM-managed with a launch constraint for the old signature). KeepAlive respawned it
  ~10 s later and it ran fine. If it ever stays dead: `launchctl print
  gui/$(id -u)/com.dnz.claudebar` and `~/Library/Logs/DiagnosticReports/ClaudeBar-*.ips`.

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

## Run / manage — a normal app in /Applications (since 2026-09-16)
`./build.sh` builds, signs and **installs to `/Applications/ClaudeBar.app`**
(`./build.sh --no-install` to skip). Launch it like any app: double-click it in
/Applications, or `open /Applications/ClaudeBar.app`.

- **Start at login = a real Login Item** (`SMAppService.mainApp`), registered by the app
  itself on first launch and toggled from the menu ("Start at Login"). It shows up in
  System Settings ▸ General ▸ Login Items.
- The old **LaunchAgent is retired** (`~/Library/LaunchAgents/com.dnz.claudebar.plist.retired`).
  Do not bring it back: it fought the Login Item and pointed at the source folder.
- **One instance only.** `applicationDidFinishLaunching` quits the new copy if another
  process with the same bundle id is already running, so opening it from /Applications
  while it runs cannot give two menu bar icons.
- Icons load from **the bundle** (`Bundle.main.url(forResource: "claude_template")`), not
  from the source folder — that hard-coded path broke the moment the app moved.
- Redeploy: `./build.sh && pkill -f 'ClaudeBar.app/Contents/MacOS/ClaudeBar' && open /Applications/ClaudeBar.app`.
- **`-target arm64-apple-macos26.0` in build.sh is load-bearing.** On macOS 27 plain
  `swiftc` stamps `minos 28.0` and LaunchServices refuses to open the app (-10825, no
  crash report). 26.0 = where FoundationModels starts. `build.sh` prints `minos` each build.
- Tweak look/feel: ClaudeBar menu → **Settings…**. **Test alert** submenu previews each state.

## The switcher needs REAL sessions (child sessions are invisible)
Rows come from `~/.claude/sessions/<pid>.json`, and Claude Code writes that file **only for
a top-level session**. A session that inherits `CLAUDE_CODE_CHILD_SESSION=1` writes no file,
joins no peer list, and its tab title never follows the session name. Moshe's Terminal was
launched from inside a Claude session once, so every tab inherited the marker and the
switcher went empty. Fix (2026-09-16): a `claude()` function in `~/.zshrc` starts Claude with
a scrubbed environment when the marker is stale. Unsetting the variables is NOT enough —
Claude also reads the parent process environment. See the memory `claude_child_session_marker`.

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
- Per-session icons in the menu bar (the ⌃⌥Tab switcher already lists sessions).
- Settable switcher hotkey (fixed at ⌃⌥Tab today).
- A master enable/disable toggle in Settings.
- More granular `Notification` filtering (it currently fires for any Claude notification).
