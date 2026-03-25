import SwiftUI
import AppKit

@main
struct TokenioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
    private var loginPrompted = false
    private var loginWindow: LoginWindow?
    private var activityToken: NSObjectProtocol?

    private let refreshInterval: TimeInterval = 300 // 5 min

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prevent App Nap
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Usage refresh timers"
        )

        // Enable launch at login on first run
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            if !LaunchAtLogin.isEnabled { LaunchAtLogin.toggle() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon(makeIcon(sUsage: 0, sTime: 0, wUsage: 0, wTime: 0))
        buildMenu()

        // Initial fetch
        let session = loadSession()
        let token = loadOAuthToken()
        if session == nil && token == nil {
            showLogin()
        } else {
            triggerFetch()
        }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.triggerFetch()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateRelativeTime()
        }
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

        menu.addItem(.separator())

        updatedItem = NSMenuItem(title: "↻  Updated —", action: #selector(refreshClicked), keyEquivalent: "")
        updatedItem.target = self
        menu.addItem(updatedItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Log in to Claude…", action: #selector(loginClicked), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        logoutItem = NSMenuItem(title: "Log out", action: #selector(logoutClicked), keyEquivalent: "")
        logoutItem.target = self
        menu.addItem(logoutItem)

        updateAuthVisibility()

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let quitItem = NSMenuItem(title: "Quit Tokenio", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Icon

    private func applyIcon(_ img: NSImage) {
        statusItem.button?.image = img
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    // MARK: - Fetch

    private func triggerFetch() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global().async { [weak self] in
            let result = fetchUsage()
            DispatchQueue.main.async { self?.handleResult(result) }
        }
    }

    private func handleResult(_ result: UsageResult) {
        loading = false

        switch result {
        case .success(let d):
            loginPrompted = false

            var sU = d.sessionPct
            let sR = d.sessionReset
            if sR > 0, sR < Date().timeIntervalSince1970 { sU = 0 }
            let sT = elapsedPct(resetTs: sR, windowSecs: 5 * 3600)

            let wU = d.weeklyPct
            let wR = d.weeklyReset
            let wT = elapsedPct(resetTs: wR, windowSecs: 7 * 24 * 3600)

            applyIcon(makeIcon(sUsage: sU, sTime: sT, wUsage: wU, wTime: wT))

            let snU = d.sonnetPct
            let snR = d.sonnetReset
            let snT = elapsedPct(resetTs: snR, windowSecs: 7 * 24 * 3600)

            let oU = d.overagePct
            let oR = d.overageReset
            let oT = elapsedPct(resetTs: oR, windowSecs: 30 * 24 * 3600)

            sessionView.setData(value: "\(Int(sU))%", usageFrac: sU / 100, timeFrac: sT / 100, resetStr: "Resets in \(fmtReset(sR))")
            weeklyView.setData(value: "\(Int(wU))%", usageFrac: wU / 100, timeFrac: wT / 100, resetStr: "Resets in \(fmtReset(wR))")
            sonnetView.setData(value: "\(Int(snU))%", usageFrac: snU / 100, timeFrac: snT / 100, resetStr: "Resets in \(fmtReset(snR))")

            let suffix = d.extraEnabled ? "$\(String(format: "%.2f", d.extraDollars))" : ""
            extraView.setTitle("Extra usage", suffix: suffix)
            extraView.setData(value: "\(Int(oU))%", usageFrac: oU / 100, timeFrac: oT / 100, resetStr: "Resets in \(fmtReset(oR))")

            lastFetched = Date().timeIntervalSince1970
            updatedItem.title = "↻  Updated just now"
            updateAuthVisibility()

        case .needsLogin:
            updatedItem.title = "⚠  Session expired"
            updateAuthVisibility()
            if !loginPrompted {
                loginPrompted = true
                showLogin()
            }

        case .error(let msg):
            updatedItem.title = "⚠  \(msg)"
        }
    }

    // MARK: - Auth UI

    private func updateAuthVisibility() {
        let hasSession = loadSession() != nil
        let hasAnyAuth = hasSession || loadOAuthToken() != nil
        loginItem.isHidden = hasAnyAuth
        logoutItem.isHidden = !hasSession
    }

    private func showLogin() {
        loginWindow = LoginWindow(
            onSuccess: { [weak self] _, _ in
                self?.loginWindow = nil
                self?.triggerFetch()
            },
            onCancel: { [weak self] in
                self?.loginWindow = nil
            }
        )
        loginWindow?.show()
    }

    // MARK: - Relative time

    private func updateRelativeTime() {
        guard lastFetched > 0 else { return }
        updatedItem.title = "↻  Updated \(fmtAgo(lastFetched))"
    }

    // MARK: - Actions

    @objc private func refreshClicked() { triggerFetch() }

    @objc private func loginClicked() { showLogin() }

    @objc private func logoutClicked() {
        clearSession()
        updateAuthVisibility()
        updatedItem.title = "⚠  Logged out"
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}

// MARK: - Launch at Login (SMAppService, macOS 13+)

import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // silently fail
        }
    }
}
