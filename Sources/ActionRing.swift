import AppKit
import ApplicationServices
import UniformTypeIdentifiers

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

/// One popup button: a built-in action, or an app to open.
enum RingItem: Hashable {
    case action(HotkeyAction)
    case app(String) // bundle identifier

    var key: String {
        switch self { case .action(let a): return a.rawValue; case .app(let id): return "app:" + id }
    }
    init?(key: String) {
        if key.hasPrefix("app:") { self = .app(String(key.dropFirst(4))) }
        else if let a = HotkeyAction(rawValue: key) { self = .action(a) }
        else { return nil }
    }
    var appURL: URL? {
        guard case .app(let id) = self else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
    var title: String {
        switch self {
        case .action(let a): return a.title
        case .app: return "Open " + (appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "app")
        }
    }
    @MainActor var image: NSImage {
        switch self {
        case .action(let a): return EdgeGlyph.image(a)
        case .app:
            let icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
            return NSImage(size: NSSize(width: 36, height: 36), flipped: false) { r in
                icon.draw(in: r.insetBy(dx: 2, dy: 2)); return true
            }
        }
    }
    @MainActor func perform() {
        switch self {
        case .action(let a): AppController.shared.perform(a)
        case .app:
            guard let u = appURL else { Toast.show("App not found"); return }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: u, configuration: cfg)
        }
    }
}

/// Which buttons the popup shows, in order. Edited in place: long-press any button.
enum RingLayout {
    /// When set (demos and tests), the popup uses this order and never touches the user's saved one.
    @MainActor static var scratch: [RingItem]?
    @MainActor static var items: [RingItem] {
        get {
            if let scratch { return scratch }
            guard let raw = UserDefaults.standard.stringArray(forKey: "ring.order") else { return HotkeyAction.allCases.map { .action($0) } }
            var seen = Set<RingItem>()
            return raw.compactMap(RingItem.init(key:)).filter { seen.insert($0).inserted }
        }
        set {
            if scratch != nil { scratch = newValue; return }
            UserDefaults.standard.set(newValue.map(\.key), forKey: "ring.order")
        }
    }
    @MainActor static var hiddenActions: [HotkeyAction] { HotkeyAction.allCases.filter { !items.contains(.action($0)) } }

    /// Actions added in later versions join a popup the user already customized, once.
    /// Removing one afterwards sticks, because the flag stays set.
    static let laterActions: [HotkeyAction] = [.emoji]

    /// Pure version for the test: the saved order (nil = never customized) and the flags already set,
    /// in; the new order and the flags to set, out.
    static func migrate(order: [String]?, flags: Set<String>) -> (order: [String]?, setFlags: [String]) {
        var order = order, set: [String] = []
        for a in laterActions {
            let flag = "ring.added.\(a.rawValue)"
            guard !flags.contains(flag) else { continue }
            set.append(flag)
            let key = RingItem.action(a).key
            if var o = order, !o.contains(key) { o.append(key); order = o }
        }
        return (order, set)
    }

    @MainActor static func addNewActionsOnce() {
        let d = UserDefaults.standard
        let saved = d.stringArray(forKey: "ring.order")
        let flags = Set(laterActions.map { "ring.added.\($0.rawValue)" }.filter { d.bool(forKey: $0) })
        let r = migrate(order: saved, flags: flags)
        r.setFlags.forEach { d.set(true, forKey: $0) }
        if let o = r.order, o != saved ?? [] { d.set(o, forKey: "ring.order") }
    }

    /// An even number of buttons sits in two even rows; otherwise rows of four.
    static func columns(for count: Int) -> Int {
        if count >= 2, count % 2 == 0 { return count / 2 }
        return max(1, min(count, 4))
    }
}

@MainActor
enum ActionRing {
    private static var panel: NSPanel?
    private static var outside: Any?
    static let tile: CGFloat = 52, gap: CGFloat = 8, tipSpace: CGFloat = 30
    /// Side margin so the edit-mode minus badges, which overhang each tile's corner, are not clipped.
    static let side: CGFloat = 10

