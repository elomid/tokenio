import AppKit

/// How bars read: filling up with usage, or draining with what's left.
/// Left inverts the fill and the time mark so both drain together.
enum DisplayMode: String {
    case used, left

    static var current: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .used
    }
}

/// Optional subtle tint carried by a bar across both the panel and the menu bar icon.
enum BarTint: Equatable {
    case neutral
    case fable
    case antigravity

    func panelColor(isDark: Bool) -> NSColor {
        switch self {
        case .neutral:
            return NSColor.labelColor.withAlphaComponent(0.84)
        case .fable:
            return isDark
                ? NSColor(red: 0.36, green: 0.64, blue: 1.00, alpha: 0.92)
                : NSColor(red: 0.16, green: 0.44, blue: 0.88, alpha: 0.92)
        case .antigravity:
            return isDark
                ? NSColor(red: 0.20, green: 0.82, blue: 0.74, alpha: 0.92)
                : NSColor(red: 0.06, green: 0.58, blue: 0.52, alpha: 0.92)
        }
    }

    func iconColor(isDark: Bool) -> NSColor {
        switch self {
        case .neutral:
            return NSColor(white: isDark ? 1.0 : 0.0, alpha: 0.92)
        case .fable:
            return isDark
                ? NSColor(red: 0.38, green: 0.66, blue: 1.00, alpha: 0.96)
                : NSColor(red: 0.14, green: 0.42, blue: 0.88, alpha: 0.96)
        case .antigravity:
            return isDark
                ? NSColor(red: 0.20, green: 0.84, blue: 0.75, alpha: 0.96)
                : NSColor(red: 0.05, green: 0.56, blue: 0.50, alpha: 0.96)
        }
    }
}

/// One limit as a bar: usage and elapsed time, both 0–1 from the start of the window.
struct BarValue: Equatable {
    var used: Double
    var elapsed: Double
    /// The window has reset but fresh numbers haven't arrived yet.
    var stale: Bool = false
    var tint: BarTint = .neutral

    static func make(usedPercent: Double, resetsAt: TimeInterval, windowSecs: TimeInterval?,
                     tint: BarTint = .neutral,
                     now: TimeInterval = Date().timeIntervalSince1970) -> BarValue {
        if resetsAt > 0, resetsAt <= now { return BarValue(used: 0, elapsed: 0, stale: true, tint: tint) }
        let elapsed = windowSecs.map { elapsedPct(resetTs: resetsAt, windowSecs: $0) / 100 } ?? 0
        return BarValue(used: max(0, min(1, usedPercent / 100)), elapsed: elapsed, tint: tint)
    }

    /// Fill fraction and mark position as drawn in the given mode.
    func display(_ mode: DisplayMode) -> (fill: Double, mark: Double) {
        if stale { return mode == .used ? (0, 0) : (1, 1) }
        return mode == .used ? (used, elapsed) : (1 - used, 1 - elapsed)
    }

    func percentText(_ mode: DisplayMode) -> String {
        stale ? "—" : "\(Int((display(mode).fill * 100).rounded()))%"
    }
}

// MARK: - Menu bar icon

private let iconCanvasH: CGFloat = 18
private let iconH: CGFloat = 18
private let iconBarW: CGFloat = 4
private let iconCorner: CGFloat = 1.5
private let iconGap: CGFloat = 2
private let iconGroupGap: CGFloat = 5

/// Vertical bars grouped by provider. Uses template rendering when all bars are
/// monochrome, or explicit light/dark colors when provider tints are active.
func makeStatusIcon(groups: [[BarValue]], mode: DisplayMode, isDark: Bool = true) -> NSImage {
    let groups = groups.filter { !$0.isEmpty }
    guard !groups.isEmpty else {
        let image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Choose a provider") ?? NSImage()
        image.isTemplate = true
        return image
    }
    let hasTint = groups.contains { group in group.contains { $0.tint != .neutral } }
    let baseWhite: CGFloat = hasTint ? (isDark ? 1.0 : 0.0) : 0.0

    let count = groups.reduce(0) { $0 + $1.count }
    let width = CGFloat(count) * iconBarW + CGFloat(count - groups.count) * iconGap
        + CGFloat(groups.count - 1) * iconGroupGap + 2
    let image = NSImage(size: NSSize(width: ceil(width), height: iconCanvasH), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current else { return false }
        var x: CGFloat = 1
        let y0 = (iconCanvasH - iconH) / 2
        for (gi, group) in groups.enumerated() {
            for (i, bar) in group.enumerated() {
                let rect = NSRect(x: x, y: y0, width: iconBarW, height: iconH)
                let track = NSBezierPath(roundedRect: rect, xRadius: iconCorner, yRadius: iconCorner)
                NSColor(white: baseWhite, alpha: 0.24).setFill()
                track.fill()

                let (fill, mark) = bar.display(mode)
                let fillH: CGFloat = fill > 0 ? max(2.0, iconH * CGFloat(fill)) : 0
                if fillH > 0 {
                    ctx.saveGraphicsState()
                    track.setClip()
                    let fillColor = hasTint ? bar.tint.iconColor(isDark: isDark) : NSColor(white: 0.0, alpha: 0.92)
                    fillColor.setFill()
                    NSRect(x: x, y: y0, width: iconBarW, height: fillH).fill()
                    ctx.restoreGraphicsState()
                }

                if !bar.stale {
                    // Clamp inside the rounded caps so the mark never slices a cap flat.
                    let rawY = y0 + iconH * CGFloat(mark)
                    let my = max(y0 + 2.0, min(y0 + iconH - 2.0, rawY))
                    let fillTop = y0 + fillH

                    ctx.saveGraphicsState()
                    track.setClip()
                    if fillH > 0 && my <= fillTop - 0.7 {
                        // Inside the fill: crisp 1.25pt clear slit clearly shows usage has passed time.
                        ctx.compositingOperation = .clear
                        NSRect(x: x, y: my - 0.625, width: iconBarW, height: 1.25).fill()
                    } else {
                        // Above/at the fill: quieter 1pt hairline never reads as a detached chunk of fill.
                        NSColor(white: baseWhite, alpha: 0.56).setFill()
                        NSRect(x: x, y: my - 0.5, width: iconBarW, height: 1.0).fill()
                    }
                    ctx.restoreGraphicsState()
                }
                x += iconBarW + (i < group.count - 1 ? iconGap : 0)
            }
            if gi < groups.count - 1 { x += iconGroupGap }
        }
        return true
    }
    image.isTemplate = !hasTint
    return image
}
