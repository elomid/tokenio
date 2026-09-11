// Appended to a temporary copy of TokenioApp.swift by scripts/test.sh so these
// checks can exercise private UI state without expanding the production API.
extension AppDelegate {
    static func runMenuChecks() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        delegate.claudeEnabled = false
        delegate.codexEnabled = false
        delegate.buildMenu()
        let menu = delegate.statusItem.menu!
        func check(_ claude: Bool, _ codex: Bool) {
            delegate.claudeEnabled = claude
            delegate.codexEnabled = codex
            delegate.updateAuthVisibility()
            precondition(delegate.claudeItems.first!.isHidden == !claude)
            precondition(delegate.codexItems.first!.isHidden == !codex)
            precondition(delegate.providerSeparator.isHidden == !(claude && codex))
            precondition(delegate.emptyItem.isHidden == (claude || codex))
            precondition(delegate.loginItem.isHidden == !claude)
            precondition(delegate.logoutItem.isHidden)
            menu.update()
            precondition(menu.size.width <= 280, "Unexpected menu width: \(menu.size.width)")
        }
        check(false, false)
        check(true, false)
        check(false, true)
        check(true, true)
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
                let icon = makeIcon(sUsage: 16, sTime: 30, wUsage: 6, wTime: 15, showClaude: claude, showCodex: codex)
                precondition(icon.size.width > 0 && icon.tiffRepresentation != nil)
            }
        }
        print("PASS: neither/Claude-only/Codex-only/both; optional metrics; bounded menu width with long errors; saved/live states; icons")
        NSStatusBar.system.removeStatusItem(delegate.statusItem)
    }
}