    static func size(slots: Int, cols: Int) -> NSSize {
        let rows = CGFloat(max(1, (slots + cols - 1) / cols))
        // Wide enough for name tags even when there is a single column.
        let w = max(CGFloat(cols) * tile + CGFloat(cols - 1) * gap, 2 * tile + gap) + 2 * side
        return NSSize(width: w,
                      height: rows * tile + (rows - 1) * gap + tipSpace * 2)
    }

    static var isOpen: Bool { panel != nil }
    static func toggle() { panel == nil ? show() : close() }

    static func show(at point: NSPoint? = nil) {
        guard SelectionSession.active == nil else { return }
        let m = point ?? NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        let n = RingLayout.items.count
        let size = self.size(slots: n, cols: RingLayout.columns(for: n))
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
        let ring = RingView(frame: NSRect(origin: .zero, size: size))
        if GlintLook.isGlass {
            // A frosted plate behind the tiles (not under the name tag row above or the Done row below).
            let host = NSView(frame: ring.frame)
            let blur = Glass.view(radius: 18)
            blur.frame = NSRect(x: 0, y: tipSpace - 10, width: size.width, height: size.height - 2 * tipSpace + 20)
            blur.autoresizingMask = [.width, .height]
            host.addSubview(blur)
            ring.autoresizingMask = [.width, .height]
            host.addSubview(ring)
            p.contentView = host
        } else {
            p.contentView = ring
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    /// Grows or shrinks the panel for a new number of slots, keeping its top edge where it is.
    static func resize(slots: Int, cols: Int) {
        guard let p = panel else { return }
        let s = size(slots: slots, cols: cols)
        var f = p.frame
        f.origin.y += f.height - s.height
        f.origin.x += (f.width - s.width) / 2 // keep it centred where it opened
        f.size = s
        p.setFrame(f, display: true)
    }

    static func close() {
        view?.endEditing(save: true)
        panel?.orderOut(nil); panel = nil
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
    }

    /// Opens the popup straight into edit mode (used by --ring-edit for screenshots).
    static func showEditing() {
        show()
        view?.beginEditingFromOutside()
    }

    static var frame: NSRect? { panel?.frame }
    static var view: RingView? {
        guard let c = panel?.contentView else { return nil }
        return c as? RingView ?? c.subviews.compactMap { $0 as? RingView }.first
    }

    static func fire(_ item: RingItem) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { item.perform() }
    }

    /// Picks an app with an open panel and adds it to the popup, then reopens the popup in edit mode.
    static func addApp() {
        close()
        NSApp.activate()
        let op = NSOpenPanel()
        op.allowedContentTypes = [.application]
        op.directoryURL = URL(fileURLWithPath: "/Applications")
        op.prompt = "Add"
        op.message = "Pick an app to add to the popup."
        guard op.runModal() == .OK, let u = op.url, let id = Bundle(url: u)?.bundleIdentifier else { return }
        var items = RingLayout.items
        if !items.contains(.app(id)) { items.append(.app(id)) }
        RingLayout.items = items
        showEditing()
    }
}

/// The popup. Tiles are layers so they can wobble and slide. Long-press any tile to edit:
/// drag to reorder, the minus badge removes, the plus tile adds from the actions not shown.
final class RingView: NSView {
    private var items = RingLayout.items
    private var tiles: [CALayer] = [] // parallel to items
    private var plus: CALayer?
    private var editing = false
    private var hot: Int? { didSet { if hot != oldValue { needsDisplay = true; refreshTiles() } } }
    private var pressTimer: Timer?
    private var pressIndex: Int?
    private var dragging: (index: Int, grab: NSPoint)?
    private var pressedPlus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for a in items { tiles.append(makeTile(a)) }
        layoutTiles(animated: false)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Geometry

    private var slots: Int { items.count + (editing ? 1 : 0) }
    private var cols: Int { RingLayout.columns(for: items.count) }
    private var rows: Int { max(1, (slots + cols - 1) / cols) }

    private func center(_ i: Int) -> NSPoint {
        let step = ActionRing.tile + ActionRing.gap
        let col = i % cols, row = i / cols
        let gridW = CGFloat(cols) * ActionRing.tile + CGFloat(cols - 1) * ActionRing.gap
        return NSPoint(x: (bounds.width - gridW) / 2 + ActionRing.tile / 2 + CGFloat(col) * step,
                       y: ActionRing.tipSpace + ActionRing.tile / 2 + CGFloat(rows - 1 - row) * step)
    }

