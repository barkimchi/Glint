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

    /// The widget panel's current frame, so pins can dock under it.
    static var frame: NSRect? { panel?.frame }

    static func place(expanded: Bool, animate: Bool = false) {
        guard let p = panel else { return }
        (p.contentView as? EdgeWidgetView)?.expanded = expanded
        p.setFrame(frame(expanded: expanded), display: true, animate: animate)
        Pins.dockAll()
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

/// Widget button art: one distinct mark per action - white outlines with an amber focal point,
/// and the Claude logo for Go to Claude.
@MainActor
enum EdgeGlyph {
    // Palette: grey plate, white corners, orange-yellow marks.
    static let ink = NSColor.white
    static let paper = NSColor(srgbRed: 0x4A / 255, green: 0x4D / 255, blue: 0x52 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xFF / 255, green: 0xB2 / 255, blue: 0x1A / 255, alpha: 1)

    /// Action glyphs: one distinct mark per action. No shared capture brackets -
    /// they made the buttons hard to tell apart at a glance.
    static func image(_ a: HotkeyAction) -> NSImage {
        NSImage(size: NSSize(width: 36, height: 36), flipped: false) { _ in
            ink.setStroke()
            let w = NSBezierPath()
            w.lineWidth = 2.6; w.lineCapStyle = .round; w.lineJoinStyle = .round
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                w.move(to: NSPoint(x: x1, y: y1)); w.line(to: NSPoint(x: x2, y: y2))
            }
            func outline(_ r: NSRect, _ rad: CGFloat) {
                let p = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
                p.lineWidth = 2.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.stroke()
            }
            func chip(_ r: NSRect, _ rad: CGFloat) {
                NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
            }
            switch a {
            case .area: // dashed selection with an amber corner dot
                let d = NSBezierPath(roundedRect: NSRect(x: 9, y: 9, width: 18, height: 18), xRadius: 3, yRadius: 3)
                d.lineWidth = 2.6; d.lineCapStyle = .round
                d.setLineDash([4, 3], count: 2, phase: 0)
                d.stroke()
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: 24.6, y: 6.6, width: 4.8, height: 4.8)).fill()
            case .window:
                outline(NSRect(x: 9.5, y: 10.5, width: 17, height: 15), 2.5)
                red.setFill(); chip(NSRect(x: 12.5, y: 20.5, width: 11, height: 3), 1.5)
            case .fullscreen:
                outline(NSRect(x: 9, y: 11, width: 18, height: 14), 3)
                red.setFill(); chip(NSRect(x: 13, y: 15, width: 10, height: 6), 1.5)
            case .scroll:
                line(18, 12, 18, 24); w.stroke()
                red.setFill()
                let up = NSBezierPath()
                up.move(to: NSPoint(x: 18, y: 27)); up.line(to: NSPoint(x: 13.5, y: 20.5)); up.line(to: NSPoint(x: 22.5, y: 20.5)); up.close(); up.fill()
                let dn = NSBezierPath()
                dn.move(to: NSPoint(x: 18, y: 9)); dn.line(to: NSPoint(x: 13.5, y: 15.5)); dn.line(to: NSPoint(x: 22.5, y: 15.5)); dn.close(); dn.fill()
            case .page:
                outline(NSRect(x: 10.5, y: 9.5, width: 15, height: 17), 2)
                red.setFill()
                chip(NSRect(x: 14, y: 19.5, width: 8, height: 2.4), 1.2)
                chip(NSRect(x: 14, y: 15.5, width: 8, height: 2.4), 1.2)
                chip(NSRect(x: 14, y: 11.5, width: 5, height: 2.4), 1.2)
            case .ocr:
                let lens = NSBezierPath(ovalIn: NSRect(x: 9.5, y: 13.5, width: 12, height: 12))
                lens.lineWidth = 2.6; lens.stroke()
                w.lineWidth = 2.8; line(20, 15, 25.5, 9.5); w.stroke()
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.3, y: 17.3, width: 4.4, height: 4.4)).fill()
            case .claude:
                // Claude logo (simple-icons path, 24x24) scaled into the tile, y flipped.
                red.setFill()
                let cl = NSBezierPath()
                cl.move(to: NSPoint(x: 9.80, y: 13.55))
                cl.line(to: NSPoint(x: 15.11, y: 16.53))
                cl.line(to: NSPoint(x: 15.20, y: 16.79))
                cl.line(to: NSPoint(x: 15.11, y: 16.93))
                cl.line(to: NSPoint(x: 14.85, y: 16.93))
                cl.line(to: NSPoint(x: 13.96, y: 16.99))
                cl.line(to: NSPoint(x: 10.93, y: 17.07))
                cl.line(to: NSPoint(x: 8.30, y: 17.18))
                cl.line(to: NSPoint(x: 5.75, y: 17.31))
                cl.line(to: NSPoint(x: 5.11, y: 17.45))
                cl.line(to: NSPoint(x: 4.51, y: 18.24))
                cl.line(to: NSPoint(x: 4.57, y: 18.64))
                cl.line(to: NSPoint(x: 5.11, y: 19.00))
                cl.line(to: NSPoint(x: 5.88, y: 18.93))
                cl.line(to: NSPoint(x: 7.59, y: 18.82))
                cl.line(to: NSPoint(x: 10.15, y: 18.64))
                cl.line(to: NSPoint(x: 12.01, y: 18.53))
                cl.line(to: NSPoint(x: 14.76, y: 18.24))
                cl.line(to: NSPoint(x: 15.20, y: 18.24))
                cl.line(to: NSPoint(x: 15.26, y: 18.42))
                cl.line(to: NSPoint(x: 15.11, y: 18.53))
                cl.line(to: NSPoint(x: 14.99, y: 18.64))
                cl.line(to: NSPoint(x: 12.34, y: 20.43))
                cl.line(to: NSPoint(x: 9.48, y: 22.33))
                cl.line(to: NSPoint(x: 7.97, y: 23.43))
                cl.line(to: NSPoint(x: 7.16, y: 23.98))
                cl.line(to: NSPoint(x: 6.75, y: 24.50))
                cl.line(to: NSPoint(x: 6.57, y: 25.63))
                cl.line(to: NSPoint(x: 7.31, y: 26.45))
                cl.line(to: NSPoint(x: 8.30, y: 26.38))
                cl.line(to: NSPoint(x: 8.55, y: 26.31))
                cl.line(to: NSPoint(x: 9.56, y: 25.54))
                cl.line(to: NSPoint(x: 11.70, y: 23.88))
                cl.line(to: NSPoint(x: 14.50, y: 21.81))
                cl.line(to: NSPoint(x: 14.91, y: 21.47))
                cl.line(to: NSPoint(x: 15.08, y: 21.59))
                cl.line(to: NSPoint(x: 15.10, y: 21.67))
                cl.line(to: NSPoint(x: 14.91, y: 21.98))
                cl.line(to: NSPoint(x: 13.39, y: 24.73))
                cl.line(to: NSPoint(x: 11.76, y: 27.53))
                cl.line(to: NSPoint(x: 11.04, y: 28.69))
                cl.line(to: NSPoint(x: 10.85, y: 29.39))
                cl.curve(to: NSPoint(x: 10.73, y: 30.21), controlPoint1: NSPoint(x: 10.78, y: 29.68), controlPoint2: NSPoint(x: 10.73, y: 29.92))
                cl.line(to: NSPoint(x: 11.57, y: 31.35))
                cl.line(to: NSPoint(x: 12.04, y: 31.50))
                cl.line(to: NSPoint(x: 13.16, y: 31.35))
                cl.line(to: NSPoint(x: 13.63, y: 30.94))
                cl.line(to: NSPoint(x: 14.33, y: 29.35))
                cl.line(to: NSPoint(x: 15.45, y: 26.84))
                cl.line(to: NSPoint(x: 17.20, y: 23.43))
                cl.line(to: NSPoint(x: 17.71, y: 22.42))
                cl.line(to: NSPoint(x: 17.99, y: 21.49))
                cl.line(to: NSPoint(x: 18.09, y: 21.20))
                cl.line(to: NSPoint(x: 18.27, y: 21.20))
                cl.line(to: NSPoint(x: 18.27, y: 21.36))
                cl.line(to: NSPoint(x: 18.41, y: 23.28))
                cl.line(to: NSPoint(x: 18.68, y: 25.64))
                cl.line(to: NSPoint(x: 18.94, y: 28.67))
                cl.line(to: NSPoint(x: 19.02, y: 29.53))
                cl.line(to: NSPoint(x: 19.45, y: 30.55))
                cl.line(to: NSPoint(x: 20.29, y: 31.10))
                cl.line(to: NSPoint(x: 20.94, y: 30.79))
                cl.line(to: NSPoint(x: 21.48, y: 30.02))
                cl.line(to: NSPoint(x: 21.41, y: 29.52))
                cl.line(to: NSPoint(x: 21.09, y: 27.44))
                cl.line(to: NSPoint(x: 20.46, y: 24.17))
                cl.line(to: NSPoint(x: 20.05, y: 21.99))
                cl.line(to: NSPoint(x: 20.29, y: 21.99))
                cl.line(to: NSPoint(x: 20.56, y: 22.26))
                cl.line(to: NSPoint(x: 21.67, y: 23.73))
                cl.line(to: NSPoint(x: 23.53, y: 26.05))
                cl.line(to: NSPoint(x: 24.35, y: 26.97))
                cl.line(to: NSPoint(x: 25.30, y: 27.99))
                cl.line(to: NSPoint(x: 25.92, y: 28.47))
                cl.line(to: NSPoint(x: 27.08, y: 28.47))
                cl.line(to: NSPoint(x: 27.93, y: 27.20))
                cl.line(to: NSPoint(x: 27.55, y: 25.89))
                cl.line(to: NSPoint(x: 26.35, y: 24.38))
                cl.line(to: NSPoint(x: 25.36, y: 23.09))
                cl.line(to: NSPoint(x: 23.94, y: 21.18))
                cl.line(to: NSPoint(x: 23.05, y: 19.65))
                cl.line(to: NSPoint(x: 23.14, y: 19.53))
                cl.line(to: NSPoint(x: 23.35, y: 19.55))
                cl.line(to: NSPoint(x: 26.56, y: 20.23))
                cl.line(to: NSPoint(x: 28.29, y: 20.54))
                cl.line(to: NSPoint(x: 30.36, y: 20.90))
                cl.line(to: NSPoint(x: 31.30, y: 20.46))
                cl.line(to: NSPoint(x: 31.40, y: 20.02))
                cl.line(to: NSPoint(x: 31.03, y: 19.11))
                cl.line(to: NSPoint(x: 28.82, y: 18.56))
                cl.line(to: NSPoint(x: 26.22, y: 18.04))
                cl.line(to: NSPoint(x: 22.36, y: 17.13))
                cl.line(to: NSPoint(x: 22.31, y: 17.09))
                cl.line(to: NSPoint(x: 22.36, y: 17.03))
                cl.line(to: NSPoint(x: 24.11, y: 16.86))
                cl.line(to: NSPoint(x: 24.85, y: 16.82))
                cl.line(to: NSPoint(x: 26.67, y: 16.82))
                cl.line(to: NSPoint(x: 30.07, y: 16.57))
                cl.line(to: NSPoint(x: 30.96, y: 15.98))
                cl.line(to: NSPoint(x: 31.49, y: 15.26))
                cl.line(to: NSPoint(x: 31.40, y: 14.72))
                cl.line(to: NSPoint(x: 30.03, y: 14.02))
                cl.line(to: NSPoint(x: 28.19, y: 14.46))
                cl.line(to: NSPoint(x: 23.89, y: 15.48))
                cl.line(to: NSPoint(x: 22.41, y: 15.85))
                cl.line(to: NSPoint(x: 22.21, y: 15.85))
                cl.line(to: NSPoint(x: 22.21, y: 15.73))
                cl.line(to: NSPoint(x: 23.44, y: 14.53))
                cl.line(to: NSPoint(x: 25.69, y: 12.49))
                cl.line(to: NSPoint(x: 28.51, y: 9.87))
                cl.line(to: NSPoint(x: 28.66, y: 9.22))
                cl.line(to: NSPoint(x: 28.29, y: 8.71))
                cl.line(to: NSPoint(x: 27.91, y: 8.76))
                cl.line(to: NSPoint(x: 25.43, y: 10.63))
                cl.line(to: NSPoint(x: 24.48, y: 11.47))
                cl.line(to: NSPoint(x: 22.31, y: 13.29))
                cl.line(to: NSPoint(x: 22.17, y: 13.29))
                cl.line(to: NSPoint(x: 22.17, y: 13.10))
                cl.line(to: NSPoint(x: 22.67, y: 12.37))
                cl.line(to: NSPoint(x: 25.30, y: 8.41))
                cl.line(to: NSPoint(x: 25.44, y: 7.19))
                cl.line(to: NSPoint(x: 25.25, y: 6.79))
                cl.line(to: NSPoint(x: 24.56, y: 6.56))
                cl.line(to: NSPoint(x: 23.81, y: 6.69))
                cl.line(to: NSPoint(x: 22.27, y: 8.86))
                cl.line(to: NSPoint(x: 20.68, y: 11.30))
                cl.line(to: NSPoint(x: 19.39, y: 13.48))
                cl.line(to: NSPoint(x: 19.24, y: 13.39))
                cl.line(to: NSPoint(x: 18.48, y: 5.23))
                cl.line(to: NSPoint(x: 18.12, y: 4.81))
                cl.line(to: NSPoint(x: 17.30, y: 4.50))
                cl.line(to: NSPoint(x: 16.62, y: 5.02))
                cl.line(to: NSPoint(x: 16.26, y: 5.86))
                cl.line(to: NSPoint(x: 16.62, y: 7.52))
                cl.line(to: NSPoint(x: 17.06, y: 9.68))
                cl.line(to: NSPoint(x: 17.41, y: 11.41))
                cl.line(to: NSPoint(x: 17.73, y: 13.54))
                cl.line(to: NSPoint(x: 17.92, y: 14.25))
                cl.line(to: NSPoint(x: 17.91, y: 14.30))
                cl.line(to: NSPoint(x: 17.75, y: 14.28))
                cl.line(to: NSPoint(x: 16.14, y: 12.07))
                cl.line(to: NSPoint(x: 13.69, y: 8.76))
                cl.line(to: NSPoint(x: 11.75, y: 6.68))
                cl.line(to: NSPoint(x: 11.29, y: 6.49))
                cl.line(to: NSPoint(x: 10.48, y: 6.91))
                cl.line(to: NSPoint(x: 10.55, y: 7.66))
                cl.line(to: NSPoint(x: 11.01, y: 8.32))
                cl.line(to: NSPoint(x: 13.69, y: 11.73))
                cl.line(to: NSPoint(x: 15.31, y: 13.85))
                cl.line(to: NSPoint(x: 16.35, y: 15.07))
                cl.line(to: NSPoint(x: 16.35, y: 15.25))
                cl.line(to: NSPoint(x: 16.29, y: 15.25))
                cl.line(to: NSPoint(x: 9.15, y: 10.62))
                cl.line(to: NSPoint(x: 7.88, y: 10.46))
                cl.line(to: NSPoint(x: 7.34, y: 10.97))
                cl.line(to: NSPoint(x: 7.41, y: 11.81))
                cl.line(to: NSPoint(x: 7.67, y: 12.08))
                cl.line(to: NSPoint(x: 9.81, y: 13.56))
                cl.close()
                cl.fill()
            case .record:
                let ring = NSBezierPath(ovalIn: NSRect(x: 9.5, y: 9.5, width: 17, height: 17))
                ring.lineWidth = 2.4; ring.stroke()
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 10, height: 10)).fill()
            }
            return true
        }
    }

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
