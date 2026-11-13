import AppKit

/// A small bar that hugs a screen edge. Collapsed it is a thin tab; hover and it opens into one
/// button per capture action. Drag the grip to slide it along the border or onto another edge or display.
@MainActor
enum EdgeWidget {
    enum Edge: String { case left, right, top, bottom }

    private static var panel: NSPanel?
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "edge.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "edge.enabled"); newValue ? show() : hide() }
    }
    static var edge: Edge {
        get { Edge(rawValue: d.string(forKey: "edge.side") ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: "edge.side") }
    }
    /// Where the widget's center sits along its edge, 0 to 1.
    static var position: CGFloat {
        get { d.object(forKey: "edge.position") as? CGFloat ?? 0.5 }
        set { d.set(Double(newValue), forKey: "edge.position") }
    }
    static var screen: NSScreen {
        get {
            let n = d.integer(forKey: "edge.screen")
            return NSScreen.screens.indices.contains(n) ? NSScreen.screens[n] : (NSScreen.main ?? NSScreen.screens[0])
        }
        set { d.set(NSScreen.screens.firstIndex(of: newValue) ?? 0, forKey: "edge.screen") }
    }

    static func restore() { if enabled { show() } }

    static func show() {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = EdgeWidgetView()
            panel = p
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { place(expanded: false) }
            }
        }
        place(expanded: false)
        panel?.orderFrontRegardless()
    }

    static func hide() { panel?.orderOut(nil) }
    static var isVisible: Bool { panel?.isVisible ?? false }

    static let thickness: (collapsed: CGFloat, expanded: CGFloat) = (8, 54)
    static let grip: CGFloat = 20, cell: CGFloat = 46

    static func frame(expanded: Bool) -> NSRect {
        let vf = screen.visibleFrame
        let len: CGFloat = expanded ? grip + cell * CGFloat(HotkeyAction.allCases.count) + 6 : 110
        let t = expanded ? thickness.expanded : thickness.collapsed
        func along(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            min(max(lo + position * (hi - lo) - len / 2, lo), hi - len)
        }
        switch edge {
        case .left: return NSRect(x: vf.minX, y: along(vf.minY, vf.maxY), width: t, height: len)
        case .right: return NSRect(x: vf.maxX - t, y: along(vf.minY, vf.maxY), width: t, height: len)
        case .top: return NSRect(x: along(vf.minX, vf.maxX), y: vf.maxY - t, width: len, height: t)
        case .bottom: return NSRect(x: along(vf.minX, vf.maxX), y: vf.minY, width: len, height: t)
        }
    }

    static func place(expanded: Bool, animate: Bool = false) {
        guard let p = panel else { return }
        (p.contentView as? EdgeWidgetView)?.expanded = expanded
        p.setFrame(frame(expanded: expanded), display: true, animate: animate)
    }

    /// Snap to whichever edge of whichever display the pointer is nearest.
    static func drag(to m: NSPoint) {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        let vf = s.visibleFrame
        let dist: [(Edge, CGFloat)] = [(.left, m.x - vf.minX), (.right, vf.maxX - m.x),
                                       (.bottom, m.y - vf.minY), (.top, vf.maxY - m.y)]
        guard let e = dist.min(by: { $0.1 < $1.1 })?.0 else { return }
        screen = s
        edge = e
        let f = (e == .left || e == .right) ? (m.y - vf.minY) / vf.height : (m.x - vf.minX) / vf.width
        position = min(max(f, 0), 1)
        place(expanded: true)
    }
}

