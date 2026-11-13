import AppKit
import QuartzCore
import ScreenCaptureKit

/// A transparent, click-through window over the recording area that draws an expanding ring
/// at every mouse click and, optionally, a pill showing pressed keys. It's the one Glint window
/// deliberately left IN the recording.
@MainActor
final class ClickOverlay {
    let window: NSWindow
    private var monitors: [Any] = []
    private let clicks: Bool
    private let keys: Bool
    private var pill: NSTextField?
    private var pillBox: NSView?
    private var typed = ""
    private var lastKey = Date.distantPast
    private var hideWork: DispatchWorkItem?

    init(globalRect: CGRect, clicks: Bool = true, keys: Bool = false) {
        self.clicks = clicks
        self.keys = keys
        let w = NSWindow(contentRect: globalRect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: NSRect(origin: .zero, size: globalRect.size))
        v.wantsLayer = true
        w.contentView = v
        window = w
    }

    func show() {
        window.orderFrontRegardless()
        // Global monitors see clicks in other apps (mouse events need no extra permission);
        // the local one covers clicks on Glint's own windows.
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.ripple(atScreenPoint: NSEvent.mouseLocation, right: e.type == .rightMouseDown) }
        }
        if clicks {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
                monitors.append(g)
            }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
                handler(e); return e
            }) { monitors.append(l) }
        }
        if keys {
            // Global key monitoring only works with Accessibility access (checked in Settings).
            // Password fields use secure input, so macOS never delivers those keys here.
            let keyHandler: (NSEvent) -> Void = { [weak self] e in
                MainActor.assumeIsolated { self?.key(e) }
            }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in keyHandler(e); return e }) {
                monitors.append(l)
            }
        }
    }

    // MARK: Keystrokes

    func key(_ e: NSEvent) {
        let f = e.modifierFlags.intersection([.control, .option, .command])
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 117: "⌦",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 76: "⌤"]
        var mods = ""
        if f.contains(.control) { mods += "⌃" }
        if f.contains(.option) { mods += "⌥" }
        if e.modifierFlags.contains(.shift) && (!f.isEmpty || special[e.keyCode] != nil) { mods += "⇧" }
        if f.contains(.command) { mods += "⌘" }
        let base = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        if f.isEmpty, special[e.keyCode] == nil, let c = e.characters, !c.isEmpty {
            // Plain typing accumulates into a running string until a pause.
            if Date().timeIntervalSince(lastKey) > 1.2 { typed = "" }
            typed = String((typed + c).suffix(28))
            showPill(typed)
        } else {
            typed = ""
            showPill(mods + base)
        }
        lastKey = Date()
    }

    func showPill(_ text: String) {
        guard let root = window.contentView else { return }
        if pill == nil {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            box.layer?.cornerRadius = 12
            let l = NSTextField(labelWithString: "")
            l.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
            l.textColor = .white
            l.alignment = .center
            box.addSubview(l)
            root.addSubview(box)
            pill = l; pillBox = box
        }
        guard let pill, let box = pillBox else { return }
        pill.stringValue = text
        pill.sizeToFit()
        let size = NSSize(width: pill.frame.width + 32, height: pill.frame.height + 16)
        box.frame = NSRect(x: (root.bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height)
        pill.frame.origin = NSPoint(x: 16, y: 8)
        box.alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak box] in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.35; box?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        window.orderOut(nil)
    }

    /// The SCWindow for this overlay, so the recording filter can include it.
    func scWindow(in content: SCShareableContent) -> SCWindow? {
        content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
    }

    func ripple(atScreenPoint p: NSPoint, right: Bool = false) {
        guard window.frame.contains(p), let layer = window.contentView?.layer else { return }
        let local = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
        let color = right ? NSColor.systemBlue : NSColor.systemYellow

        let ring = CAShapeLayer()
        let r: CGFloat = 26
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = local
        ring.fillColor = color.withAlphaComponent(0.35).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ring.removeFromSuperlayer() }
    }
}
