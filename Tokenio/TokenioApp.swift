import AppKit
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var sessionView: MetricMenuView!
    private var weeklyView: MetricMenuView!
    private var sonnetView: MetricMenuView!
    private var extraView: MetricMenuView!
    private var updatedItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var logoutItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var fetchTimer: Timer?
    private var uiTimer: Timer?
    private var lastFetched: TimeInterval = 0
    private var loading = false
    private var authFailed = false
    private var loginWindow: LoginWindow?
    private var welcomeWindow: WelcomeWindow?

    // Last known icon values for redraw on appearance change
    private var lastSU: Double = 0, lastST: Double = 0
    private var lastWU: Double = 0, lastWT: Double = 0

    private let refreshInterval: TimeInterval = 300 // 5 min

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Enable launch at login on first run
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            if LaunchAtLogin.isEnabled || LaunchAtLogin.enable() {
                UserDefaults.standard.set(true, forKey: "hasLaunched")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        if loadSession() != nil {
            // Logged in — show snapshot immediately if available, then refresh
            if let (snapshot, ts) = loadSnapshot() {
                applySnapshot(snapshot)
                lastFetched = ts
                updatedItem.title = "Updated \(fmtAgo(ts))  \u{21bb}"
            } else {
                applyIcon(makeIcon(sUsage: 0, sTime: 0, wUsage: 0, wTime: 0, isDark: isDarkMenuBar))
            }
            triggerFetch(isBackground: true)
        } else {
            // Not logged in — warning icon, show stale data if any
            applyIcon(makeDisconnectedIcon())
            if let (snapshot, ts) = loadSnapshot() {
                applySnapshot(snapshot, iconOverride: false)
                lastFetched = ts
                updatedItem.title = "Not logged in  \u{26a0}"
            } else {
                updatedItem.title = "Not logged in  \u{26a0}"
            }
            authFailed = true
            updateAuthVisibility()
            // Show welcome window on first launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showWelcome()
            }
        }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.triggerFetch(isBackground: true)
        }
        RunLoop.main.add(fetchTimer!, forMode: .common)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateRelativeTime()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wakeRefresh),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addMetric(_ view: MetricMenuView) {
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }

        sessionView = MetricMenuView(title: "Current session")
        weeklyView = MetricMenuView(title: "Weekly - All models")
        sonnetView = MetricMenuView(title: "Weekly - Sonnet only")
        extraView = MetricMenuView(title: "Extra usage")

        addMetric(sessionView)
        addMetric(weeklyView)
        addMetric(sonnetView)
        addMetric(extraView)

        updatedItem = NSMenuItem(title: "Refreshing\u{2026}  \u{21bb}", action: #selector(refreshClicked), keyEquivalent: "")
        updatedItem.target = self
        menu.addItem(updatedItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Log in to Claude\u{2026}", action: #selector(loginClicked), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        logoutItem = NSMenuItem(title: "Log out", action: #selector(logoutClicked), keyEquivalent: "")
        logoutItem.target = self
        menu.addItem(logoutItem)

        updateAuthVisibility()

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let aboutItem = NSMenuItem(title: "About Tokenio", action: #selector(aboutClicked), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Tokenio", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Icon

    private var isDarkMenuBar: Bool {
        statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func applyIcon(_ img: NSImage) {
        statusItem.button?.image = img
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    // MARK: - Fetch

    private func triggerFetch(isBackground: Bool = false) {
        guard !loading, !authFailed else { return }
        loading = true
        if !isBackground { updatedItem?.title = "Refreshing\u{2026}  \u{21bb}" }
        DispatchQueue.global().async { [weak self] in
            let result = fetchUsage()
            DispatchQueue.main.async { self?.handleResult(result, isBackground: isBackground) }
        }
    }

    private func handleResult(_ result: UsageResult, isBackground: Bool) {
        loading = false

        switch result {
        case .success(let d):
            applySnapshot(d)
            lastFetched = Date().timeIntervalSince1970
            authFailed = false
            updatedItem.title = "Updated just now  \u{21bb}"
            updateAuthVisibility()

        case .needsLogin:
            authFailed = true
            applyIcon(makeDisconnectedIcon())
            if lastFetched > 0 {
                updatedItem.title = "Session expired (\(fmtAgo(lastFetched)))  \u{26a0}"
            } else {
                updatedItem.title = "Not logged in  \u{26a0}"
            }
            updateAuthVisibility()

        case .error(let msg):
            let short = msg.count > 40 ? String(msg.prefix(40)) + "\u{2026}" : msg
            updatedItem.title = "\(short)  \u{26a0}"
        }
    }

    private func applySnapshot(_ d: UsageData, iconOverride: Bool = true) {
        var sU = d.sessionPct
        let sR = d.sessionReset
        if sR > 0, sR < Date().timeIntervalSince1970 { sU = 0 }
        let sT = elapsedPct(resetTs: sR, windowSecs: 5 * 3600)

        let wU = d.weeklyPct
        let wR = d.weeklyReset
        let wT = elapsedPct(resetTs: wR, windowSecs: 7 * 24 * 3600)

        lastSU = sU; lastST = sT; lastWU = wU; lastWT = wT
        if iconOverride {
            applyIcon(makeIcon(sUsage: sU, sTime: sT, wUsage: wU, wTime: wT, isDark: isDarkMenuBar))
        }

        let snU = d.sonnetPct
        let snR = d.sonnetReset
        let snT = elapsedPct(resetTs: snR, windowSecs: 7 * 24 * 3600)

        sessionView.setData(value: "\(Int(sU))%", usageFrac: sU / 100, timeFrac: sT / 100, resetStr: "Resets in \(fmtReset(sR))")
        weeklyView.setData(value: "\(Int(wU))%", usageFrac: wU / 100, timeFrac: wT / 100, resetStr: "Resets in \(fmtReset(wR))")
        sonnetView.setData(value: "\(Int(snU))%", usageFrac: snU / 100, timeFrac: snT / 100, resetStr: "Resets in \(fmtReset(snR))")

        if d.extraEnabled {
            let oU = d.overagePct
            let oR = d.overageReset
            let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
            let oT = elapsedPct(resetTs: oR, windowSecs: daysInMonth * 24 * 3600)
            extraView.setTitle("Extra usage", suffix: "$\(String(format: "%.2f", d.extraDollars))")
            extraView.setData(value: "\(Int(oU))%", usageFrac: oU / 100, timeFrac: oT / 100, resetStr: "Resets in \(fmtReset(oR))")
        } else {
            extraView.setTitle("Extra usage")
            extraView.setData(value: "Not enabled", usageFrac: 0, timeFrac: 0, resetStr: "")
        }
    }

    // MARK: - Auth visibility

    private func updateAuthVisibility() {
        let loggedIn = loadSession() != nil
        loginItem.isHidden = loggedIn
        logoutItem.isHidden = !loggedIn
    }

    // MARK: - Relative time

    private func updateRelativeTime() {
        guard lastFetched > 0, !authFailed else { return }
        updatedItem.title = "Updated \(fmtAgo(lastFetched))  \u{21bb}"
        applyIcon(makeIcon(sUsage: lastSU, sTime: lastST, wUsage: lastWU, wTime: lastWT, isDark: isDarkMenuBar))
    }

    // MARK: - Actions

    @objc private func refreshClicked() { triggerFetch(isBackground: false) }

    @objc private func wakeRefresh() { triggerFetch(isBackground: true) }

    private func showWelcome() {
        welcomeWindow = WelcomeWindow(onLogin: { [weak self] in
            self?.welcomeWindow = nil
            self?.loginClicked()
        })
        welcomeWindow?.show()
    }

    @objc private func loginClicked() {
        loginWindow = LoginWindow(
            onSuccess: { [weak self] sessionKey, orgId in
                saveSession(Session(sessionKey: sessionKey, orgId: orgId))
                self?.authFailed = false
                self?.loginWindow = nil
                self?.updateAuthVisibility()
                self?.triggerFetch(isBackground: false)
            },
            onCancel: { [weak self] in
                self?.loginWindow = nil
            }
        )
        loginWindow?.show()
    }

    @objc private func logoutClicked() {
        clearSession()
        clearSnapshot()
        authFailed = true
        lastFetched = 0
        applyIcon(makeDisconnectedIcon())
        updatedItem.title = "Not logged in  \u{26a0}"
        sessionView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        weeklyView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        sonnetView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        extraView.setTitle("Extra usage")
        extraView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        updateAuthVisibility()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func aboutClicked() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "github.com/elomid/tokenio",
                attributes: [
                    .link: URL(string: "https://github.com/elomid/tokenio")!,
                    .font: NSFont.systemFont(ofSize: 11),
                ]
            ),
        ])
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}

// MARK: - Launch at Login (SMAppService, macOS 13+)

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            log.error("LaunchAtLogin register failed: \(error.localizedDescription)")
            return false
        }
    }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }
}
