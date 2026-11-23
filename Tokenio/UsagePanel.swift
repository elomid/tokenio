import AppKit

// MARK: - Model

struct PanelColumn: Equatable {
    var label: String
    var value: BarValue
    var resetsAt: TimeInterval
    var toolTip: String? = nil
}

struct PanelGroup: Equatable {
    enum Status: Equatable {
        case ok
        /// Saved numbers are shown, but the last refresh failed.
        case warning(String)
        /// No numbers to show; the title is a clickable action.
        case action(String)
        case loading
    }

    var id: String
    var name: String
    var columns: [PanelColumn]
    var status: Status = .ok
}

// MARK: - Columns

private let colW: CGFloat = 45
private let colGap: CGFloat = 4
private let groupPad: CGFloat = 10
private let groupGap: CGFloat = 7
private let sidePad: CGFloat = 8
private let cardTop: CGFloat = 8
private let cardCorner: CGFloat = 9
private let barW: CGFloat = 14
private let barH: CGFloat = 82
private let barCorner: CGFloat = 4
private let markWing: CGFloat = 2.5
private let nameY: CGFloat = cardTop + 10
private let valueY: CGFloat = nameY + 26
private let barY: CGFloat = valueY + 21
private let labelY: CGFloat = barY + barH + 10
private let resetY: CGFloat = labelY + 15
private let cardBottom: CGFloat = resetY + 23
private let columnsH: CGFloat = cardBottom
private let minPanelW: CGFloat = 232

/// Vertical bars grouped by provider: percentage, bar with time mark, label, reset.
final class UsageColumnsView: NSView, NSViewToolTipOwner {
    var groups: [PanelGroup] = [] { didSet { relayout() } }
    var mode: DisplayMode = .used { didSet { needsDisplay = true } }
    /// Called with a group id when its warning or action is clicked; nil id means the empty state.
    var onGroupClick: ((String?) -> Void)?

