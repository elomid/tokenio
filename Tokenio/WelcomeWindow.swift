import AppKit

class WelcomeWindow {
    private var window: NSWindow?
    private var onLogin: (() -> Void)?
    private var onCodex: (() -> Void)?

    init(onLogin: @escaping () -> Void, onCodex: @escaping () -> Void) {
        self.onCodex = onCodex
        self.onLogin = onLogin
    }

    func show() {
        let w: CGFloat = 320
        let h: CGFloat = 410

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // App icon
        let icon = NSImageView(frame: .zero)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)

        // Title
        let title = NSTextField(labelWithString: "Tokenio")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Track Claude, Codex, or both\nright from the menu bar.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subtitle)

        // Hint
        let hint = NSTextField(labelWithString: "Choose either provider to start.\nChange this anytime in Providers.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        // Login button
        let button = NSButton(title: "Log in to Claude", target: self, action: #selector(loginClicked))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)

        let codexButton = NSButton(title: "Use Codex", target: self, action: #selector(codexClicked))
        codexButton.bezelStyle = .rounded
        codexButton.controlSize = .large
        codexButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(codexButton)
        let codexHint = NSTextField(labelWithString: "Uses your existing Codex CLI login.")
        codexHint.font = .systemFont(ofSize: 11)
        codexHint.textColor = .secondaryLabelColor
        codexHint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(codexHint)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),

            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),

            subtitle.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

            button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            button.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            button.widthAnchor.constraint(equalToConstant: 180),

            hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            codexButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            codexButton.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            codexButton.widthAnchor.constraint(equalToConstant: 180),
            codexHint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            codexHint.topAnchor.constraint(equalTo: codexButton.bottomAnchor, constant: 6),
            hint.topAnchor.constraint(equalTo: codexHint.bottomAnchor, constant: 20),
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentView = content
        win.center()
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        self.window = win

        win.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func loginClicked() {
        close()
        onLogin?()
    }

    @objc private func codexClicked() {
        close()
        onCodex?()
    }

    func close() {
        window?.close()
        window = nil
    }
}