final class EdgeWidgetView: NSView {
    var expanded = false { didSet { needsLayout = true; needsDisplay = true } }
    private var buttons: [NSButton] = []
    private var dragging = false
    private var moved = false
    private var pinned = false // clicked open: stays open until clicked again
    private var collapseWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        for (i, a) in HotkeyAction.allCases.enumerated() {
            let b = NSButton(image: EdgeGlyph.image(a), target: self, action: #selector(fire(_:)))
            b.setAccessibilityLabel(a.title)
            b.tag = i
            b.isBordered = false
            b.imageScaling = .scaleNone
            addSubview(b)
            buttons.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var vertical: Bool { EdgeWidget.edge == .left || EdgeWidget.edge == .right }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        let c = EdgeWidget.cell, g = EdgeWidget.grip, t = EdgeWidget.thickness.expanded
        for (i, b) in buttons.enumerated() {
            b.isHidden = !expanded
            let a = HotkeyAction.allCases[i]
            let key = HotkeySettings.shared.shortcut(a)?.display
            b.toolTip = key.map { "\(a.title)  \($0)" } ?? a.title
            let off = g + CGFloat(i) * c
            // Vertical bars read top to bottom, so the grip sits at the top.
            b.frame = vertical ? NSRect(x: (t - c) / 2, y: bounds.height - off - c, width: c, height: c)
                               : NSRect(x: off, y: (t - c) / 2, width: c, height: c)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard expanded else { // collapsed: a slim ink tab with a red tick, visible on light and dark
            EdgeGlyph.paper.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            EdgeGlyph.red.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: vertical ? 2.5 : 30, dy: vertical ? 30 : 2.5), xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        EdgeGlyph.paper.setFill(); plate.fill()
        EdgeGlyph.ink.withAlphaComponent(0.18).setStroke(); plate.lineWidth = 1; plate.stroke()
        // Grip dots
        EdgeGlyph.ink.withAlphaComponent(0.4).setFill()
        for i in 0..<3 {
            let o = CGFloat(i - 1) * 5
            let p = vertical ? NSPoint(x: bounds.midX + o, y: bounds.maxY - EdgeWidget.grip / 2 - 1)
                             : NSPoint(x: EdgeWidget.grip / 2 + 1, y: bounds.midY + o)
            NSBezierPath(ovalIn: NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
        }
    }

    @objc private func fire(_ b: NSButton) {
        let a = HotkeyAction.allCases[b.tag]
        pinned = false
        EdgeWidget.place(expanded: false)
        // Give the bar a moment to collapse so it is never caught mid-animation in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { AppController.shared.perform(a) }
    }

    override func mouseEntered(with event: NSEvent) {
        collapseWork?.cancel()
        if !expanded { EdgeWidget.place(expanded: true) }
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging, !pinned else { return }
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging, !self.pinned, let win = self.window,
                  !NSMouseInRect(NSEvent.mouseLocation, win.frame, false) else { return }
            EdgeWidget.place(expanded: false)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    override func mouseDown(with event: NSEvent) { dragging = true; moved = false }
    override func mouseDragged(with event: NSEvent) { moved = true; EdgeWidget.drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if !moved { // a plain click on the tab or grip pins the bar open, or closes it again
            pinned.toggle()
            collapseWork?.cancel()
            EdgeWidget.place(expanded: pinned)
            return
        }
        if let win = window, !NSMouseInRect(NSEvent.mouseLocation, win.frame, false) { EdgeWidget.place(expanded: false) }
    }
}

/// Widget button art in the style of the "Crop" icon concept: ink selection corners framing one red mark per action.
@MainActor
enum EdgeGlyph {
    // Palette: grey plate, white corners, orange-yellow marks.
    static let ink = NSColor.white
    static let paper = NSColor(srgbRed: 0x4A / 255, green: 0x4D / 255, blue: 0x52 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xFF / 255, green: 0xB2 / 255, blue: 0x1A / 255, alpha: 1)

    static func image(_ a: HotkeyAction) -> NSImage {
        NSImage(size: NSSize(width: 36, height: 36), flipped: false) { _ in
            // Corner brackets
            let c = NSBezierPath()
            c.lineWidth = 2.8; c.lineCapStyle = .round; c.lineJoinStyle = .round
            let lo: CGFloat = 4, hi: CGFloat = 32, arm: CGFloat = 7
            for (x, y, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (hi, hi, -1.0, -1.0), (lo, hi, 1.0, -1.0)] {
                c.move(to: NSPoint(x: x + arm * dx, y: y)); c.line(to: NSPoint(x: x, y: y)); c.line(to: NSPoint(x: x, y: y + arm * dy))
            }
            ink.setStroke(); c.stroke()

            red.setFill(); red.setStroke()
            let m = NSBezierPath()
            m.lineWidth = 2.6; m.lineCapStyle = .round; m.lineJoinStyle = .round
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                m.move(to: NSPoint(x: x1, y: y1)); m.line(to: NSPoint(x: x2, y: y2))
            }
            switch a {
            case .area: // the glint
                let k: CGFloat = 8, q: CGFloat = 1.6
                let pts = [NSPoint(x: 18, y: 18 + k), NSPoint(x: 18 + k, y: 18), NSPoint(x: 18, y: 18 - k), NSPoint(x: 18 - k, y: 18)]
                let g = NSBezierPath(); g.move(to: pts[3])
                for (i, p) in pts.enumerated() {
                    let sx: CGFloat = (i == 0 || i == 3) ? -1 : 1, sy: CGFloat = (i < 2) ? 1 : -1
                    g.curve(to: p, controlPoint1: NSPoint(x: 18 + sx * q, y: 18 + sy * q), controlPoint2: NSPoint(x: 18 + sx * q, y: 18 + sy * q))
                }
                g.close(); g.fill()
            case .window:
                m.appendRoundedRect(NSRect(x: 10.5, y: 11.5, width: 15, height: 13), xRadius: 2.5, yRadius: 2.5)
                line(10.5, 20, 25.5, 20); m.stroke()
            case .fullscreen:
                NSBezierPath(roundedRect: NSRect(x: 10, y: 11, width: 16, height: 14), xRadius: 3, yRadius: 3).fill()
            case .scroll:
                line(18, 10.5, 18, 25.5)
                line(14, 21.5, 18, 25.5); line(22, 21.5, 18, 25.5)
                line(14, 14.5, 18, 10.5); line(22, 14.5, 18, 10.5); m.stroke()
            case .page:
                line(11.5, 24, 24.5, 24); line(11.5, 18, 24.5, 18); line(11.5, 12, 19, 12); m.stroke()
            case .ocr: // a magnifier: inspect the screen and lift the text off it
                m.appendOval(in: NSRect(x: 10.5, y: 14, width: 11.5, height: 11.5))
                line(20.6, 15.4, 25.5, 10.5); m.stroke()
            case .claude: // a chat bubble
                m.appendRoundedRect(NSRect(x: 10, y: 14, width: 16, height: 11.5), xRadius: 3.5, yRadius: 3.5)
                m.move(to: NSPoint(x: 14, y: 14)); m.line(to: NSPoint(x: 13, y: 10)); m.line(to: NSPoint(x: 18, y: 14))
                m.stroke()
            case .record:
                NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 13, height: 13)).fill()
            }
            return true
        }
    }
}

extension EdgeGlyph {
    /// Menu bar version of the app icon: the glint with its dot, as a template image so macOS tints it.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c: CGFloat = 8.5, k: CGFloat = 7.5, q: CGFloat = 1.3
            let pts = [NSPoint(x: c, y: c + k), NSPoint(x: c + k, y: c), NSPoint(x: c, y: c - k), NSPoint(x: c - k, y: c)]
            let g = NSBezierPath(); g.move(to: pts[3])
            for (i, p) in pts.enumerated() {
                let sx: CGFloat = (i == 0 || i == 3) ? -1 : 1, sy: CGFloat = (i < 2) ? 1 : -1
                let cp = NSPoint(x: c + sx * q, y: c + sy * q)
                g.curve(to: p, controlPoint1: cp, controlPoint2: cp)
            }
            g.close()
            NSColor.black.setFill(); g.fill()
            NSBezierPath(ovalIn: NSRect(x: 13.2, y: 13.2, width: 3.6, height: 3.6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
