import AppKit

private let menuW: CGFloat = 250
private let menuPad: CGFloat = 24
private let viewH: CGFloat = 72

class MetricMenuView: NSView {
    private var title: String
    private var titleSuffix: String = ""
    private var value: String = "—"
    private var usageFrac: Double = 0
    private var timeFrac: Double = 0
    private var resetText: String = "—"

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: menuW, height: viewH))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setTitle(_ title: String, suffix: String = "") {
        self.title = title
        self.titleSuffix = suffix
        needsDisplay = true
    }

    func setData(value: String, usageFrac: Double, timeFrac: Double, resetStr: String) {
        self.value = value
        self.usageFrac = usageFrac
        self.timeFrac = timeFrac
        self.resetText = resetStr
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let fVal = NSFont.systemFont(ofSize: 13, weight: .regular)
        let fReset = NSFont.systemFont(ofSize: 11)
        let cLabel = NSColor.labelColor
        let cSec = NSColor.secondaryLabelColor

        let titleStr = NSAttributedString(string: title, attributes: [
            .font: fTitle, .foregroundColor: cLabel
        ])
        titleStr.draw(at: NSPoint(x: menuPad, y: 14))

        if !titleSuffix.isEmpty {
            let sfx = NSAttributedString(string: " \(titleSuffix)", attributes: [
                .font: fVal, .foregroundColor: cSec
            ])
            sfx.draw(at: NSPoint(x: menuPad + titleStr.size().width, y: 14))
        }

        let valStr = NSAttributedString(string: value, attributes: [
            .font: fVal, .foregroundColor: cSec
        ])
        valStr.draw(at: NSPoint(x: menuW - menuPad - valStr.size().width, y: 14))

        let bx = menuPad
        let bw = menuW - 2 * menuPad
        let by: CGFloat = 36
        drawBar(x: bx, y: by, w: bw, h: menuBarH,
                corner: menuBarCorner, fillFrac: usageFrac, tickFrac: timeFrac,
                bgAlpha: 0.30)

        let resetStr = NSAttributedString(string: resetText, attributes: [
            .font: fReset, .foregroundColor: NSColor.secondaryLabelColor
        ])
        resetStr.draw(at: NSPoint(x: menuPad, y: by + menuBarH + 6))
    }
}