    private func slot(at p: NSPoint) -> Int? {
        let t = ActionRing.tile / 2
        return (0..<slots).first { i in let c = center(i); return abs(p.x - c.x) <= t && abs(p.y - c.y) <= t }
    }

    /// Nearest item slot to a point, for dropping a dragged tile.
    private func nearestItemSlot(_ p: NSPoint) -> Int {
        (0..<items.count).min { a, b in
            let ca = center(a), cb = center(b)
            return hypot(ca.x - p.x, ca.y - p.y) < hypot(cb.x - p.x, cb.y - p.y)
        } ?? 0
    }

    private var doneBox: NSRect {
        let w: CGFloat = 64, h: CGFloat = 22
        return NSRect(x: bounds.midX - w / 2, y: (ActionRing.tipSpace - h) / 2, width: w, height: h)
    }

    // MARK: Tiles

    private func makeTile(_ a: RingItem) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: ActionRing.tile, height: ActionRing.tile)
        l.cornerRadius = 13
        l.backgroundColor = (GlintLook.isGlass ? Glass.tile : EdgeGlyph.paper.withAlphaComponent(0.9)).cgColor
        l.contents = a.image
        l.contentsGravity = .center
        l.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let badge = CALayer() // remove badge, shown while editing
        badge.name = "badge"
        badge.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        badge.position = CGPoint(x: 3, y: ActionRing.tile - 3)
        badge.cornerRadius = 9
        badge.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        badge.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        badge.borderWidth = 1
        let bar = CALayer()
        bar.bounds = CGRect(x: 0, y: 0, width: 8, height: 2)
        bar.position = CGPoint(x: 9, y: 9)
        bar.backgroundColor = NSColor.white.cgColor
        bar.cornerRadius = 1
        badge.addSublayer(bar)
        badge.isHidden = true
        l.addSublayer(badge)
        layer?.addSublayer(l)
        return l
    }

    private func makePlus() -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: ActionRing.tile, height: ActionRing.tile)
        l.cornerRadius = 13
        l.backgroundColor = NSColor(white: 0.2, alpha: 0.75).cgColor
        l.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        l.borderWidth = 1.5
        for (w, h) in [(18.0, 2.6), (2.6, 18.0)] {
            let b = CALayer()
            b.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            b.position = CGPoint(x: ActionRing.tile / 2, y: ActionRing.tile / 2)
            b.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            b.cornerRadius = 1.3
            l.addSublayer(b)
        }
        layer?.addSublayer(l)
        return l
    }

    private func refreshTiles() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in tiles.enumerated() {
            let lit = !editing && i == hot
            l.backgroundColor = GlintLook.isGlass ? (lit ? Glass.tileLit : Glass.tile).cgColor
                : (lit ? NSColor(white: 0.42, alpha: 0.96) : EdgeGlyph.paper.withAlphaComponent(0.9)).cgColor
            l.sublayers?.first { $0.name == "badge" }?.isHidden = !editing
        }
        CATransaction.commit()
    }

    private func layoutTiles(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        for (i, l) in tiles.enumerated() where dragging?.index != i { l.position = center(i) }
        plus?.position = center(items.count)
        CATransaction.commit()
        needsDisplay = true
    }

    private func wobble(_ l: CALayer, _ i: Int) {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let d = 0.035 // about 2 degrees
        a.values = [-d, d, -d]
        a.duration = 0.26 + Double(i % 3) * 0.02
        a.repeatCount = .infinity
        a.timeOffset = Double(i) * 0.07
        l.add(a, forKey: "wobble")
    }

    // MARK: Editing

    private func beginEditing() {
        guard !editing else { return }
        editing = true
        hot = nil
        ActionRing.resize(slots: slots, cols: cols)
        plus = makePlus()
        layoutTiles(animated: false)
        for (i, l) in tiles.enumerated() { wobble(l, i) }
        refreshTiles()
    }

    func beginEditingFromOutside() { beginEditing() }
    // Test hooks for RingSelfTest.
    var testEditing: Bool { editing }
    func testCenter(_ i: Int) -> NSPoint { center(i) }
    var testDone: NSRect { doneBox }
    func testAdd(_ a: RingItem) { add(a) }
    var testItemCount: Int { items.count }

    func endEditing(save: Bool) {
        guard editing else { return }
        editing = false
        if save { RingLayout.items = items }
        tiles.forEach { $0.removeAnimation(forKey: "wobble") }
        plus?.removeFromSuperlayer(); plus = nil
        ActionRing.resize(slots: slots, cols: cols)
        layoutTiles(animated: false)
        refreshTiles()
    }

    private func remove(_ i: Int) {
        guard items.count > 1 else { Toast.show("Keep at least one button in the popup"); return }
        items.remove(at: i)
        tiles[i].removeFromSuperlayer()
        tiles.remove(at: i)
        rebuildPlus()
        settle()
    }

    private func add(_ a: RingItem) {
        items.append(a)
        let l = makeTile(a)
        tiles.append(l)
        rebuildPlus()
        settle()
        wobble(l, tiles.count - 1)
    }

    private func rebuildPlus() { plus?.removeFromSuperlayer(); plus = makePlus() }

    /// After a change in count: resize the panel, then lay out.
    private func settle() {
        RingLayout.items = items
        ActionRing.resize(slots: slots, cols: cols)
        layoutTiles(animated: false)
        refreshTiles()
    }

    @objc private func addFromMenu(_ m: NSMenuItem) {
        if let a = RingItem(key: m.representedObject as? String ?? "") { add(a) }
    }

    private func showLibrary(at p: NSPoint) {
        let menu = NSMenu()
        for a in HotkeyAction.allCases where !items.contains(.action(a)) {
            let it = menu.addItem(withTitle: a.title, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = RingItem.action(a).key
            let img = EdgeGlyph.image(a); img.size = NSSize(width: 22, height: 22)
            it.image = img
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let app = menu.addItem(withTitle: "App…", action: #selector(pickApp), keyEquivalent: "")
        app.target = self
        app.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func pickApp() {
        RingLayout.items = items
        DispatchQueue.main.async { ActionRing.addApp() }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard !editing else { return }
        let p = convert(event.locationInWindow, from: nil)
        hot = slot(at: p).flatMap { $0 < items.count ? $0 : nil }
    }
    override func mouseExited(with event: NSEvent) { if !editing { hot = nil } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editing {
            if doneBox.contains(p) { endEditing(save: true); return }
            guard let i = slot(at: p) else { endEditing(save: true); return }
            if i == items.count { pressedPlus = true; return }
            let c = center(i)
            // Minus badge: the tile's top-left corner.
            if hypot(p.x - (c.x - ActionRing.tile / 2 + 3), p.y - (c.y + ActionRing.tile / 2 - 3)) <= 12 { remove(i); return }
            dragging = (i, NSPoint(x: p.x - c.x, y: p.y - c.y))
            tiles[i].zPosition = 10
            return
        }
        guard let i = slot(at: p), i < items.count else { ActionRing.close(); return }
        pressIndex = i
        pressTimer?.invalidate()
        pressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressIndex != nil else { return }
                self.pressIndex = nil
                self.beginEditing()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing, let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tiles[d.index].position = CGPoint(x: p.x - d.grab.x, y: p.y - d.grab.y)
        CATransaction.commit()
        let target = nearestItemSlot(NSPoint(x: p.x - d.grab.x, y: p.y - d.grab.y))
        if target != d.index {
            let a = items.remove(at: d.index); items.insert(a, at: target)
            let l = tiles.remove(at: d.index); tiles.insert(l, at: target)
            dragging = (target, d.grab)
            layoutTiles(animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editing {
            if pressedPlus {
                pressedPlus = false
                if slot(at: p) == items.count { showLibrary(at: center(items.count)) }
                return
            }
            if let d = dragging {
                tiles[d.index].zPosition = 0
                dragging = nil
                RingLayout.items = items
                layoutTiles(animated: true)
            }
            return
        }
        pressTimer?.invalidate()
        if let i = pressIndex {
            pressIndex = nil
            if slot(at: p) == i { ActionRing.fire(items[i]) }
        }
    }

    // MARK: Drawing (name tag, or the Done button while editing)

    override func draw(_ dirtyRect: NSRect) {
        if editing {
            let box = doneBox
            NSColor.black.withAlphaComponent(0.82).setFill() // dark pill reads on light and dark backgrounds
            NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
            let s = NSAttributedString(string: "Done", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            let z = s.size()
            s.draw(at: NSPoint(x: box.midX - z.width / 2, y: box.midY - z.height / 2))
            return
        }
        guard let h = hot, h < items.count else { return }
        let t = ActionRing.tile
        // Name tag: above the top row, below the bottom row, so it never covers another button.
        let s = NSAttributedString(string: items[h].title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white])
        let z = s.size(), p = center(h)
        let w = z.width + 16, hgt: CGFloat = 22
        let top = h < cols
        var box = NSRect(x: p.x - w / 2, y: top ? p.y + t / 2 + 5 : p.y - t / 2 - 5 - hgt, width: w, height: hgt)
        box.origin.x = min(max(box.minX, 0), bounds.maxX - w)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: box.minX + 8, y: box.midY - z.height / 2))
    }
}

/// `--ring-selftest`: drives the popup with synthetic mouse events (long press, drag, remove, add)
/// and logs the saved order after each step to /tmp/glint-scrolltest.log. Restores the user's order.
@MainActor
enum RingSelfTest {
    static func run() {
        RingLayout.scratch = HotkeyAction.allCases.map { .action($0) } // never touches the saved order
        ActionRing.show()
        guard let v = ActionRing.view, let w = v.window else { ScrollTest.log("ring: no view"); NSApp.terminate(nil); return }
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func order() -> String { RingLayout.items.map(\.key).joined(separator: ",") }
        var c0 = v.testCenter(0), c1 = NSPoint.zero, c3 = NSPoint.zero
        ScrollTest.log("ring start:", order(), "editing:", v.testEditing, "bounds:", v.bounds, "c0:", c0, "win:", w.frame)
        v.mouseDown(with: ev(.leftMouseDown, c0)) // long press on tile 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            ScrollTest.log("after long press, editing:", v.testEditing, "panel h:", Int(w.frame.height))
            v.mouseUp(with: ev(.leftMouseUp, c0))
            c0 = v.testCenter(0); c1 = v.testCenter(1); c3 = v.testCenter(3) // edit mode adds a row
            // Drag tile 0 onto slot 3.
            v.mouseDown(with: ev(.leftMouseDown, c0))
            for k in 1...6 {
                let t = CGFloat(k) / 6
                v.mouseDragged(with: ev(.leftMouseDragged, NSPoint(x: c0.x + (c3.x - c0.x) * t, y: c0.y + (c3.y - c0.y) * t)))
            }
            v.mouseUp(with: ev(.leftMouseUp, c3))
            ScrollTest.log("after drag 0->3:", order())
            // Tap the minus badge of tile 1.
            let badge = NSPoint(x: c1.x - ActionRing.tile / 2 + 3, y: c1.y + ActionRing.tile / 2 - 3)
            v.mouseDown(with: ev(.leftMouseDown, badge)); v.mouseUp(with: ev(.leftMouseUp, badge))
            ScrollTest.log("after remove 1:", order(), "hidden:", RingLayout.hiddenActions.map(\.rawValue).joined(separator: ","))
            v.testAdd(.action(RingLayout.hiddenActions[0]))
            v.testAdd(.app("com.apple.Safari"))
            v.testAdd(.app("com.apple.TextEdit"))
            ScrollTest.log("after add (8 + 2 apps):", order(), "panel:", Int(w.frame.width), "x", Int(w.frame.height))
            // Done.
            let done = v.testDone
            v.mouseDown(with: ev(.leftMouseDown, NSPoint(x: done.midX, y: done.midY)))
            ScrollTest.log("after done, editing:", v.testEditing, "panel:", Int(w.frame.width), "x", Int(w.frame.height), "saved:", order())
            ActionRing.close()
            RingLayout.scratch = nil
            ScrollTest.log("saved order untouched:", order())
            NSApp.terminate(nil)
        }
    }
}