    private var hotspots: [(rect: NSRect, id: String?)] = []
    private var toolTips: [(rect: NSRect, text: String)] = []
    private var hoveredHotspot: Int? {
        didSet { if hoveredHotspot != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    private let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private let actionFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private func actionTitle(_ g: PanelGroup) -> String? {
        switch g.status {
        case .action(let title): return title
        case .loading where g.columns.isEmpty: return "Loading…"
        default: return nil
        }
    }

    private func warningMessage(_ g: PanelGroup) -> String? {
        if case .warning(let msg) = g.status { return msg }
        return nil
    }

    private func groupWidth(_ g: PanelGroup) -> CGFloat {
        let header = textWidth(g.name, nameFont) + (warningMessage(g) != nil ? 15 : 0)
        let content: CGFloat
        if let title = actionTitle(g) {
            content = max(96, textWidth(title, actionFont) + 24)
        } else {
            content = CGFloat(g.columns.count) * colW + CGFloat(max(0, g.columns.count - 1)) * colGap
        }
        return max(header, content) + groupPad * 2
    }

    private func totalGroupsWidth() -> CGFloat {
        guard !groups.isEmpty else { return 0 }
        return groups.reduce(0) { $0 + groupWidth($1) } + CGFloat(groups.count - 1) * groupGap
    }

    override var intrinsicContentSize: NSSize {
        let inner = totalGroupsWidth()
        return NSSize(width: max(minPanelW, inner + sidePad * 2), height: groups.isEmpty ? 64 : columnsH)
    }

    override func layout() {
        super.layout()
        rebuildInteractiveRegions()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func relayout() {
        hoveredHotspot = nil
        invalidateIntrinsicContentSize()
        rebuildInteractiveRegions()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilitySummary())
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func rebuildInteractiveRegions() {
        hotspots = []
        toolTips = []
        removeAllToolTips()

        let w = bounds.width > 0 ? bounds.width : intrinsicContentSize.width
        if groups.isEmpty {
            let title = "Choose a provider to get started"
            let bw = textWidth(title, actionFont) + 24
            hotspots.append((NSRect(x: (w - bw) / 2, y: 18, width: bw, height: 28), nil))
            return
        }

        let total = totalGroupsWidth()
        var x = (w - total) / 2
        for (gi, g) in groups.enumerated() {
            let gw = groupWidth(g)
            if let msg = warningMessage(g) {
                let nameW = textWidth(g.name, nameFont) + 15
                let nameX = x + (gw - nameW) / 2
                let rect = NSRect(x: nameX - 5, y: nameY - 3, width: nameW + 10, height: 20)
                hotspots.append((rect, g.id))
                toolTips.append((rect, "\(msg) — click for details"))
            }
            if let title = actionTitle(g), g.status != .loading {
                let bw = max(96, textWidth(title, actionFont) + 24)
                hotspots.append((NSRect(x: x + (gw - bw) / 2, y: barY + barH / 2 - 14, width: bw, height: 28), g.id))
            } else if actionTitle(g) == nil {
                let cw = CGFloat(g.columns.count) * colW + CGFloat(max(0, g.columns.count - 1)) * colGap
                var cx = x + (gw - cw) / 2
                for c in g.columns {
                    if let tip = c.toolTip {
                        toolTips.append((NSRect(x: cx, y: valueY - 2, width: colW, height: cardBottom - valueY - 6), tip))
                    }
                    cx += colW + colGap
                }
            }
            x += gw + (gi < groups.count - 1 ? groupGap : 0)
        }

        for (index, entry) in toolTips.enumerated() {
            addToolTip(entry.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        let idx = Int(bitPattern: data) - 1
        guard idx >= 0, idx < toolTips.count else { return "" }
        return toolTips[idx].text
    }

    func accessibilitySummary() -> String {
        if groups.isEmpty { return "No providers. Choose a provider to get started." }
        return groups.map { g in
            if let title = actionTitle(g) { return "\(g.name): \(title)" }
            let cols = g.columns.map { c in
                c.value.stale ? "\(c.label) reset, waiting for new numbers"
                    : "\(c.label) \(c.value.percentText(mode)) \(mode == .used ? "used" : "left"), resets in \(fmtReset(c.resetsAt))"
            }
            return "\(g.name): " + cols.joined(separator: ", ")
        }.joined(separator: ". ")
    }

    override func draw(_ dirtyRect: NSRect) {
        if hotspots.isEmpty && !groups.isEmpty { rebuildInteractiveRegions() }
        guard let ctx = NSGraphicsContext.current else { return }

        if groups.isEmpty {
            let title = "Choose a provider to get started"
            let w = textWidth(title, actionFont) + 24
            let rect = NSRect(x: (bounds.width - w) / 2, y: 18, width: w, height: 28)
            drawAction(title, in: rect, hovered: hoveredHotspot == 0)
            return
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tileFill = isDark ? NSColor.white.withAlphaComponent(0.055) : NSColor.white.withAlphaComponent(0.48)
        let tileBorder = isDark ? NSColor.white.withAlphaComponent(0.095) : NSColor.black.withAlphaComponent(0.08)

        let total = totalGroupsWidth()
        var x = (bounds.width - total) / 2
        for (gi, g) in groups.enumerated() {
            let gw = groupWidth(g)

            // Tactile Control Center tile container per provider.
            let tileRect = NSRect(x: round(x), y: cardTop, width: round(gw), height: cardBottom - cardTop)
            let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cardCorner, yRadius: cardCorner)
            tileFill.setFill()
            tilePath.fill()
            let strokePath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 0.25, dy: 0.25), xRadius: cardCorner - 0.25, yRadius: cardCorner - 0.25)
            strokePath.lineWidth = 0.5
            tileBorder.setStroke()
            strokePath.stroke()

            let hasWarning = warningMessage(g) != nil
            let nameW = textWidth(g.name, nameFont) + (hasWarning ? 15 : 0)
            let nameX = x + (gw - nameW) / 2

            if hasWarning, let idx = hotspots.firstIndex(where: { $0.id == g.id }), hoveredHotspot == idx {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: hotspots[idx].rect, xRadius: 5, yRadius: 5).fill()
            }

            draw(g.name, font: nameFont, color: NSColor.labelColor.withAlphaComponent(0.90), at: NSPoint(x: nameX, y: nameY))
            if hasWarning, let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Refresh failed") {
                let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
                    .applying(.init(paletteColors: [NSColor.systemOrange.withAlphaComponent(0.92)]))
                let img = symbol.withSymbolConfiguration(config) ?? symbol
                img.draw(in: NSRect(x: nameX + nameW - 11.5, y: nameY + 2.5, width: 11.5, height: 10.5))
            }

            if let title = actionTitle(g) {
                let w = max(96, textWidth(title, actionFont) + 24)
                let rect = NSRect(x: x + (gw - w) / 2, y: barY + barH / 2 - 14, width: w, height: 28)
                let isHovered = hotspots.firstIndex(where: { $0.id == g.id }) == hoveredHotspot
                drawAction(title, in: rect, enabled: g.status != .loading, hovered: isHovered)
            } else {
                let cw = CGFloat(g.columns.count) * colW + CGFloat(max(0, g.columns.count - 1)) * colGap
                var cx = x + (gw - cw) / 2
                for c in g.columns {
                    drawColumn(c, x: cx, ctx: ctx)
                    cx += colW + colGap
                }
            }
            x += gw + (gi < groups.count - 1 ? groupGap : 0)
        }
    }

    private func drawColumn(_ c: PanelColumn, x: CGFloat, ctx: NSGraphicsContext) {
        let dim = c.value.stale
        let isIdleZero = !dim && mode == .used && c.value.used <= 0.004
        let center = x + colW / 2

        let valueColor: NSColor = dim
            ? NSColor.labelColor.withAlphaComponent(0.45)
            : (isIdleZero ? NSColor.labelColor.withAlphaComponent(0.55) : .labelColor)
        drawCentered(c.value.percentText(mode), font: valueFont, color: valueColor, center: center, y: valueY)

        let rect = NSRect(x: round(center - barW / 2), y: barY, width: barW, height: barH)
        let track = NSBezierPath(roundedRect: rect, xRadius: barCorner, yRadius: barCorner)

        // Quiet recessed track with a whisper-thin inner rim.
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        track.fill()
        let innerRim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: barCorner - 0.25, yRadius: barCorner - 0.25)
        innerRim.lineWidth = 0.5
        NSColor.labelColor.withAlphaComponent(0.06).setStroke()
        innerRim.stroke()

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (fill, mark) = c.value.display(mode)
        let fillH: CGFloat = (!dim && fill > 0) ? max(3.0, barH * CGFloat(fill)) : 0
        if fillH > 0 {
            ctx.saveGraphicsState()
            track.setClip()
            c.value.tint.panelColor(isDark: isDark).setFill()
            NSRect(x: rect.minX, y: rect.maxY - fillH, width: barW, height: fillH).fill()
            ctx.restoreGraphicsState()
        }

        if !dim {
            // Clamp inside the rounded corners so 0–2% and 98–100% never clip or slice a cap.
            let rawY = rect.maxY - barH * CGFloat(mark)
            let my = max(rect.minY + 2.5, min(rect.maxY - 2.5, rawY))
            let fillTop = rect.maxY - fillH
            let wingColor = NSColor.labelColor.withAlphaComponent(0.52)

            if fillH > 0 && my >= fillTop + 1.5 {
                // Mark sits inside the solid fill: crisp internal clear slit + quiet outer flanking ticks.
                ctx.saveGraphicsState()
                track.setClip()
                ctx.compositingOperation = .clear
                NSRect(x: rect.minX, y: my - 0.75, width: barW, height: 1.5).fill()
                ctx.restoreGraphicsState()

                wingColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX - markWing, y: my - 0.75, width: markWing - 0.5, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
                NSBezierPath(roundedRect: NSRect(x: rect.maxX + 0.5, y: my - 0.75, width: markWing - 0.5, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            } else if fillH > 0 && my >= fillTop - 1.5 {
                // Mark sits right at the fill meniscus: optional thin separation seam only on taller fills,
                // then a crisp hairline so low 3–4% fills are never erased.
                if fillH >= 7 {
                    ctx.saveGraphicsState()
                    track.setClip()
                    ctx.compositingOperation = .clear
                    NSRect(x: rect.minX, y: my + 0.75, width: barW, height: 1.0).fill()
                    ctx.restoreGraphicsState()
                }
                NSColor.labelColor.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX - markWing, y: my - 0.75, width: barW + markWing * 2, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            } else {
                // Mark sits in the empty track: one quiet continuous precision hairline.
                wingColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX - markWing, y: my - 0.75, width: barW + markWing * 2, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            }
        }

        let labelColor: NSColor = dim
            ? NSColor.labelColor.withAlphaComponent(0.45)
            : (isIdleZero ? NSColor.labelColor.withAlphaComponent(0.58) : NSColor.labelColor.withAlphaComponent(0.84))
        let resetColor: NSColor = NSColor.labelColor.withAlphaComponent(isIdleZero || dim ? 0.50 : 0.66)
        drawCentered(c.label, font: labelFont, color: labelColor, center: center, y: labelY)
        drawCentered(dim ? "reset" : fmtReset(c.resetsAt), font: resetFont, color: resetColor, center: center, y: resetY)
    }

    private func drawAction(_ title: String, in rect: NSRect, enabled: Bool = true, hovered: Bool = false) {
        if enabled {
            NSColor.labelColor.withAlphaComponent(hovered ? 0.13 : 0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        drawCentered(title, font: actionFont, color: enabled ? .labelColor : .secondaryLabelColor, center: rect.midX, y: rect.minY + 6.5)
    }

    private func draw(_ s: String, font: NSFont, color: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCentered(_ s: String, font: NSFont, color: NSColor, center: CGFloat, y: CGFloat) {
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        draw(s, font: font, color: color, at: NSPoint(x: center - w / 2, y: y))
    }

    override func resetCursorRects() {
        for (rect, _) in hotspots { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredHotspot = hotspots.firstIndex(where: { $0.rect.contains(p) })
    }

    func resetHover() {
        hoveredHotspot = nil
    }

    override func mouseExited(with event: NSEvent) {
        hoveredHotspot = nil
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hotspots.first(where: { $0.rect.contains(p) }) { onGroupClick?(hit.id) }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Optically centered footer button

final class FooterButton: NSButton {
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        font = .systemFont(ofSize: 11.5, weight: .regular)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    override var image: NSImage? {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private var iconSize: NSSize {
        guard let image else { return .zero }
        return image.size
    }

    private var textSize: NSSize {
        guard !title.isEmpty, let font else { return .zero }
        return (title as NSString).size(withAttributes: [.font: font])
    }

    override var intrinsicContentSize: NSSize {
        let h: CGFloat = 24
        if title.isEmpty {
            return NSSize(width: 26, height: h)
        }
        // Slightly tighter left pad on the icon side so the visible glyph balances the text side.
        let leftPad: CGFloat = image == nil ? 8 : 7
        let rightPad: CGFloat = 9
        let gap: CGFloat = image == nil ? 0 : 5
        return NSSize(width: ceil(leftPad + iconSize.width + gap + textSize.width + rightPad), height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    func resetHover() {
        hovered = false
        pressed = false
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        let inside = trackClick(startingWith: event)
        pressed = false
        if inside, let action {
            sendAction(action, to: target)
        }
    }

    private func trackClick(startingWith event: NSEvent) -> Bool {
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(next.locationInWindow, from: nil)
            inside = bounds.contains(p)
            pressed = inside
            if next.type == .leftMouseUp { return inside }
        }
        return inside
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || pressed {
            let alpha: CGFloat = pressed ? 0.14 : 0.08
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        let ink = NSColor.labelColor.withAlphaComponent(hovered || pressed ? 0.90 : 0.68)

        if title.isEmpty {
            if let image {
                let sz = image.size
                let r = NSRect(x: round((bounds.width - sz.width) / 2),
                               y: round((bounds.height - sz.height) / 2),
                               width: sz.width, height: sz.height)
                drawTinted(image, in: r, color: ink)
            }
            return
        }

        let leftPad: CGFloat = image == nil ? 8 : 7
        var x = leftPad
        if let image {
            let sz = image.size
            // SF Symbol arrow.clockwise carries top alignment slack; nudge up optically onto the text's cap-center spine.
            let r = NSRect(x: x, y: round((bounds.height - sz.height) / 2) - 1.5, width: sz.width, height: sz.height)
            drawTinted(image, in: r, color: ink)
            x += sz.width + 5
        }
        if let font {
            let ts = textSize
            // Center on cap-height optically so ascenders/descenders don't push the label low.
            let y = round((bounds.height - ts.height) / 2) - 0.5
            (title as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: font,
                .foregroundColor: ink,
            ])
        }
    }

    private func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Panel content

final class UsagePanelView: NSView {
    let columns = UsageColumnsView()
    let refreshButton: NSButton = FooterButton()
    let moreButton: NSButton = FooterButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium))
        refreshButton.toolTip = "Refresh all providers"
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        moreButton.setAccessibilityLabel("More")
        for v in [columns, refreshButton, moreButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: topAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            refreshButton.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 7),
            refreshButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            refreshButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            moreButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshButton.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func resetHover() {
        columns.resetHover()
        (refreshButton as? FooterButton)?.resetHover()
        (moreButton as? FooterButton)?.resetHover()
    }
}

// MARK: - Window

/// A borderless visual effect container that maintains a native continuous corner rim
/// across light and dark appearance switches.
private final class PanelEffectView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .menu
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.09)).cgColor
    }
}

/// A borderless panel that can take key status without activating the app,
/// so Esc and outside clicks can close it like a menu.
final class UsagePanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class UsagePanelController: NSObject, NSWindowDelegate {
    let view = UsagePanelView()
    private let window: UsagePanelWindow
    private let effect = PanelEffectView()
    private weak var statusItem: NSStatusItem?
    private var outsideMonitor: Any?
    private var lastClosed: TimeInterval = 0
    var onClose: (() -> Void)?

    var isVisible: Bool { window.isVisible }

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        window = UsagePanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: effect.topAnchor),
            view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        window.contentView = effect
    }

    func toggle() {
        if window.isVisible { close() }
        // The click that closed the panel by taking key status shouldn't reopen it.
        else if ProcessInfo.processInfo.systemUptime - lastClosed > 0.3 { show() }
    }

    func show() {
        resize()
        window.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        view.resetHover()
        lastClosed = ProcessInfo.processInfo.systemUptime
        statusItem?.button?.highlight(false)
        if let monitor = outsideMonitor { NSEvent.removeMonitor(monitor) }
        outsideMonitor = nil
        onClose?()
    }

    /// Size to content and center under the status item, keeping the panel on screen.
    func resize() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            window.setContentSize(size)
            return
        }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = round(anchor.midX - size.width / 2)
        x = min(x, screen.maxX - size.width - 8)
        x = max(x, screen.minX + 8)
        let frame = NSRect(x: x, y: anchor.minY - size.height - 5, width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}
