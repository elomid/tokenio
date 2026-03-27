import AppKit

// MARK: - Visual constants

private let iconW: CGFloat = 36
private let iconH: CGFloat = 22
private let barW: CGFloat = 31
private let barH: CGFloat = 6
private let barX0: CGFloat = (iconW - barW) / 2
private let sessionY: CGFloat = 13   // top bar (bottom-left origin)
private let weeklyY: CGFloat = 3     // bottom bar (4px gap between bars)
private let barCorner: CGFloat = 2.5
private let iconBgAlpha: CGFloat = 0.35

let menuBarH: CGFloat = 7
let menuBarCorner: CGFloat = 2.5

private let colorNormal: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.25, 0.85, 0.35, 1.0)  // green
private let colorWarn:   (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0,  0.45, 0.10, 1.0)  // orange (≥90%)
private let colorCrit:   (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0,  0.25, 0.20, 1.0)  // red (100%)

// MARK: - Color logic

private func lerp(_ c1: (CGFloat, CGFloat, CGFloat, CGFloat),
                  _ c2: (CGFloat, CGFloat, CGFloat, CGFloat),
                  _ t: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let t = max(0, min(1, t))
    return (c1.0 + (c2.0 - c1.0) * t,
            c1.1 + (c2.1 - c1.1) * t,
            c1.2 + (c2.2 - c1.2) * t,
            c1.3 + (c2.3 - c1.3) * t)
}

func usageColor(usageFrac: Double) -> NSColor {
    let c: (CGFloat, CGFloat, CGFloat, CGFloat)
    if usageFrac >= 1.0 {
        c = colorCrit
    } else if usageFrac >= 0.9 {
        c = lerp(colorWarn, colorCrit, (usageFrac - 0.9) / 0.1)
    } else {
        c = colorNormal
    }
    return NSColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
}

// MARK: - Bar drawing (shared by icon + menu views)

func drawBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
             corner: CGFloat, fillFrac: Double, tickFrac: Double,
             bgAlpha: CGFloat) {
    let trackRect = NSRect(x: x, y: y, width: w, height: h)
    let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: corner, yRadius: corner)

    NSColor(white: 1.0, alpha: bgAlpha).setFill()
    trackPath.fill()

    guard let ctx = NSGraphicsContext.current else { return }

    let fw = max(0, min(CGFloat(fillFrac), 1.0)) * w
    if fw > 0 {
        ctx.saveGraphicsState()
        trackPath.setClip()
        usageColor(usageFrac: fillFrac).setFill()
        NSRect(x: x, y: y, width: fw, height: h).fill()
        ctx.restoreGraphicsState()
    }

    // Tick (transparent notch)
    let tx = x + CGFloat(tickFrac) * w
    ctx.saveGraphicsState()
    trackPath.setClip()
    ctx.compositingOperation = .clear
    NSRect(x: tx - 0.75, y: y, width: 1.5, height: h).fill()
    ctx.restoreGraphicsState()
}

// MARK: - Menu bar icon

func drawBarMonochrome(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                       corner: CGFloat, fillFrac: Double, tickFrac: Double,
                       bgAlpha: CGFloat, isDark: Bool) {
    let trackRect = NSRect(x: x, y: y, width: w, height: h)
    let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: corner, yRadius: corner)

    let baseWhite: CGFloat = isDark ? 1.0 : 0.0
    NSColor(white: baseWhite, alpha: bgAlpha).setFill()
    trackPath.fill()

    guard let ctx = NSGraphicsContext.current else { return }

    let fw = max(0, min(CGFloat(fillFrac), 1.0)) * w
    if fw > 0 {
        ctx.saveGraphicsState()
        trackPath.setClip()
        let fillColor = fillFrac >= 0.9
            ? NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 1.0)
            : NSColor(white: baseWhite, alpha: 0.75)
        fillColor.setFill()
        NSRect(x: x, y: y, width: fw, height: h).fill()
        ctx.restoreGraphicsState()
    }

    let tx = x + CGFloat(tickFrac) * w
    ctx.saveGraphicsState()
    trackPath.setClip()
    ctx.compositingOperation = .clear
    NSRect(x: tx - 0.75, y: y, width: 1.5, height: h).fill()
    ctx.restoreGraphicsState()
}

func makeIcon(sUsage: Double, sTime: Double, wUsage: Double, wTime: Double,
              isDark: Bool = true) -> NSImage {
    let img = NSImage(size: NSSize(width: iconW, height: iconH), flipped: false) { _ in
        drawBarMonochrome(x: barX0, y: sessionY, w: barW, h: barH,
                          corner: barCorner, fillFrac: sUsage / 100, tickFrac: sTime / 100,
                          bgAlpha: iconBgAlpha, isDark: isDark)
        drawBarMonochrome(x: barX0, y: weeklyY, w: barW, h: barH,
                          corner: barCorner, fillFrac: wUsage / 100, tickFrac: wTime / 100,
                          bgAlpha: iconBgAlpha, isDark: isDark)
        return true
    }
    img.isTemplate = false
    return img
}

func makeDisconnectedIcon() -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Disconnected")?
        .withSymbolConfiguration(config)
    let img = symbol ?? NSImage()
    img.isTemplate = true
    return img
}
