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

    private var claudeEnabled = UserDefaults.standard.object(forKey: "claudeEnabled") as? Bool ?? (loadSession() != nil)
    private var codexEnabled = UserDefaults.standard.object(forKey: "codexEnabled") as? Bool ?? (CodexUsage.cached != nil)
    private var antigravityEnabled = UserDefaults.standard.object(forKey: "antigravityEnabled") as? Bool ?? (AntigravityUsage.cached != nil)
    // Which enabled providers get a bar in the menu bar icon.
    private var iconShowsClaude = UserDefaults.standard.object(forKey: "iconShowsClaude") as? Bool ?? true
    private var iconShowsCodex = UserDefaults.standard.object(forKey: "iconShowsCodex") as? Bool ?? true
    private var iconShowsAntigravity = UserDefaults.standard.object(forKey: "iconShowsAntigravity") as? Bool ?? true
    private var mode = DisplayMode.current

    private var statusItem: NSStatusItem!
    private var panel: UsagePanelController!

    private var claudeSnapshot: UsageData?
    private var claudeError: String?
    private var claudeGeneration = 0
    private var lastFetched: TimeInterval = 0
    private var loading = false
    private var authFailed = false

    private var codexUsage = CodexUsage.cached
    private var codexLoading = false
    private var codexError: String?

    private var antigravityUsage = AntigravityUsage.cached
    private var antigravityLoading = false
    private var antigravityError: String?

    private var fetchTimer: Timer?
    private var uiTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var loginWindow: LoginWindow?
    private var welcomeWindow: WelcomeWindow?

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
        buildPanel()
        triggerCodexFetch()
        triggerAntigravityFetch()

        if claudeEnabled, loadSession() != nil {
            // Logged in: show the saved snapshot immediately, then refresh.
            if let (snapshot, ts) = loadSnapshot() {
                claudeSnapshot = snapshot
                lastFetched = ts
            }
            triggerFetch()
        } else {
            authFailed = loadSession() == nil
        }
        refreshUI()
        if !claudeEnabled && !codexEnabled && !antigravityEnabled && !UserDefaults.standard.bool(forKey: "providerWelcomeShown") {
            UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome() }
        }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        RunLoop.main.add(fetchTimer!, forMode: .common)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wakeRefresh),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    // MARK: - Panel

    private func buildPanel() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imageScaling = .scaleNone
            button.setAccessibilityTitle("Tokenio")
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
        }
        panel = UsagePanelController(statusItem: statusItem)
        panel.view.refreshButton.target = self
        panel.view.refreshButton.action = #selector(refreshClicked)
        panel.view.moreButton.target = self
        panel.view.moreButton.action = #selector(moreClicked(_:))
        panel.view.columns.onGroupClick = { [weak self] id in self?.groupClicked(id) }
    }

    @objc private func statusItemClicked() {
        refreshUI()
        panel.toggle()
    }

    /// Redraws the icon and, when the panel is open, its contents.
    private func refreshUI() {
        updateIcon()
        guard let panel else { return }
        panel.view.columns.mode = mode
        panel.view.columns.groups = panelGroups()
        panel.view.refreshButton.title = footerText()
        if panel.isVisible { panel.resize() }
    }

    private func claudeColumns(_ d: UsageData) -> [PanelColumn] {
        func column(_ label: String, _ pct: Double, _ reset: TimeInterval, _ window: TimeInterval, tint: BarTint = .neutral) -> PanelColumn {
            PanelColumn(label: label, value: .make(usedPercent: pct, resetsAt: reset, windowSecs: window, tint: tint), resetsAt: reset)
        }
        var columns = [column("5h", d.sessionPct, d.sessionReset, 5 * 3600),
                       column("Week", d.weeklyPct, d.weeklyReset, 7 * 86400)]
        if d.fableEnabled { columns.append(column("Fable", d.fablePct, d.fableReset, 7 * 86400, tint: .fable)) }
        if d.extraEnabled {
            let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
            var extra = column("Extra", d.overagePct, d.overageReset, days * 86400)
            extra.toolTip = "Extra usage: $\(String(format: "%.2f", d.extraDollars)) spent"
            columns.append(extra)
        }
        return columns
    }

    private func codexColumns(_ u: CodexUsage) -> [PanelColumn] {
        [PanelColumn(label: Self.windowLabel(minutes: u.windowDurationMins),
                     value: .make(usedPercent: u.usedPercent, resetsAt: u.resetsAt, windowSecs: u.windowDurationMins * 60),
                     resetsAt: u.resetsAt)]
    }

    static func windowLabel(minutes: Double) -> String {
        switch minutes {
        case 10080: return "Week"
        case 1440: return "Day"
        case 40320...44640: return "Month"
        case ..<1440: return "\(Int((minutes / 60).rounded()))h"
        default: return "\(Int((minutes / 1440).rounded()))d"
        }
    }

    /// Antigravity titles read "<window> - <group>". The first group's columns are
    /// named by window ("5h", "Week"); other groups by model ("Flash").
    static func antigravityLabels(_ titles: [String]) -> [String] {
        let parts = titles.map { title -> (window: String, group: String) in
            let pieces = title.components(separatedBy: " - ")
            return pieces.count > 1 ? (pieces[0], pieces.dropFirst().joined(separator: " - ")) : (title, "")
        }
        func short(_ window: String) -> String {
            if window.hasSuffix("-hour"), let n = Int(window.dropLast(5)) { return "\(n)h" }
            switch window {
            case "Weekly": return "Week"
            case "Daily": return "Day"
            case "Monthly": return "Month"
            default: return window.components(separatedBy: " ").first ?? window
            }
        }
        let primary = parts.first?.group ?? ""
        return parts.map { p in
            if p.group == primary || p.group.isEmpty { return short(p.window) }
            // "Gemini 3 Flash" reads as "Flash"; a trailing version number keeps the whole name.
            let last = p.group.components(separatedBy: " ").last ?? p.group
            let model = last.allSatisfy(\.isNumber) ? p.group : last
            let siblings = parts.filter { $0.group == p.group }.count
            return siblings > 1 ? "\(model) \(short(p.window))" : model
        }
    }

    private func antigravityColumns(_ u: AntigravityUsage) -> [PanelColumn] {
        let labels = Self.antigravityLabels(u.limits.map(\.title))
        return zip(u.limits, labels).map { limit, label in
            PanelColumn(label: label, value: .make(usedPercent: limit.usedPercent, resetsAt: limit.resetsAt, windowSecs: limit.windowSecs, tint: .antigravity),
                        resetsAt: limit.resetsAt, toolTip: limit.title)
        }
    }

    /// Limits belonging to Antigravity's primary model group (e.g. 5h and Week), shown in the menu bar icon.
    private func antigravityIconBars(_ u: AntigravityUsage) -> [BarValue] {
        func groupName(_ title: String) -> String {
            let pieces = title.components(separatedBy: " - ")
            return pieces.count > 1 ? pieces.dropFirst().joined(separator: " - ") : ""
        }
        guard let first = u.limits.first else { return [] }
        let primary = groupName(first.title)
        let primaryLimits = u.limits.filter { groupName($0.title) == primary }
        return primaryLimits.prefix(2).map {
            .make(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowSecs: $0.windowSecs, tint: .antigravity)
        }
    }

    private func panelGroups() -> [PanelGroup] {
        var groups: [PanelGroup] = []
        if claudeEnabled {
            if loadSession() == nil || authFailed {
                groups.append(PanelGroup(id: "claude", name: "Claude", columns: [], status: .action("Sign in…")))
            } else if let snapshot = claudeSnapshot {
                groups.append(PanelGroup(id: "claude", name: "Claude", columns: claudeColumns(snapshot),
                                         status: claudeError.map { .warning($0) } ?? .ok))
            } else {
                groups.append(PanelGroup(id: "claude", name: "Claude", columns: [],
                                         status: claudeError == nil || loading ? .loading : .action("Couldn’t load…")))
            }
        }
        if codexEnabled {
            if let usage = codexUsage {
                groups.append(PanelGroup(id: "codex", name: "Codex", columns: codexColumns(usage), status: codexError.map { .warning($0) } ?? .ok))
            } else {
                groups.append(PanelGroup(id: "codex", name: "Codex", columns: [], status: codexError == nil || codexLoading ? .loading : .action("Connect Codex…")))
            }
        }
        if antigravityEnabled {
            if let usage = antigravityUsage {
                groups.append(PanelGroup(id: "antigravity", name: "Antigravity", columns: antigravityColumns(usage),
                                         status: antigravityError.map { .warning($0) } ?? .ok))
            } else {
                groups.append(PanelGroup(id: "antigravity", name: "Antigravity", columns: [],
                                         status: antigravityError == nil || antigravityLoading ? .loading : .action("Connect Antigravity…")))
            }
        }
        return groups
    }

    /// One line for every provider: the oldest successful refresh among those showing numbers.
    private func footerText() -> String {
        if (claudeEnabled && loading) || (codexEnabled && codexLoading) || (antigravityEnabled && antigravityLoading) {
            return "Refreshing…"
        }
        var times: [TimeInterval] = []
        if claudeEnabled, claudeSnapshot != nil, lastFetched > 0, !authFailed { times.append(lastFetched) }
        if codexEnabled, let usage = codexUsage { times.append(usage.fetchedAt) }
        if antigravityEnabled, let usage = antigravityUsage { times.append(usage.fetchedAt) }
        guard let oldest = times.min() else { return "Refresh" }
        return "Updated \(fmtAgo(oldest))"
    }

    private func groupClicked(_ id: String?) {
        panel.close()
        switch id {
        case nil:
            showWelcome()
        case "claude":
            if loadSession() == nil || authFailed { loginClicked() }
            else if let error = claudeError {
                showError(provider: "Claude", message: error, fetchedAt: claudeSnapshot == nil ? 0 : lastFetched) { triggerFetch() }
            }
        case "codex":
            showError(provider: "Codex", message: codexError ?? "Couldn’t read Codex usage.", fetchedAt: codexUsage?.fetchedAt ?? 0) { triggerCodexFetch() }
        case "antigravity":
            showError(provider: "Antigravity", message: antigravityError ?? "Couldn’t read Antigravity usage.",
                      fetchedAt: antigravityUsage?.fetchedAt ?? 0) { triggerAntigravityFetch() }
        default:
            break
        }
    }

    // MARK: - More menu

    @objc private func moreClicked(_ sender: NSButton) {
        let menu = buildMoreMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        panel.view.resetHover()
    }

    private func buildMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector?, key: String = "", state: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let state { item.state = state ? .on : .off }
            item.isEnabled = enabled
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            items.forEach(sub.addItem)
            parent.submenu = sub
            return parent
        }
        menu.addItem(submenu("Providers", [
            item("Claude", #selector(toggleClaude), state: claudeEnabled),
            item("Codex", #selector(toggleCodex), state: codexEnabled),
            item("Antigravity", #selector(toggleAntigravity), state: antigravityEnabled),
        ]))
        let iconItems = [
            item("Claude", #selector(toggleIconClaude), state: iconShowsClaude, enabled: claudeEnabled),
            item("Codex", #selector(toggleIconCodex), state: iconShowsCodex, enabled: codexEnabled),
            item("Antigravity", #selector(toggleIconAntigravity), state: iconShowsAntigravity, enabled: antigravityEnabled),
        ]
        for i in iconItems where !i.isEnabled { i.toolTip = "Turn this provider on in Providers first." }
        menu.addItem(submenu("Menu Bar Icon", iconItems))
        menu.addItem(submenu("Show", [
            item("Used", #selector(showUsed), state: mode == .used),
            item("Left", #selector(showLeft), state: mode == .left),
        ]))
        menu.addItem(.separator())
        if claudeEnabled {
            if loadSession() != nil, !authFailed { menu.addItem(item("Log out of Claude", #selector(logoutClicked))) }
            else { menu.addItem(item("Log in to Claude…", #selector(loginClicked))) }
        }
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), state: LaunchAtLogin.isEnabled))
        menu.addItem(item("About Tokenio", #selector(aboutClicked)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tokenio", #selector(quitClicked), key: "q"))
        return menu
    }

    @objc private func showUsed() { setMode(.used) }
    @objc private func showLeft() { setMode(.left) }

    private func setMode(_ newMode: DisplayMode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "displayMode")
        refreshUI()
    }

    // MARK: - Icon

    private var iconClaude: Bool { claudeEnabled && iconShowsClaude }
    private var iconCodex: Bool { codexEnabled && iconShowsCodex }
    private var iconAntigravity: Bool { antigravityEnabled && iconShowsAntigravity }

    /// Claude's session and weekly (and Fable), Codex's limit, and Antigravity's
    /// primary 5h and weekly limits, for the providers chosen in Menu Bar Icon.
    private func iconGroups() -> [[BarValue]] {
        let empty = BarValue(used: 0, elapsed: 0, stale: true)
        var groups: [[BarValue]] = []
        if iconClaude {
            if let d = claudeSnapshot, !authFailed {
                groups.append(claudeColumns(d).filter { $0.label != "Extra" }.map(\.value))
            } else {
                groups.append([empty, empty])
            }
        }
        if iconCodex { groups.append(codexUsage.map { codexColumns($0).map(\.value) } ?? [empty]) }
        if iconAntigravity {
            let bars = antigravityUsage.map(antigravityIconBars) ?? []
            groups.append(bars.isEmpty ? [BarValue(used: 0, elapsed: 0, stale: true, tint: .antigravity)] : bars)
        }
        return groups
    }

    private var isDarkMenuBar: Bool {
        statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func updateIcon() {
        statusItem.button?.image = makeStatusIcon(groups: iconGroups(), mode: mode, isDark: isDarkMenuBar)
    }

    // MARK: - Fetch

    private func refreshAll(isBackground: Bool = true) {
        triggerFetch()
        triggerCodexFetch()
        triggerAntigravityFetch()
    }

    private func triggerFetch() {
        guard claudeEnabled, !loading, !authFailed, let session = loadSession() else { return }
        loading = true
        refreshUI()
        let generation = claudeGeneration
        DispatchQueue.global().async { [weak self] in
            let result = fetchUsage(session: session)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard generation == self.claudeGeneration else {
                    self.triggerFetch()
                    return
                }
                guard self.claudeEnabled else { self.refreshUI(); return }
                self.handleResult(result)
            }
        }
    }

    private func handleResult(_ result: UsageResult) {
        switch result {
        case .success(let d):
            saveSnapshot(d)
            claudeSnapshot = d
            claudeError = nil
            lastFetched = Date().timeIntervalSince1970
            authFailed = false
        case .needsLogin:
            clearSession()
            claudeError = nil
            authFailed = true
        case .error(let msg):
            claudeError = msg
        }
        refreshUI()
    }

    private func triggerCodexFetch() {
        guard codexEnabled, !codexLoading else { return }
        codexLoading = true
        refreshUI()
        DispatchQueue.global().async { [weak self] in
            let result = Result { try CodexUsage.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.codexLoading = false
                if self.codexEnabled {
                    switch result {
                    case .success(let usage):
                        self.codexUsage = usage
                        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: "codexUsage") }
                        self.codexError = nil
                    case .failure(let error):
                        self.codexError = error.localizedDescription
                    }
                }
                self.refreshUI()
            }
        }
    }

    private func triggerAntigravityFetch() {
        guard antigravityEnabled, !antigravityLoading else { return }
        antigravityLoading = true
        refreshUI()
        DispatchQueue.global().async { [weak self] in
            let result = Result { try AntigravityUsage.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.antigravityLoading = false
                if self.antigravityEnabled {
                    switch result {
                    case .success(let usage):
                        self.antigravityUsage = usage
                        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: "antigravityUsage") }
                        self.antigravityError = nil
                    case .failure(let error):
                        self.antigravityError = error.localizedDescription
                    }
                }
                self.refreshUI()
            }
        }
    }

    // MARK: - Providers

    private func setClaudeEnabled(_ enabled: Bool) {
        claudeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "claudeEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        refreshUI()
    }

    private func setCodexEnabled(_ enabled: Bool) {
        codexEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "codexEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        refreshUI()
    }

    private func setAntigravityEnabled(_ enabled: Bool) {
        antigravityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "antigravityEnabled")
        UserDefaults.standard.set(true, forKey: "providerWelcomeShown")
        refreshUI()
    }

    @objc private func toggleClaude() {
        setClaudeEnabled(!claudeEnabled)
        if claudeEnabled {
            if loadSession() == nil || authFailed { panel.close(); loginClicked() }
            else { triggerFetch() }
        }
    }

    @objc private func toggleCodex() {
        setCodexEnabled(!codexEnabled)
        if codexEnabled { triggerCodexFetch() }
    }

    @objc private func toggleAntigravity() {
        setAntigravityEnabled(!antigravityEnabled)
        if antigravityEnabled { triggerAntigravityFetch() }
    }

    @objc private func toggleIconClaude() {
        iconShowsClaude.toggle()
        UserDefaults.standard.set(iconShowsClaude, forKey: "iconShowsClaude")
        refreshUI()
    }

    @objc private func toggleIconCodex() {
        iconShowsCodex.toggle()
        UserDefaults.standard.set(iconShowsCodex, forKey: "iconShowsCodex")
        refreshUI()
    }

    @objc private func toggleIconAntigravity() {
        iconShowsAntigravity.toggle()
        UserDefaults.standard.set(iconShowsAntigravity, forKey: "iconShowsAntigravity")
        refreshUI()
    }

    // MARK: - Actions

    private func showError(provider: String, message: String, fetchedAt: TimeInterval, retry: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(provider) couldn’t refresh"
        alert.informativeText = message + (fetchedAt > 0 ? "\n\nShowing saved usage from \(fmtAgo(fetchedAt))." : "")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { retry() }
    }

    @objc private func refreshClicked() { refreshAll() }

    @objc private func wakeRefresh() { refreshAll() }

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
        panel?.close()
        guard loginWindow == nil else { loginWindow?.show(); return }
        loginWindow = LoginWindow(
            onSuccess: { [weak self] sessionKey, orgId in
                self?.claudeGeneration += 1
                saveSession(Session(sessionKey: sessionKey, orgId: orgId))
                self?.setClaudeEnabled(true)
                self?.authFailed = false
                self?.loginWindow = nil
                self?.triggerFetch()
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
        claudeError = nil
        authFailed = true
        lastFetched = 0
        setClaudeEnabled(false)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }

    @objc private func aboutClicked() {
        panel.close()
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
