import Cocoa

// Programmatic settings window (no storyboard — keeps ClaudeBar a single-binary,
// no-Xcode build). One section per AlertState: color well, pulse toggle, sound.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var colorWells: [AlertState: NSColorWell] = [:]
    private var pulseChecks: [AlertState: NSButton] = [:]
    private var soundPops:   [AlertState: NSPopUpButton] = [:]
    private var notifyChecks: [AlertState: NSButton] = [:]

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, state) in AlertState.allCases.enumerated() {
            stack.addArrangedSubview(section(for: state))
            if i < AlertState.allCases.count - 1 {
                let line = NSBox(); line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 320).isActive = true
                stack.addArrangedSubview(line)
            }
        }

        let note = NSTextField(wrappingLabelWithString:
            "A new prompt (or clicking the icon) clears the alert. Sound previews when you pick one.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        stack.addArrangedSubview(note)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "ClaudeBar Settings"
        win.isReleasedWhenClosed = false
        win.contentView = container
        container.layoutSubtreeIfNeeded()
        win.setContentSize(stack.fittingSize)
        window = win
    }

    private func section(for state: AlertState) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8

        let title = NSTextField(labelWithString: state.title)
        title.font = NSFont.boldSystemFont(ofSize: 13)
        box.addArrangedSubview(title)

        let well = NSColorWell()
        well.color = Prefs.color(state)
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWells[state] = well
        box.addArrangedSubview(row("Icon color:", well))

        let pulse = NSButton(checkboxWithTitle: "Pulse the icon",
                             target: self, action: #selector(pulseChanged(_:)))
        pulse.state = Prefs.pulse(state) ? .on : .off
        pulseChecks[state] = pulse
        box.addArrangedSubview(pulse)

        let notify = NSButton(checkboxWithTitle: "Send a notification",
                              target: self, action: #selector(notifyChanged(_:)))
        notify.state = Prefs.notify(state) ? .on : .off
        notifyChecks[state] = notify
        box.addArrangedSubview(notify)

        let pop = NSPopUpButton()
        pop.addItems(withTitles: Prefs.soundNames)
        pop.selectItem(withTitle: Prefs.sound(state))
        pop.target = self
        pop.action = #selector(soundChanged(_:))
        soundPops[state] = pop
        box.addArrangedSubview(row("Sound:", pop))

        return box
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let r = NSStackView(views: [NSTextField(labelWithString: label), control])
        r.orientation = .horizontal
        r.spacing = 8
        return r
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        for (state, well) in colorWells where well === sender { Prefs.setColor(state, sender.color) }
    }

    @objc private func pulseChanged(_ sender: NSButton) {
        for (state, b) in pulseChecks where b === sender { Prefs.setPulse(state, sender.state == .on) }
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        for (state, p) in soundPops where p === sender {
            let name = sender.titleOfSelectedItem ?? "None"
            Prefs.setSound(state, name)
            if name != "None" { NSSound(named: name)?.play() }
        }
    }

    @objc private func notifyChanged(_ sender: NSButton) {
        for (state, b) in notifyChecks where b === sender { Prefs.setNotify(state, sender.state == .on) }
    }
}
