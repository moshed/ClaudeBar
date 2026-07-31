import Cocoa

// Alert states ClaudeBar can signal. `active` (a new prompt) is not an alert —
// it just clears whatever alert was showing.
enum AlertState: String, CaseIterable {
    case done
    case needsInput

    // Section title in the settings window.
    var title: String {
        switch self {
        case .done:       return "When Claude finishes a turn"
        case .needsInput: return "When Claude needs your input"
        }
    }

    // Token written to claudebar.json by the hooks.
    var token: String {
        switch self {
        case .done:       return "done"
        case .needsInput: return "needs-input"
        }
    }

    static func from(token: String) -> AlertState? {
        AlertState.allCases.first { $0.token == token }
    }

    var key: String { rawValue }
}

// UserDefaults-backed per-state preferences: icon color, pulse on/off, sound.
enum Prefs {
    static let defaults = UserDefaults.standard

    // "None" + a selection of built-in macOS system sounds.
    static let soundNames = ["None", "Glass", "Ping", "Pop", "Hero", "Submarine",
                             "Funk", "Blow", "Bottle", "Frog", "Morse", "Purr",
                             "Sosumi", "Tink", "Basso"]

    static func registerDefaults() {
        defaults.register(defaults: [
            "done.color":       [0.20, 0.78, 0.35, 1.0],   // green
            "done.pulse":       true,
            "done.sound":       "Glass",
            "done.notify":      true,
            "needsInput.color": [1.0, 0.58, 0.0, 1.0],     // orange
            "needsInput.pulse": true,
            "needsInput.sound": "Submarine",
            "needsInput.notify": true,
        ])
    }

    static func color(_ s: AlertState) -> NSColor {
        let c = defaults.array(forKey: "\(s.key).color") as? [Double] ?? [0, 0, 0, 1]
        let a = c.count > 3 ? c[3] : 1
        return NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: CGFloat(a))
    }

    static func setColor(_ s: AlertState, _ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        defaults.set([Double(c.redComponent), Double(c.greenComponent),
                      Double(c.blueComponent), Double(c.alphaComponent)],
                     forKey: "\(s.key).color")
    }

    static func pulse(_ s: AlertState) -> Bool { defaults.bool(forKey: "\(s.key).pulse") }
    static func setPulse(_ s: AlertState, _ v: Bool) { defaults.set(v, forKey: "\(s.key).pulse") }

    static func sound(_ s: AlertState) -> String { defaults.string(forKey: "\(s.key).sound") ?? "None" }
    static func setSound(_ s: AlertState, _ v: String) { defaults.set(v, forKey: "\(s.key).sound") }

    static func notify(_ s: AlertState) -> Bool { defaults.bool(forKey: "\(s.key).notify") }
    static func setNotify(_ s: AlertState, _ v: Bool) { defaults.set(v, forKey: "\(s.key).notify") }
}
