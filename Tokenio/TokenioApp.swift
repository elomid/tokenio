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
    private var connectItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var fetchTimer: Timer?
    private var uiTimer: Timer?
    private var lastFetched: TimeInterval = 0
    private var loading = false
    private var authFailed = false  // prevents relative-time timer from overwriting auth error state

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

        if loadStoredAccess() != nil {
            // Connected — show snapshot immediately if available, then refresh
            if let (snapshot, ts) = loadSnapshot() {
                applySnapshot(snapshot)
                lastFetched = ts
                updatedItem.title = "Updated \(fmtAgo(ts))  ↻"
            } else {
                applyIcon(makeIcon(sUsage: 0, sTime: 0, wUsage: 0, wTime: 0, isDark: isDarkMenuBar))
            }
            triggerFetch(isBackground: true)
        } else {
            // Disconnected — warning icon, show stale data if any
            applyIcon(makeDisconnectedIcon())
            if let (snapshot, ts) = loadSnapshot() {
                applySnapshot(snapshot, iconOverride: false)
                lastFetched = ts
                updatedItem.title = "Disconnected (data from \(fmtAgo(ts)))  ⚠"
            } else {
                updatedItem.title = "Not connected  ⚠"
            }
            authFailed = true
            updateAuthVisibility()
            // Auto-open menu on first launch so user sees what to do
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItem.button?.performClick(nil)
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

        updatedItem = NSMenuItem(title: "Refreshing…  ↻", action: #selector(refreshClicked), keyEquivalent: "")
        updatedItem.target = self
        menu.addItem(updatedItem)

        menu.addItem(.separator())

        connectItem = NSMenuItem(title: "Connect to Claude Code…", action: #selector(connectClicked), keyEquivalent: "")
        connectItem.target = self
        menu.addItem(connectItem)
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
        guard !loading else { return }
        loading = true
        if !isBackground { updatedItem?.title = "Refreshing…  ↻" }
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
            updatedItem.title = "Updated just now  ↻"
            updateAuthVisibility()

        case .needsLogin:
            authFailed = true
            applyIcon(makeDisconnectedIcon())
            if lastFetched > 0 {
                updatedItem.title = "Disconnected (data from \(fmtAgo(lastFetched)))  ⚠"
            } else {
                updatedItem.title = "Not connected  ⚠"
            }
            updateAuthVisibility()

        case .error(let msg):
            let short = msg.count > 40 ? String(msg.prefix(40)) + "…" : msg
            updatedItem.title = "\(short)  ⚠"
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
        let connected = loadStoredAccess() != nil
        connectItem.isHidden = connected
        connectItem.title = lastFetched > 0 ? "Reconnect to Claude Code…" : "Connect to Claude Code…"
    }

    // MARK: - Relative time

    private func updateRelativeTime() {
        guard lastFetched > 0, !authFailed else { return }
        updatedItem.title = "Updated \(fmtAgo(lastFetched))  ↻"
        applyIcon(makeIcon(sUsage: lastSU, sTime: lastST, wUsage: lastWU, wTime: lastWT, isDark: isDarkMenuBar))
    }

    // MARK: - Actions

    @objc private func refreshClicked() { triggerFetch(isBackground: false) }

    @objc private func wakeRefresh() { triggerFetch(isBackground: true) }

    @objc private func connectClicked() {
        // Explain what's about to happen before the system keychain prompt
        let explain = NSAlert()
        explain.messageText = "Connect to Claude Code"
        explain.informativeText = "Tokenio will read your Claude Code credentials to display usage data.\n\nmacOS will ask you to allow keychain access — click \"Always Allow\" so Tokenio can reconnect without prompting again."
        explain.addButton(withTitle: "Continue")
        explain.addButton(withTitle: "Cancel")
        explain.alertStyle = .informational

        guard explain.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global().async { [weak self] in
            let imported = importClaudeCodeAccessInteractive()
            DispatchQueue.main.async {
                if imported != nil {
                    self?.authFailed = false
                    self?.triggerFetch(isBackground: false)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Not Connected"
                    alert.informativeText = "No valid Claude Code credentials found, or the token is expired. Make sure Claude Code CLI is installed and you're logged in."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
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
