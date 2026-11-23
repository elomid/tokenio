import AppKit
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var claudeEnabled = UserDefaults.standard.object(forKey: "claudeEnabled") as? Bool ?? (loadSession() != nil)
    private var codexEnabled = UserDefaults.standard.object(forKey: "codexEnabled") as? Bool ?? (CodexUsage.cached != nil)
    private var antigravityEnabled = UserDefaults.standard.object(forKey: "antigravityEnabled") as? Bool ?? (AntigravityUsage.cached != nil)
    // Which enabled providers get a bar in the menu bar icon.
    private var iconShowsClaude = UserDefaults.standard.object(forKey: "iconShowsClaude") as? Bool ?? true
    private var iconShowsCodex = UserDefaults.standard.object(forKey: "iconShowsCodex") as? Bool ?? true
    private var iconShowsAntigravity = UserDefaults.standard.object(forKey: "iconShowsAntigravity") as? Bool ?? true
    private var claudeItems: [NSMenuItem] = []
    private var codexItems: [NSMenuItem] = []
    private var providerSeparator: NSMenuItem!
    private var antigravitySeparator: NSMenuItem!
    private var antigravityHeader: NSMenuItem!
    private var antigravityMetricItems: [NSMenuItem] = []
    private var antigravityUpdatedItem: NSMenuItem!
    private var antigravityUsage = AntigravityUsage.cached
    private var antigravityLoading = false
    private var antigravityError: String?
    private var usageSeparator: NSMenuItem!
    private var emptyItem: NSMenuItem!
    private var claudeToggle: NSMenuItem!
    private var codexToggle: NSMenuItem!
    private var antigravityToggle: NSMenuItem!
    private var iconClaudeToggle: NSMenuItem!
    private var iconCodexToggle: NSMenuItem!
    private var iconAntigravityToggle: NSMenuItem!
    private var claudeGeneration = 0
    private var codexView: MetricMenuView!
    private var codexUpdatedItem: NSMenuItem!
    private var codexUsage = CodexUsage.cached
    private var codexLoading = false
    private var codexError: String?
    private var claudeSnapshot: UsageData?
    private var claudeError: String?
    private var statusItem: NSStatusItem!
    private var sessionView: MetricMenuView!
    private var weeklyView: MetricMenuView!
    private var fableView: MetricMenuView!
    private var fableItem: NSMenuItem!
    private var extraView: MetricMenuView!
    private var extraItem: NSMenuItem!
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
    private var lastFU: Double = 0, lastFT: Double = 0
    private var lastShowFable = false

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
        triggerCodexFetch()
        triggerAntigravityFetch()

        if claudeEnabled, loadSession() != nil {
            // Logged in — show snapshot immediately if available, then refresh
            if let (snapshot, ts) = loadSnapshot() {
                applySnapshot(snapshot)
                lastFetched = ts
                updatedItem.title = "Updated \(fmtAgo(ts))  \u{21bb}"
            } else {
                updateIcon()
            }
            triggerFetch(isBackground: true)
        } else {
            authFailed = loadSession() == nil
            updatedItem.title = "Sign in to Claude…"
        }
        updateAuthVisibility()
        updateRelativeTime()
        if !claudeEnabled && !codexEnabled && !antigravityEnabled && !UserDefaults.standard.bool(forKey: "providerWelcomeShown") {
            UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome() }
        }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.triggerFetch(isBackground: true)
            self?.triggerCodexFetch()
            self?.triggerAntigravityFetch()
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
        menu.delegate = self
        menu.minimumWidth = 250

        func addMetric(_ view: MetricMenuView) {
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }

        func addSection(_ title: String) {
            let item = NSMenuItem()
            item.view = SectionHeaderView(title: title)
            menu.addItem(item)
        }

        addSection("Claude")
        sessionView = MetricMenuView(title: "Current session")
        weeklyView = MetricMenuView(title: "Weekly - All models")
        fableView = MetricMenuView(title: "Weekly - Fable", fill: fableBlue)
        extraView = MetricMenuView(title: "Extra usage")

        addMetric(sessionView)
        addMetric(weeklyView)

        fableItem = NSMenuItem()
        fableItem.view = fableView
        fableItem.isHidden = true
        menu.addItem(fableItem)

        extraItem = NSMenuItem()
        extraItem.view = extraView
        extraItem.isHidden = true
        menu.addItem(extraItem)

        updatedItem = NSMenuItem(title: "Refreshing\u{2026}  \u{21bb}", action: #selector(claudeStatusClicked), keyEquivalent: "")
        updatedItem.target = self
        menu.addItem(updatedItem)

        claudeItems = menu.items
        providerSeparator = .separator()
        menu.addItem(providerSeparator)
        let codexStart = menu.items.count
        addSection("Codex")
        codexView = MetricMenuView(title: "Weekly", fill: codexPurple)
        addMetric(codexView)
        codexUpdatedItem = NSMenuItem(title: "Refreshing…", action: #selector(codexStatusClicked), keyEquivalent: "")
        codexUpdatedItem.target = self
        menu.addItem(codexUpdatedItem)
        codexItems = Array(menu.items.dropFirst(codexStart))
        antigravitySeparator = .separator()
        menu.addItem(antigravitySeparator)
        antigravityHeader = NSMenuItem()
        antigravityHeader.view = SectionHeaderView(title: "Antigravity")
        menu.addItem(antigravityHeader)
        antigravityUpdatedItem = NSMenuItem(title: "Refreshing…", action: #selector(antigravityStatusClicked), keyEquivalent: "")
        antigravityUpdatedItem.target = self
        menu.addItem(antigravityUpdatedItem)
        syncAntigravityMetrics()
        emptyItem = NSMenuItem(title: "Choose a provider to get started", action: #selector(showProviderWelcome), keyEquivalent: "")
        emptyItem.target = self
        menu.addItem(emptyItem)
        usageSeparator = .separator()
        menu.addItem(usageSeparator)

        let providers = NSMenu()
        providers.autoenablesItems = false
        claudeToggle = NSMenuItem(title: "Claude", action: #selector(toggleClaude), keyEquivalent: "")
        codexToggle = NSMenuItem(title: "Codex", action: #selector(toggleCodex), keyEquivalent: "")
        antigravityToggle = NSMenuItem(title: "Antigravity", action: #selector(toggleAntigravity), keyEquivalent: "")
        for item in [claudeToggle!, codexToggle!, antigravityToggle!] { item.target = self; providers.addItem(item) }
        let providerItem = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
        providerItem.submenu = providers
        menu.addItem(providerItem)

        let iconProviders = NSMenu()
        iconProviders.autoenablesItems = false
        iconClaudeToggle = NSMenuItem(title: "Claude", action: #selector(toggleIconClaude), keyEquivalent: "")
        iconCodexToggle = NSMenuItem(title: "Codex", action: #selector(toggleIconCodex), keyEquivalent: "")
        iconAntigravityToggle = NSMenuItem(title: "Antigravity", action: #selector(toggleIconAntigravity), keyEquivalent: "")
        for item in [iconClaudeToggle!, iconCodexToggle!, iconAntigravityToggle!] { item.target = self; iconProviders.addItem(item) }
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = iconProviders
        menu.addItem(iconItem)

        loginItem = NSMenuItem(title: "Log in to Claude\u{2026}", action: #selector(loginClicked), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        logoutItem = NSMenuItem(title: "Log out of Claude", action: #selector(logoutClicked), keyEquivalent: "")
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

    private var iconClaude: Bool { claudeEnabled && iconShowsClaude }
    private var iconCodex: Bool { codexEnabled && iconShowsCodex }
    private var iconAntigravity: Bool { antigravityEnabled && iconShowsAntigravity }

    private func updateIcon() {
        // Keep Codex and Antigravity visible even when Claude is disconnected.
        let tightest = antigravityUsage?.tightest
        statusItem.button?.image = makeIcon(
            sUsage: lastSU, sTime: lastST, wUsage: lastWU, wTime: lastWT,
            fUsage: lastFU, fTime: lastFT, showFable: lastShowFable, showClaude: iconClaude, showCodex: iconCodex,
            isDark: isDarkMenuBar, cUsage: codexUsage?.usedPercent ?? 0,
            cTime: codexUsage.map { elapsedPct(resetTs: $0.resetsAt, windowSecs: $0.windowDurationMins * 60) } ?? 0,
            showAntigravity: iconAntigravity, aUsage: tightest.map(antigravityUsed) ?? 0,
            aTime: tightest.map(antigravityElapsed) ?? 0)
        let providers = [iconClaude ? "Claude: session, weekly" : nil, iconCodex ? "Codex: weekly (purple)" : nil,
                         iconAntigravity ? "Antigravity: tightest limit (teal)" : nil].compactMap { $0 }
        let anyEnabled = claudeEnabled || codexEnabled || antigravityEnabled
        statusItem.button?.toolTip = providers.isEmpty
            ? (anyEnabled ? "Tokenio — choose providers in Menu Bar Icon" : "Tokenio — choose a provider")
            : providers.joined(separator: " · ")
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    // MARK: - Fetch

    private func triggerFetch(isBackground: Bool = false) {
        guard claudeEnabled, !loading, !authFailed, let session = loadSession() else { return }
        loading = true
        if !isBackground { updatedItem?.title = "Refreshing\u{2026}  \u{21bb}" }
        let generation = claudeGeneration
        DispatchQueue.global().async { [weak self] in
            let result = fetchUsage(session: session)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard generation == self.claudeGeneration else {
                    self.triggerFetch(isBackground: false)
                    return
                }
                guard self.claudeEnabled else { return }
                self.handleResult(result, isBackground: isBackground)
            }
        }
    }

    private func handleResult(_ result: UsageResult, isBackground: Bool) {
        loading = false

        switch result {
        case .success(let d):
            saveSnapshot(d)
            claudeError = nil
            updatedItem.toolTip = nil
            applySnapshot(d)
            lastFetched = Date().timeIntervalSince1970
            authFailed = false
            updatedItem.title = "Updated just now  \u{21bb}"
            updateAuthVisibility()

        case .needsLogin:
            clearSession()
            claudeError = nil
            authFailed = true
            updateIcon()
            updatedItem.title = "Sign in to Claude…"
            updateAuthVisibility()

        case .error(let msg):
            claudeError = msg
            updatedItem.title = lastFetched > 0 ? "Saved usage — details…" : "Refresh failed — details…"
            updatedItem.toolTip = msg
        }
    }

    private func applySnapshot(_ d: UsageData, iconOverride: Bool = true) {
        claudeSnapshot = d
        var sU = d.sessionPct
        let sR = d.sessionReset
        if sR > 0, sR < Date().timeIntervalSince1970 { sU = 0 }
        let sT = elapsedPct(resetTs: sR, windowSecs: 5 * 3600)

        var wU = d.weeklyPct
        let wR = d.weeklyReset
        if wR > 0, wR < Date().timeIntervalSince1970 { wU = 0 }
        let wT = elapsedPct(resetTs: wR, windowSecs: 7 * 24 * 3600)

        var fU = d.fablePct
        let fR = d.fableReset
        if fR > 0, fR < Date().timeIntervalSince1970 { fU = 0 }
        let fT = elapsedPct(resetTs: fR, windowSecs: 7 * 24 * 3600)

        lastSU = sU; lastST = sT; lastWU = wU; lastWT = wT
        lastFU = fU; lastFT = fT; lastShowFable = d.fableEnabled
        if iconOverride {
            updateIcon()
        }

        sessionView.setData(value: "\(Int(sU))%", usageFrac: sU / 100, timeFrac: sT / 100, resetStr: "Resets in \(fmtReset(sR))")
        weeklyView.setData(value: "\(Int(wU))%", usageFrac: wU / 100, timeFrac: wT / 100, resetStr: "Resets in \(fmtReset(wR))")
        if d.fableEnabled {
            fableView.setData(value: "\(Int(fU))%", usageFrac: fU / 100, timeFrac: fT / 100, resetStr: "Resets in \(fmtReset(fR))")
            fableItem.isHidden = false
        } else {
            fableItem.isHidden = true
        }

        if d.extraEnabled {
            let oU = d.overagePct
            let oR = d.overageReset
            let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
            let oT = elapsedPct(resetTs: oR, windowSecs: daysInMonth * 24 * 3600)
            extraView.setTitle("Extra usage", suffix: "$\(String(format: "%.2f", d.extraDollars))")
            extraView.setData(value: "\(Int(oU))%", usageFrac: oU / 100, timeFrac: oT / 100, resetStr: "Resets in \(fmtReset(oR))")
            extraItem.isHidden = false
        } else {
            extraItem.isHidden = true
        }
    }

    // MARK: - Auth visibility

    private func updateAuthVisibility() {
        let loggedIn = loadSession() != nil
        loginItem.isHidden = !claudeEnabled || (loggedIn && !authFailed)
        logoutItem.isHidden = !claudeEnabled || !loggedIn
        for item in claudeItems { item.isHidden = !claudeEnabled }
        fableItem.isHidden = !claudeEnabled || !(claudeSnapshot?.fableEnabled ?? false)
        extraItem.isHidden = !claudeEnabled || !(claudeSnapshot?.extraEnabled ?? false)
        for item in codexItems { item.isHidden = !codexEnabled }
        for item in [antigravityHeader!, antigravityUpdatedItem!] + antigravityMetricItems { item.isHidden = !antigravityEnabled }
        providerSeparator.isHidden = !claudeEnabled || !codexEnabled
        antigravitySeparator.isHidden = !antigravityEnabled || !(claudeEnabled || codexEnabled)
        emptyItem.isHidden = claudeEnabled || codexEnabled || antigravityEnabled
        claudeToggle.state = claudeEnabled ? .on : .off
        codexToggle.state = codexEnabled ? .on : .off
        antigravityToggle.state = antigravityEnabled ? .on : .off
        for (toggle, enabled, shown) in [(iconClaudeToggle!, claudeEnabled, iconShowsClaude),
                                         (iconCodexToggle!, codexEnabled, iconShowsCodex),
                                         (iconAntigravityToggle!, antigravityEnabled, iconShowsAntigravity)] {
            toggle.state = shown ? .on : .off
            toggle.isEnabled = enabled
            toggle.toolTip = enabled ? nil : "Turn this provider on in Providers first."
        }
    }

    // MARK: - Antigravity

    private func antigravityUsed(_ limit: AntigravityUsage.Limit) -> Double {
        limit.resetsAt < Date().timeIntervalSince1970 ? 0 : limit.usedPercent
    }

    private func antigravityElapsed(_ limit: AntigravityUsage.Limit) -> Double {
        limit.windowSecs.map { elapsedPct(resetTs: limit.resetsAt, windowSecs: $0) } ?? 0
    }

    /// Antigravity reports a variable set of limits, so its rows follow the
    /// latest response instead of being fixed at build time.
    private func syncAntigravityMetrics() {
        guard let menu = antigravityUpdatedItem.menu else { return }
        let titles = antigravityUsage?.limits.map(\.title) ?? ["Usage"]
        let current = antigravityMetricItems.compactMap { ($0.view as? MetricMenuView)?.title }
        if titles != current {
            for item in antigravityMetricItems { menu.removeItem(item) }
            antigravityMetricItems = titles.map { title in
                let item = NSMenuItem()
                item.view = MetricMenuView(title: title, fill: antigravityTeal)
                item.isHidden = !antigravityEnabled
                return item
            }
            let index = menu.index(of: antigravityUpdatedItem)
            for (offset, item) in antigravityMetricItems.enumerated() { menu.insertItem(item, at: index + offset) }
        }
        let views = antigravityMetricItems.compactMap { $0.view as? MetricMenuView }
        if let usage = antigravityUsage {
            for (view, limit) in zip(views, usage.limits) {
                let used = antigravityUsed(limit)
                view.setData(value: "\(Int(used.rounded()))%", usageFrac: used / 100,
                             timeFrac: antigravityElapsed(limit) / 100, resetStr: "Resets in \(fmtReset(limit.resetsAt))")
            }
            antigravityUpdatedItem.title = antigravityError == nil ? "Updated \(fmtAgo(usage.fetchedAt))  ↻" : "Saved usage — details…"
            antigravityUpdatedItem.toolTip = antigravityError.map { "\($0)\n\nShowing saved usage from \(fmtAgo(usage.fetchedAt))." }
        } else {
            views.first?.setData(value: "—", usageFrac: 0, timeFrac: 0, resetStr: "Waiting for usage")
            antigravityUpdatedItem.title = antigravityError == nil ? "Refreshing…" : "Connect Antigravity — details…"
            antigravityUpdatedItem.toolTip = antigravityError
        }
        if antigravityLoading { antigravityUpdatedItem.title = "Refreshing…" }
    }

    private func triggerAntigravityFetch() {
        guard antigravityEnabled, !antigravityLoading else { return }
        antigravityLoading = true
        antigravityUpdatedItem.title = "Refreshing…"
        DispatchQueue.global().async { [weak self] in
            let result = Result { try AntigravityUsage.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.antigravityLoading = false
                guard self.antigravityEnabled else { return }
                switch result {
                case .success(let usage):
                    self.antigravityUsage = usage
                    if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: "antigravityUsage") }
                    self.antigravityError = nil
                case .failure(let error):
                    self.antigravityError = error.localizedDescription
                }
                self.updateRelativeTime()
            }
        }
    }

    // MARK: - Relative time

    private func updateRelativeTime() {
        if claudeEnabled, let snapshot = claudeSnapshot { applySnapshot(snapshot) }
        if lastFetched > 0, !loading, !authFailed, claudeError == nil {
            updatedItem.title = "Updated \(fmtAgo(lastFetched))  ↻"
        }
        if let usage = codexUsage {
            codexView.setData(value: "\(Int(usage.usedPercent))%", usageFrac: usage.usedPercent / 100,
                              timeFrac: elapsedPct(resetTs: usage.resetsAt, windowSecs: usage.windowDurationMins * 60) / 100,
                              resetStr: "Resets in \(fmtReset(usage.resetsAt))")
            codexUpdatedItem.title = codexError == nil ? "Updated \(fmtAgo(usage.fetchedAt))  ↻" : "Saved usage — details…"
            codexUpdatedItem.toolTip = codexError.map { "\($0)\n\nShowing saved usage from \(fmtAgo(usage.fetchedAt))." }
        } else {
            codexView.setData(value: "—", usageFrac: 0, timeFrac: 0, resetStr: "Waiting for usage")
            codexUpdatedItem.title = codexError == nil ? "Refreshing…" : "Connect Codex — details…"
            codexUpdatedItem.toolTip = codexError
        }
        if codexLoading { codexUpdatedItem.title = "Refreshing…" }
        syncAntigravityMetrics()
        updateAuthVisibility()
        updateIcon()
    }

    private func triggerCodexFetch() {
        guard codexEnabled, !codexLoading else { return }
        codexLoading = true
        codexUpdatedItem.title = "Refreshing…"
        DispatchQueue.global().async { [weak self] in
            let result = Result { try CodexUsage.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.codexLoading = false
                guard self.codexEnabled else { return }
                switch result {
                case .success(let usage):
                    self.codexUsage = usage
                    if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: "codexUsage") }
                    self.codexError = nil
                case .failure(let error):
                    self.codexError = error.localizedDescription
                }
                self.updateRelativeTime()
            }
        }
    }

    // MARK: - Actions

    func menuWillOpen(_ menu: NSMenu) {
        updateRelativeTime()
    }

    private func setClaudeEnabled(_ enabled: Bool) {
        claudeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "claudeEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        updateAuthVisibility()
        updateIcon()
    }

    private func setCodexEnabled(_ enabled: Bool) {
        codexEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "codexEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        updateAuthVisibility()
        updateIcon()
    }

    @objc private func toggleClaude() {
        setClaudeEnabled(!claudeEnabled)
        if claudeEnabled {
            if loadSession() == nil || authFailed { loginClicked() }
            else { triggerFetch(isBackground: false) }
        }
    }

    @objc private func toggleCodex() {
        setCodexEnabled(!codexEnabled)
        if codexEnabled { triggerCodexFetch() }
    }

    private func setAntigravityEnabled(_ enabled: Bool) {
        antigravityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "antigravityEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        updateAuthVisibility()
        updateIcon()
    }

    @objc private func toggleAntigravity() {
        setAntigravityEnabled(!antigravityEnabled)
        if antigravityEnabled { triggerAntigravityFetch() }
    }

    @objc private func toggleIconClaude() {
        iconShowsClaude.toggle()
        UserDefaults.standard.set(iconShowsClaude, forKey: "iconShowsClaude")
        updateAuthVisibility(); updateIcon()
    }

    @objc private func toggleIconCodex() {
        iconShowsCodex.toggle()
        UserDefaults.standard.set(iconShowsCodex, forKey: "iconShowsCodex")
        updateAuthVisibility(); updateIcon()
    }

    @objc private func toggleIconAntigravity() {
        iconShowsAntigravity.toggle()
        UserDefaults.standard.set(iconShowsAntigravity, forKey: "iconShowsAntigravity")
        updateAuthVisibility(); updateIcon()
    }

    @objc private func showProviderWelcome() { showWelcome() }

    private func showError(provider: String, message: String, fetchedAt: TimeInterval, retry: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(provider) couldn’t refresh"
        alert.informativeText = message + (fetchedAt > 0 ? "\n\nShowing saved usage from \(fmtAgo(fetchedAt))." : "")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { retry() }
    }

    @objc private func claudeStatusClicked() {
        if authFailed { loginClicked() }
        else if let error = claudeError {
            showError(provider: "Claude", message: error, fetchedAt: lastFetched) { triggerFetch(isBackground: false) }
        } else { triggerFetch(isBackground: false) }
    }

    @objc private func codexStatusClicked() {
        if let error = codexError {
            showError(provider: "Codex", message: error, fetchedAt: codexUsage?.fetchedAt ?? 0) { triggerCodexFetch() }
        } else { triggerCodexFetch() }
    }

    @objc private func antigravityStatusClicked() {
        if let error = antigravityError {
            showError(provider: "Antigravity", message: error, fetchedAt: antigravityUsage?.fetchedAt ?? 0) { triggerAntigravityFetch() }
        } else { triggerAntigravityFetch() }
    }

    @objc private func refreshClicked() { triggerFetch(isBackground: false); triggerCodexFetch(); triggerAntigravityFetch() }

    @objc private func wakeRefresh() { triggerFetch(isBackground: true); triggerCodexFetch(); triggerAntigravityFetch() }

    private func showWelcome() {
        welcomeWindow?.close()
        welcomeWindow = WelcomeWindow(onLogin: { [weak self] in
            self?.setClaudeEnabled(true)
            self?.loginClicked()
        }, onCodex: { [weak self] in
            self?.setCodexEnabled(true)
            self?.triggerCodexFetch()
        }, onAntigravity: { [weak self] in
            self?.setAntigravityEnabled(true)
            self?.triggerAntigravityFetch()
        })
        welcomeWindow?.show()
    }

    @objc private func loginClicked() {
        guard loginWindow == nil else { loginWindow?.show(); return }
        loginWindow = LoginWindow(
            onSuccess: { [weak self] sessionKey, orgId in
                self?.claudeGeneration += 1
                saveSession(Session(sessionKey: sessionKey, orgId: orgId))
                self?.setClaudeEnabled(true)
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
        claudeGeneration += 1
        clearSession()
        clearSnapshot()
        claudeSnapshot = nil
        lastSU = 0; lastST = 0; lastWU = 0; lastWT = 0; lastFU = 0; lastFT = 0
        authFailed = true
        lastFetched = 0
        updateIcon()
        updatedItem.title = "Not logged in  \u{26a0}"
        sessionView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        weeklyView.setData(value: "\u{2014}", usageFrac: 0, timeFrac: 0, resetStr: "\u{2014}")
        fableItem.isHidden = true
        extraItem.isHidden = true
        setClaudeEnabled(false)
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
