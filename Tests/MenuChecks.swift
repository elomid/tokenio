// Appended to a temporary copy of TokenioApp.swift by scripts/test.sh so these
// checks can exercise private UI state without expanding the production API.
extension AppDelegate {
    static func runMenuChecks() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        delegate.claudeEnabled = false
        delegate.codexEnabled = false
        delegate.antigravityEnabled = false
        delegate.antigravityUsage = nil
        delegate.buildMenu()
        let menu = delegate.statusItem.menu!
        func check(_ claude: Bool, _ codex: Bool, _ antigravity: Bool = false) {
            delegate.claudeEnabled = claude
            delegate.codexEnabled = codex
            delegate.antigravityEnabled = antigravity
            delegate.updateAuthVisibility()
            precondition(delegate.claudeItems.first!.isHidden == !claude)
            precondition(delegate.codexItems.first!.isHidden == !codex)
            precondition(delegate.antigravityHeader.isHidden == !antigravity)
            precondition(delegate.antigravityMetricItems.allSatisfy { $0.isHidden == !antigravity })
            precondition(delegate.providerSeparator.isHidden == !(claude && codex))
            precondition(delegate.antigravitySeparator.isHidden == !(antigravity && (claude || codex)))
            precondition(delegate.emptyItem.isHidden == (claude || codex || antigravity))
            precondition(delegate.iconAntigravityToggle.isEnabled == antigravity)
            precondition(delegate.loginItem.isHidden == !claude)
            precondition(delegate.logoutItem.isHidden)
            menu.update()
            precondition(menu.size.width <= 280, "Unexpected menu width: \(menu.size.width)")
        }
        // Antigravity rows follow the response and keep their place before the status item.
        delegate.antigravityUsage = AntigravityUsage(limits: [
            .init(title: "5-hour - Gemini", usedPercent: 40, resetsAt: Date().timeIntervalSince1970 + 3600, windowSecs: 18000),
            .init(title: "Weekly - Gemini", usedPercent: 10, resetsAt: Date().timeIntervalSince1970 + 86400, windowSecs: 604800),
            .init(title: "Weekly - Claude and GPT", usedPercent: 90, resetsAt: Date().timeIntervalSince1970 - 60, windowSecs: 604800),
        ])
        check(true, false, true)
        delegate.updateRelativeTime()
        precondition(delegate.antigravityMetricItems.count == 3)
        let first = menu.index(of: delegate.antigravityMetricItems[0])
        precondition(first == menu.index(of: delegate.antigravityHeader) + 1)
        precondition(menu.index(of: delegate.antigravityUpdatedItem) == first + 3)
        precondition(delegate.antigravityUpdatedItem.title.hasPrefix("Updated"))
        precondition(delegate.antigravityUsed(delegate.antigravityUsage!.limits[2]) == 0, "Expired windows read as unused")
        let itemCount = menu.items.count
        delegate.updateRelativeTime()
        precondition(menu.items.count == itemCount, "Unchanged limits must not rebuild rows")
        delegate.antigravityUsage = nil
        delegate.antigravityError = "Not signed in"
        delegate.updateRelativeTime()
        precondition(delegate.antigravityMetricItems.count == 1 && menu.items.count == itemCount - 2)
        precondition(delegate.antigravityUpdatedItem.title == "Connect Antigravity — details…")
        delegate.antigravityError = nil
        // Menu bar icon choices apply only to enabled providers.
        delegate.claudeEnabled = true; delegate.codexEnabled = true; delegate.antigravityEnabled = true
        delegate.iconShowsCodex = false
        precondition(delegate.iconClaude && !delegate.iconCodex && delegate.iconAntigravity)
        delegate.antigravityEnabled = false
        precondition(!delegate.iconAntigravity)
        delegate.iconShowsCodex = true
        for claude in [false, true] { for codex in [false, true] { for antigravity in [false, true] {
            check(claude, codex, antigravity)
        } } }
        delegate.claudeSnapshot = UsageData(fableEnabled: true, extraEnabled: true)
        delegate.updateAuthVisibility()
        precondition(!delegate.fableItem.isHidden && !delegate.extraItem.isHidden)
        check(false, true)
        precondition(delegate.fableItem.isHidden && delegate.extraItem.isHidden)
        delegate.codexUsage = CodexUsage(usedPercent: 18, resetsAt: Date().timeIntervalSince1970 + 3600, windowDurationMins: 10080)
        delegate.codexError = String(repeating: "An unusually long connection error. ", count: 100)
        delegate.updateRelativeTime()
        menu.update()
        precondition(menu.size.width <= 280)
        precondition(abs(delegate.codexView.frame.width - menu.size.width) <= 16,
                     "Metric view should fill menu width")
        print("Menu width: \(menu.size.width); metric width: \(delegate.codexView.frame.width)")
        precondition(delegate.codexUpdatedItem.title == "Saved usage — details…")
        precondition(delegate.codexUpdatedItem.toolTip!.contains("Showing saved usage"))
        delegate.codexUsage = nil
        delegate.updateRelativeTime()
        precondition(delegate.codexUpdatedItem.title == "Connect Codex — details…")
        delegate.codexError = nil
        delegate.codexUsage = CodexUsage(usedPercent: 18, resetsAt: 1900000000, windowDurationMins: 10080)
        delegate.updateRelativeTime()
        precondition(delegate.codexUpdatedItem.toolTip == nil)
        precondition(delegate.codexUpdatedItem.title.hasPrefix("Updated"))
        for claude in [false, true] {
            for codex in [false, true] {
                for antigravity in [false, true] {
                    let icon = makeIcon(sUsage: 16, sTime: 30, wUsage: 6, wTime: 15, showFable: true, showClaude: claude,
                                        showCodex: codex, showAntigravity: antigravity, aUsage: 40, aTime: 20)
                    precondition(icon.size.width > 0 && icon.tiffRepresentation != nil)
                }
            }
        }
        print("PASS: all 8 provider combinations; dynamic Antigravity rows; icon provider choices; optional metrics; bounded menu width with long errors; saved/live states; icons")
        NSStatusBar.system.removeStatusItem(delegate.statusItem)
    }
}
