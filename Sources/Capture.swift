import AppKit
import ScreenCaptureKit

enum CaptureMode {
    case area, window, ocr, record, scroll, page
    var picksWindow: Bool { self == .window || self == .page }
}

/// A display frozen at the moment the hotkey was pressed. Selecting on a still image
/// means menus and hover states stay exactly as they were.
struct Frozen {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage
}

enum SelectionResult {
    case area(Frozen, CGRect) // rect in the overlay view's points (bottom-left origin)
    case window(SCWindow)
    case page(Frozen, CGRect, SCWindow) // the clicked window's rect, in overlay view points
    case cancel
}

@MainActor
enum Capture {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func ownApps(_ c: SCShareableContent) -> [SCRunningApplication] {
        c.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    }

    static func screen(for d: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
        }
    }

    static func snapshot(_ d: SCDisplay, content c: SCShareableContent) async throws -> CGImage {
        let filter = SCContentFilter(display: d, excludingApplications: ownApps(c), exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let s = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * s)
        cfg.height = Int(filter.contentRect.height * s)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func window(_ w: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let s = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * s)
        cfg.height = Int(filter.contentRect.height * s)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Normal app windows, front to back (CGWindowList gives z-order; SCShareableContent does not).
    static func pickableWindows(_ c: SCShareableContent) -> [SCWindow] {
        let byID = Dictionary(c.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let mine = Bundle.main.bundleIdentifier
        return info.compactMap { d -> SCWindow? in
            guard let n = d[kCGWindowNumber as String] as? CGWindowID, let w = byID[n] else { return nil }
            guard w.windowLayer == 0, w.frame.width > 40, w.frame.height > 40,
                  w.owningApplication?.bundleIdentifier != mine else { return nil }
            return w
        }
    }

    static func crop(_ f: Frozen, _ r: CGRect) -> CGImage? {
        let s = CGFloat(f.image.width) / f.screen.frame.width
        let px = CGRect(x: r.minX * s, y: (f.screen.frame.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s).integral
        return f.image.cropping(to: px)
    }
}

// MARK: - Selection overlay

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SelectionSession {
    static var active: SelectionSession?
    private var windows: [OverlayWindow] = []
    private let completion: (SelectionResult) -> Void

    private init(completion: @escaping (SelectionResult) -> Void) { self.completion = completion }

    static func start(frozen: [Frozen], mode: CaptureMode, windows: [SCWindow],
                      completion: @escaping (SelectionResult) -> Void) {
        let session = SelectionSession(completion: completion)
        active = session
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        for f in frozen {
            let w = OverlayWindow(contentRect: f.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.acceptsMouseMovedEvents = true
            // SCWindow frames use a top-left origin across all displays; convert to this view's space.
            let rects: [(SCWindow, CGRect)] = windows.map { sw in
                let r = sw.frame
                let ns = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
                return (sw, ns.offsetBy(dx: -f.screen.frame.minX, dy: -f.screen.frame.minY))
            }
            let v = SelectionView(frozen: f, mode: mode, windows: rects) { [weak session] r in session?.finish(r) }
            w.contentView = v
            w.setFrame(f.screen.frame, display: true)
            w.orderFrontRegardless()
            session.windows.append(w)
            if NSMouseInRect(mouse, f.screen.frame, false) {
                w.makeKeyAndOrderFront(nil)
                w.makeFirstResponder(v)
            }
        }
        NSApp.activate()
    }

    private func finish(_ r: SelectionResult) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        SelectionSession.active = nil
        // Let the overlays leave the screen before anything is captured live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.completion(r) }
    }
}

final class SelectionView: NSView {
    let frozen: Frozen
    let mode: CaptureMode
    let windows: [(SCWindow, CGRect)]
    let onDone: (SelectionResult) -> Void
    private var start: NSPoint?
    private var current: NSRect?
    private var hover: (SCWindow, CGRect)?
    private var done = false

    init(frozen: Frozen, mode: CaptureMode, windows: [(SCWindow, CGRect)], onDone: @escaping (SelectionResult) -> Void) {
        self.frozen = frozen; self.mode = mode; self.windows = windows; self.onDone = onDone
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: mode.picksWindow ? .pointingHand : .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    private var hint: String {
        switch mode {
        case .area: return "Drag to capture  ·  Esc to cancel"
        case .window: return "Click a window  ·  Esc to cancel"
        case .ocr: return "Drag over text to copy it  ·  Esc to cancel"
        case .record: return "Drag an area to record, or press Return for the whole screen  ·  Esc to cancel"
        case .page: return "Click a page to capture all of it, top to bottom  ·  Esc to cancel"
        case .scroll: return "Drag over the scrollable area, then scroll it  ·  Esc to cancel"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(frozen.image, in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let h = current ?? hover?.1 {
            ctx.saveGState(); ctx.clip(to: h); ctx.draw(frozen.image, in: bounds); ctx.restoreGState()
            let p = NSBezierPath(rect: h.insetBy(dx: -0.75, dy: -0.75))
            p.lineWidth = 1.5
            NSColor.systemTeal.setStroke()
            p.stroke()
            if current != nil {
                label("\(Int(h.width)) × \(Int(h.height))", at: NSPoint(x: h.minX, y: max(h.minY - 26, 4)))
            }
        }
        let attrs = labelAttrs
        let size = (hint as NSString).size(withAttributes: attrs)
        label(hint, at: NSPoint(x: bounds.midX - size.width / 2 - 8, y: bounds.maxY - 80))
    }

    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func label(_ s: String, at p: NSPoint) {
        let size = (s as NSString).size(withAttributes: labelAttrs)
        let box = NSRect(x: p.x, y: p.y, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (s as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: labelAttrs)
    }

    private func finish(_ r: SelectionResult) {
        guard !done else { return }
        done = true
        onDone(r)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode.picksWindow else { return }
        let p = convert(event.locationInWindow, from: nil)
        let h = windows.first { $0.1.contains(p) }
        if h?.0.windowID != hover?.0.windowID { hover = h; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !mode.picksWindow, let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode.picksWindow {
            guard let h = hover else { return }
            let r = h.1.intersection(bounds).integral
            finish(mode == .page && r.height > 80 ? .page(frozen, r, h.0) : .window(h.0))
            return
        }
        if let c = current, c.width > 4, c.height > 4 {
            finish(.area(frozen, c.integral))
        } else if mode == .record {
            finish(.area(frozen, bounds))
        } else {
            current = nil; start = nil; needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish(.cancel) // Esc
        case 36 where mode == .record, 76 where mode == .record: finish(.area(frozen, bounds)) // Return
        default: super.keyDown(with: event)
        }
    }
}
