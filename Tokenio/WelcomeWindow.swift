import AppKit

class WelcomeWindow {
    private var window: NSWindow?
    private var onLogin: (() -> Void)?

    init(onLogin: @escaping () -> Void) {
        self.onLogin = onLogin
    }

    func show() {
        let w: CGFloat = 320
        let h: CGFloat = 320

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
        let subtitle = NSTextField(labelWithString: "Track your Claude usage\nright from the menu bar.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subtitle)

        // Hint
        let hint = NSTextField(labelWithString: "Use \u{201c}Continue with email\u{201d} to log in.\nGoogle sign-in is not supported.")
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
            hint.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 16),
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

    func close() {
        window?.close()
        window = nil
    }
}
