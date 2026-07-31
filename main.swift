import Cocoa
import UserNotifications
import FoundationModels

// ClaudeBar — menu bar agent that signals Claude Code activity by coloring,
// pulsing, and/or chiming its icon, and posting native notifications. Two alert
// states (done / needs-input) are each configurable in the Settings window. State
// is driven by hooks that write ~/.claude/claudebar.json. Runs as an .accessory
// app (menu bar only, no Dock).

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let stateURL = URL(fileURLWithPath:
        ("~/.claude/claudebar.json" as NSString).expandingTildeInPath)

    private var lastTs: Int = 0
    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var phase: Double = 0
    private lazy var whiteBurst: NSImage = makeWhiteBurst()

    private let headerItem = NSMenuItem(title: "Claude: idle", action: nil, keyEquivalent: "")
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = idleImage()

        let menu = NSMenu()
        menu.delegate = self
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear alert", action: #selector(clearAlert), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let test = NSMenuItem(title: "Test alert", action: nil, keyEquivalent: "")
        let testMenu = NSMenu()
        testMenu.addItem(NSMenuItem(title: "“finished” alert", action: #selector(testDone), keyEquivalent: ""))
        testMenu.addItem(NSMenuItem(title: "“needs input” alert", action: #selector(testNeedsInput), keyEquivalent: ""))
        test.submenu = testMenu
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeBar", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Seed lastTs from the current file so we don't fire on a stale event at launch.
        if let s = readState() { lastTs = s.ts }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private struct StateFile {
        let state: String; let session: String; let tty: String
        let summary: String; let text: String; let ts: Int
    }

    private func readState() -> StateFile? {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let st = obj["state"] as? String ?? ""
        let se = obj["session"] as? String ?? ""
        let tt = obj["tty"] as? String ?? ""
        let sm = obj["summary"] as? String ?? ""
        let tx = obj["text"] as? String ?? ""
        let ts = (obj["ts"] as? Int) ?? Int((obj["ts"] as? Double) ?? 0)
        return StateFile(state: st, session: se, tty: tt, summary: sm, text: tx, ts: ts)
    }

    private func poll() {
        guard let s = readState(), s.ts != lastTs else { return }
        lastTs = s.ts
        headerItem.title = "Claude (\(s.session)): \(s.state)"
        if let alert = AlertState.from(token: s.state) {
            applyAlert(alert, session: s.session, tty: s.tty, summary: s.summary, text: s.text)
        } else {
            stopAlert()   // "active" or anything else clears the alert
        }
    }

    private func applyAlert(_ state: AlertState, session: String, tty: String, summary: String, text: String) {
        // Icon = white burst on a colored badge (the alert color). Pulsing fades that
        // badge in and out. The badge is composited into the image because a status
        // item's own layer background doesn't render reliably.
        let color = Prefs.color(state)
        if Prefs.pulse(state) {
            startPulse(color)
        } else {
            stopPulse()
            statusItem.button?.image = alertBadge(color, alpha: 0.85)
        }

        let sound = Prefs.sound(state)
        if sound != "None" { NSSound(named: sound)?.play() }

        if Prefs.notify(state) {
            // Summarize the full message on-device (Apple Intelligence); fall back to the
            // heuristic summary if it's unavailable. Async so the menu bar updates instantly.
            Task { @MainActor in
                let body = await self.bestSummary(text: text, fallback: summary)
                self.postNotification(state, session: session, tty: tty, body: body)
            }
        }
    }

    private func bestSummary(text: String, fallback: String) async -> String {
        guard !text.isEmpty else { return fallback }
        if #available(macOS 26.0, *), let s = await summarizeOnDevice(text), !s.isEmpty {
            return s
        }
        return fallback
    }

    @available(macOS 26.0, *)
    private func summarizeOnDevice(_ text: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions:
                "You write a terse one-line macOS notification summary of what an AI coding "
                + "assistant just did. Max 14 words. State the action plainly. No quotes, no preamble.")
            let r = try await session.respond(to: "Summarize for a notification:\n\n\(text)")
            var s = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 150 { s = String(s.prefix(149)) + "…" }
            return s
        } catch {
            return nil
        }
    }

    // Idle: the Claude burst as a template — macOS renders it black on a light menu bar
    // and white on a dark one automatically.
    private func idleImage() -> NSImage {
        guard let img = NSImage(byReferencingFile: "/Users/moshe/Apps/ClaudeBar/claude_template.png"),
              img.isValid else { return fallbackImage() }
        img.size = NSSize(width: 22, height: 22)
        img.isTemplate = true
        return img
    }

    private func fallbackImage() -> NSImage {
        let f = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude")!
        f.isTemplate = true
        return f
    }

    // The burst recolored white, for drawing on top of a colored badge.
    private func makeWhiteBurst() -> NSImage {
        guard let base = NSImage(byReferencingFile: "/Users/moshe/Apps/ClaudeBar/claude_template.png")
        else { return fallbackImage() }
        let size = NSSize(width: 19, height: 19)
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        NSColor.white.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    // A colored rounded badge with the white burst centered. `alpha` drives the pulse.
    private func alertBadge(_ color: NSColor, alpha: CGFloat) -> NSImage {
        let size = NSSize(width: 38, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
        let radius = rect.height / 2   // full radius => pill shape
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let bw: CGFloat = 19
        whiteBurst.draw(in: NSRect(x: (size.width - bw) / 2, y: (size.height - bw) / 2, width: bw, height: bw))
        img.unlockFocus()
        img.isTemplate = false   // keep the colors
        return img
    }

    // Native banner via UNUserNotificationCenter. No actions => a plain auto-dismissing
    // banner (no "Show" button). Title is the summary of what Claude did; the tty rides
    // in userInfo so a click can focus the originating Terminal window.
    private func postNotification(_ state: AlertState, session: String, tty: String, body: String) {
        let content = UNMutableNotificationContent()
        let fallback = (state == .done) ? "finished a turn" : "needs your input"
        content.title = session                          // tab name
        content.body = body.isEmpty ? fallback : body    // AI summary of what Claude did
        content.userInfo = ["tty": tty, "session": session]
        // ONE group for everything (all notifications collapse together in Notification
        // Center), NOT a separate stack per tab.
        content.threadIdentifier = "ClaudeBar"
        // Break through Focus / Do Not Disturb when allowed.
        content.interruptionLevel = .timeSensitive

        // Unique id every time, so each "done" fires a fresh banner instead of silently
        // updating a previous one (which suppresses the alert).
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        // One-per-tab: remove any prior delivered notification from the SAME tab/session
        // (tracked via userInfo since threadIdentifier is now a shared group), then post
        // the fresh one. Other tabs keep their latest; this tab's older one is replaced.
        center.getDeliveredNotifications { delivered in
            let stale = delivered
                .filter { ($0.request.content.userInfo["session"] as? String) == session }
                .map { $0.request.identifier }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            center.add(req)
        }
    }

    private func focusTerminal(tty: String) {
        guard !tty.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["/Users/moshe/.claude/scripts/focus-terminal.sh", tty]
        try? p.run()
    }

    // Show the banner even though we're a background agent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // Clicking the banner focuses the originating Terminal window.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tty = response.notification.request.content.userInfo["tty"] as? String {
            focusTerminal(tty: tty)
        }
        completionHandler()
    }

    // Pulse the colored badge by fading it in and out (the white burst stays solid).
    private func startPulse(_ color: NSColor) {
        phase = 0
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.phase += 0.2
            let alpha = 0.35 + 0.55 * (0.5 + 0.5 * sin(self.phase))   // ~0.35…0.9
            self.statusItem.button?.image = self.alertBadge(color, alpha: alpha)
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate(); pulseTimer = nil
    }

    private func stopAlert() {
        stopPulse()
        statusItem.button?.alphaValue = 1.0
        statusItem.button?.image = idleImage()
    }

    @objc private func clearAlert()      { stopAlert() }
    @objc private func openSettings()    { settings.show() }
    @objc private func testDone()        { applyAlert(.done, session: "test", tty: "", summary: "Finished — test alert", text: "") }
    @objc private func testNeedsInput()  { applyAlert(.needsInput, session: "test", tty: "", summary: "Waiting for your input — test", text: "") }
    @objc private func quit()            { NSApp.terminate(nil) }

    // Opening the menu acknowledges the alert.
    func menuWillOpen(_ menu: NSMenu) { stopAlert() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
