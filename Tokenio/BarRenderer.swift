import AppKit

// MARK: - Visual constants

let iconW: CGFloat = 36
let iconH: CGFloat = 22
let barW: CGFloat = 31
let barH: CGFloat = 6
let barX0: CGFloat = (iconW - barW) / 2
let sessionY: CGFloat = 13   // top bar (bottom-left origin)
let weeklyY: CGFloat = 3     // bottom bar (4px gap between bars)
let barCorner: CGFloat = 2.5
let iconBgAlpha: CGFloat = 0.35

let menuBarH: CGFloat = 7
let menuBarCorner: CGFloat = 2.5

let colorUnder: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.25, 0.85, 0.35, 1.0)
let colorOn:    (CGFloat, CGFloat, CGFloat, CGFloat) = (0.95, 0.85, 0.25, 1.0)
let colorOver:  (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0,  0.45, 0.10, 1.0)

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

func paceColor(usageFrac: Double, timeFrac: Double) -> NSColor {
    let effectiveTime = max(timeFrac, 0.15)
    let ratio = effectiveTime > 0 ? usageFrac / effectiveTime : 0

    let c: (CGFloat, CGFloat, CGFloat, CGFloat)
    if ratio < 0.7 {
        c = colorUnder
    } else if ratio < 1.0 {
        c = lerp(colorUnder, colorOn, (ratio - 0.7) / 0.3)
    } else if ratio < 1.5 {
        c = lerp(colorOn, colorOver, (ratio - 1.0) / 0.5)
    } else {
        c = colorOver
    }
    return NSColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
}

// MARK: - Bar drawing (shared by icon + menu views)

func drawBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
             corner: CGFloat, fillFrac: Double, tickFrac: Double,
             bgAlpha: CGFloat) {
    let trackRect = NSRect(x: x, y: y, width: w, height: h)
    let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: corner, yRadius: corner)

    // Track background
    NSColor(white: 1.0, alpha: bgAlpha).setFill()
    trackPath.fill()

    guard let ctx = NSGraphicsContext.current else { return }

    // Fill
    let fw = max(0, min(CGFloat(fillFrac), 1.0)) * w
    if fw > 0 {
        ctx.saveGraphicsState()
        trackPath.setClip()
        paceColor(usageFrac: fillFrac, timeFrac: tickFrac).setFill()
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
        let fillColor = fillFrac >= 0.9
            ? NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 0.75)
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

func makeIcon(sUsage: Double, sTime: Double, wUsage: Double, wTime: Double) -> NSImage {
    let img = NSImage(size: NSSize(width: iconW, height: iconH))
    img.lockFocus()
    drawBarMonochrome(x: barX0, y: sessionY, w: barW, h: barH,
                      corner: barCorner, fillFrac: sUsage / 100, tickFrac: sTime / 100,
                      bgAlpha: iconBgAlpha)
    drawBarMonochrome(x: barX0, y: weeklyY, w: barW, h: barH,
                      corner: barCorner, fillFrac: wUsage / 100, tickFrac: wTime / 100,
                      bgAlpha: iconBgAlpha)
    img.unlockFocus()
    img.isTemplate = false
    return img
}
