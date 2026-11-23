// Appended to a temporary copy of TokenioApp.swift by scripts/test.sh so these
// checks can exercise private UI state without expanding the production API.
extension AppDelegate {
    static func runMenuChecks() {
        _ = NSApplication.shared
        let now = Date().timeIntervalSince1970
        let delegate = AppDelegate()
        delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        delegate.claudeEnabled = false
        delegate.codexEnabled = false
        delegate.antigravityEnabled = false
        delegate.codexUsage = nil
        delegate.antigravityUsage = nil
        delegate.mode = .used
        delegate.buildPanel()
        let columns = delegate.panel.view.columns

        // Every provider combination shows exactly the enabled providers, in order.
        for claude in [false, true] { for codex in [false, true] { for antigravity in [false, true] {
            delegate.claudeEnabled = claude; delegate.codexEnabled = codex; delegate.antigravityEnabled = antigravity
            delegate.refreshUI()
            let expected = [claude ? "claude" : nil, codex ? "codex" : nil, antigravity ? "antigravity" : nil].compactMap { $0 }
            precondition(columns.groups.map(\.id) == expected, "\(columns.groups.map(\.id)) != \(expected)")
            precondition(delegate.panel.view.fittingSize.width >= 232, "Panel keeps a minimum width")
            let icon = makeStatusIcon(groups: delegate.iconGroups(), mode: delegate.mode)
            precondition(icon.size.width > 0 && icon.size.height > 0, "Icon renders non-empty")
        } } }
        delegate.claudeEnabled = false; delegate.codexEnabled = false; delegate.antigravityEnabled = false
        delegate.refreshUI()
        precondition(columns.groups.isEmpty && columns.accessibilitySummary().contains("Choose a provider"))

        // Signed out, loading and failed providers offer one action instead of columns.
        delegate.claudeEnabled = true; delegate.codexEnabled = true; delegate.antigravityEnabled = true
        delegate.authFailed = true
        delegate.codexError = "Codex is not installed"
        delegate.antigravityLoading = true
        delegate.refreshUI()
        precondition(columns.groups[0].status == .action("Sign in…"))
        precondition(columns.groups[1].status == .action("Connect Codex…") && columns.groups[1].columns.isEmpty)
        precondition(columns.groups[2].status == .loading)
        precondition(delegate.footerText() == "Refreshing…")
        delegate.antigravityLoading = false

        // Signed in with saved numbers: Claude's columns, Fable and Extra when present.
        testSessionValue = Session(sessionKey: "test", orgId: "test")
        delegate.authFailed = false
        delegate.claudeSnapshot = UsageData(sessionPct: 3, sessionReset: now + 3 * 3600, weeklyPct: 31, weeklyReset: now + 3 * 86400,
                                            fablePct: 49, fableReset: now + 3 * 86400, fableEnabled: true,
                                            overagePct: 20, overageReset: now + 10 * 86400, extraDollars: 12.5, extraEnabled: true)
        delegate.lastFetched = now - 240
        delegate.codexError = "Network down"
        delegate.codexUsage = CodexUsage(usedPercent: 12, resetsAt: now - 60, windowDurationMins: 10080, fetchedAt: now - 600)
        delegate.antigravityUsage = AntigravityUsage(limits: [
            .init(title: "5-hour - Gemini", usedPercent: 13, resetsAt: now + 4 * 3600, windowSecs: 18000),
            .init(title: "Weekly - Gemini", usedPercent: 4, resetsAt: now + 6 * 86400, windowSecs: 604800),
            .init(title: "Weekly - Gemini 3 Flash", usedPercent: 0, resetsAt: now + 6 * 86400, windowSecs: 604800),
        ], fetchedAt: now - 120)
        delegate.refreshUI()
        let claude = columns.groups[0]
        precondition(claude.status == .ok && claude.columns.map(\.label) == ["5h", "Week", "Fable", "Extra"])
        precondition(claude.columns[3].toolTip == "Extra usage: $12.50 spent")
        precondition(abs(claude.columns[1].value.used - 0.31) < 0.001)
        precondition(claude.columns[1].value.elapsed > 0.5 && claude.columns[1].value.elapsed < 0.6)
        // A refresh failure keeps saved numbers and flags the provider.
        precondition(columns.groups[1].status == .warning("Network down"))
        // A window that already reset reads as stale until fresh numbers arrive.
        precondition(columns.groups[1].columns[0].value.stale)
        precondition(columns.groups[1].columns[0].value.percentText(.used) == "—")
        precondition(columns.groups[2].columns.map(\.label) == ["5h", "Week", "Flash"])
        precondition(delegate.footerText() == "Updated 10 mins ago", delegate.footerText())
        precondition(columns.accessibilitySummary().contains("Claude: 5h 3% used, resets in"))

        // Eight columns (Claude with Extra usage) stay within a sensible menu width.
        delegate.codexError = nil
        delegate.refreshUI()
        let width = delegate.panel.view.fittingSize.width
        precondition(width > 300 && width <= 480, "Unexpected panel width: \(width)")
        print("Panel size with eight columns: \(delegate.panel.view.fittingSize)")

        // Left inverts fill and mark together.
        let value = BarValue(used: 0.3, elapsed: 0.6)
        precondition(value.display(.used) == (0.3, 0.6) && value.display(.left).fill == 0.7)
        precondition(abs(value.display(.left).mark - 0.4) < 0.0001 && value.percentText(.left) == "70%")
        delegate.setMode(.left)
        precondition(columns.mode == .left)
        delegate.setMode(.used)

        // Menu bar icon: Claude session + weekly + Fable, Codex, Antigravity's primary 5h + weekly limits.
        precondition(delegate.iconGroups().map(\.count) == [3, 1, 2])
        delegate.iconShowsCodex = false
        precondition(delegate.iconGroups().map(\.count) == [3, 2], "Hidden from the icon")
        delegate.antigravityEnabled = false
        precondition(delegate.iconGroups().map(\.count) == [3], "Disabled providers never reach the icon")
        delegate.iconShowsCodex = true; delegate.antigravityEnabled = true

        // The ••• menu carries every setting, and Quit keeps ⌘Q.
        delegate.codexEnabled = false
        let more = delegate.buildMoreMenu()
        let titles = more.items.map(\.title)
        for title in ["Providers", "Menu Bar Icon", "Show", "Log out of Claude", "Launch at Login", "About Tokenio", "Quit Tokenio"] {
            precondition(titles.contains(title), "Missing \(title) in \(titles)")
        }
        precondition(more.items.first { $0.title == "Quit Tokenio" }?.keyEquivalent == "q")
        let iconMenu = more.items.first { $0.title == "Menu Bar Icon" }!.submenu!
        precondition(iconMenu.items.first { $0.title == "Codex" }?.isEnabled == false, "Can't show a disabled provider in the icon")
        precondition(more.items.first { $0.title == "Show" }!.submenu!.items.first { $0.title == "Used" }?.state == .on)

        precondition(fmtAgo(now - 323 * 3600) == "13 days ago" && fmtAgo(now - 5 * 3600) == "5h ago")

        // Codex columns are named by their window length.
        precondition([300.0, 1440, 10080, 43200, 20160].map { AppDelegate.windowLabel(minutes: $0) } == ["5h", "Day", "Week", "Month", "14d"])

        // Label rules for Antigravity: the first group by window, others by model.
        let labels = AppDelegate.antigravityLabels(["5-hour - Gemini", "Weekly - Gemini", "Weekly - Imagen", "5-hour - Veo 3", "Weekly - Veo 3", "Odd"])
        precondition(labels == ["5h", "Week", "Imagen", "Veo 3 5h", "Veo 3 Week", "Odd"], "\(labels)")
        precondition(AppDelegate.antigravityLabels(["5-hour - Gemini", "Weekly - Gemini 3 Flash"]) == ["5h", "Flash"])

        print("PASS: all 8 provider combinations; empty, sign-in, connect and loading states; Claude/Codex/Antigravity columns; stale windows; refresh warnings; footer time; used/left; icon groups; ••• menu")
        NSStatusBar.system.removeStatusItem(delegate.statusItem)
    }
}
