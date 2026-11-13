import AppKit
import ApplicationServices

/// Middle mouse button opens a ring of the capture actions at the pointer.
/// With Accessibility access the click is swallowed (so it does not also close a browser tab);
/// without it we can only listen, and the click still reaches the app underneath.
@MainActor
enum MiddleClick {
    private static var tap: CFMachPort?
    private static var monitor: Any?

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ring.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ring.enabled"); newValue ? start(prompt: true) : stop() }
    }

    static func start(prompt: Bool = false) {
        stop()
        guard enabled else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async { MainActor.assumeIsolated { MiddleClick.reenable() } }
                    return Unmanaged.passUnretained(event)
                }
                guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return Unmanaged.passUnretained(event) }
                if type == .otherMouseDown {
                    DispatchQueue.main.async { MainActor.assumeIsolated { ActionRing.toggle() } }
                }
                return nil // swallow both the press and the release
            }
            if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: cb, userInfo: nil) {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
                CGEvent.tapEnable(tap: t, enable: true)
                tap = t
                return
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { e in
            if e.buttonNumber == 2 { MainActor.assumeIsolated { ActionRing.toggle() } }
        }
    }

    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }
}

@MainActor
enum ActionRing {
    private static var panel: NSPanel?
    private static var outside: Any?
    static let cols = 4, tile: CGFloat = 52, gap: CGFloat = 8, tipSpace: CGFloat = 30
    static var size: NSSize {
        let rows = CGFloat((HotkeyAction.allCases.count + cols - 1) / cols)
        return NSSize(width: CGFloat(cols) * tile + CGFloat(cols - 1) * gap,
                      height: rows * tile + (rows - 1) * gap + tipSpace * 2)
    }

    static func toggle() { panel == nil ? show() : close() }

    static func show() {
        guard SelectionSession.active == nil else { return }
        let m = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        let size = self.size
        var o = NSPoint(x: m.x - size.width / 2, y: m.y - size.height / 2)
        if let f = scr?.frame {
            o.x = min(max(o.x, f.minX + 4), f.maxX - size.width - 4)
            o.y = min(max(o.y, f.minY + 4), f.maxY - size.height - 4)
        }
        let p = NSPanel(contentRect: NSRect(origin: o, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = RingView(frame: NSRect(origin: .zero, size: size))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    static func close() {
        panel?.orderOut(nil); panel = nil
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
    }

    static func fire(_ a: HotkeyAction) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { AppController.shared.perform(a) }
    }
}

private final class RingButton: NSButton {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class RingView: NSView {
    private var hot: Int? { didSet { needsDisplay = true } }
    private var centers: [NSPoint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let all = HotkeyAction.allCases
        let cols = ActionRing.cols, rows = Int(ceil(Double(all.count) / Double(cols)))
        let step = ActionRing.tile + ActionRing.gap
        for (i, a) in all.enumerated() {
            let col = i % cols, row = i / cols
            let p = NSPoint(x: ActionRing.tile / 2 + CGFloat(col) * step,
                            y: ActionRing.tipSpace + ActionRing.tile / 2 + CGFloat(rows - 1 - row) * step)
            centers.append(p)
            let b = RingButton(image: EdgeGlyph.image(a), target: self, action: #selector(fire(_:)))
            b.tag = i
            b.isBordered = false
            b.imageScaling = .scaleNone
            b.setAccessibilityLabel(a.title)
            b.frame = NSRect(x: p.x - 23, y: p.y - 23, width: 46, height: 46)
            b.onHover = { [weak self] inside in
                guard let self else { return }
                if inside { self.hot = i } else if self.hot == i { self.hot = nil }
            }
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { ActionRing.close() }

    override func draw(_ dirtyRect: NSRect) {
        let t = ActionRing.tile
        for (i, p) in centers.enumerated() { // each button sits on its own small tile; there is no shared plate
            let r = NSBezierPath(roundedRect: NSRect(x: p.x - t / 2, y: p.y - t / 2, width: t, height: t), xRadius: 13, yRadius: 13)
            (i == hot ? NSColor(white: 0.42, alpha: 0.96) : EdgeGlyph.paper.withAlphaComponent(0.9)).setFill()
            r.fill()
        }
        guard let h = hot else { return }
        // Name tag: above the top row, below the bottom row, so it never covers another button.
        let s = NSAttributedString(string: HotkeyAction.allCases[h].title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white])
        let z = s.size(), p = centers[h]
        let w = z.width + 16, hgt: CGFloat = 22
        let top = h < ActionRing.cols
        var box = NSRect(x: p.x - w / 2, y: top ? p.y + t / 2 + 5 : p.y - t / 2 - 5 - hgt, width: w, height: hgt)
        box.origin.x = min(max(box.minX, 0), bounds.maxX - w)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: box.minX + 8, y: box.midY - z.height / 2))
    }

    @objc private func fire(_ b: NSButton) { ActionRing.fire(HotkeyAction.allCases[b.tag]) }
}
