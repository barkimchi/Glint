import AppKit
import ScreenCaptureKit

/// `--demo <ring|capture|annotate> <scene.png> <x,y,w,h>` plays a scripted walkthrough for the README
/// GIFs. A stage window shows the scene over the region (top-left origin points), so nothing else on
/// screen appears in the recording. A drawn pointer stands in for the mouse. Quits when done.
@MainActor
enum Demo {
    private static var stage: NSWindow?
    private static var pointer: NSPanel?
    private static var region = CGRect.zero // bottom-left global

    static func run(_ name: String, scene: String, rect spec: String) {
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4, let img = NSImage(contentsOfFile: scene) else { NSApp.terminate(nil); return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        region = CGRect(x: n[0], y: primaryH - n[1] - n[3], width: n[2], height: n[3])
        Task {
            showStage(img) // also under the editor, so nothing behind it shows before it opens
            // Park the real pointer off the stage so only the drawn one appears.
            CGWarpMouseCursorPosition(CGPoint(x: region.maxX + 300, y: primaryH - region.maxY + 40))
            showPointer(at: NSPoint(x: region.midX + 260, y: region.minY + 120))
            try? await Task.sleep(nanoseconds: 3_000_000_000) // the recorder starts after the stage is up
            switch name {
            case "ring", "popup": await ring()
            case "capture": await capture(img)
            case "annotate": await annotate(scene)
            default: break
            }
            // Stay on screen; the recorder quits the app after it stops, so the clip never shows
            // what is behind the stage.
        }
    }

    // MARK: Stage and pointer

    private static func showStage(_ img: NSImage) {
        let w = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: 2) // above app windows, below Glint's floating panels
        let v = NSImageView(frame: NSRect(origin: .zero, size: region.size))
        v.image = img; v.imageScaling = .scaleAxesIndependently
        w.contentView = v
        w.orderFrontRegardless()
        stage = w
    }

    private static func showPointer(at p: NSPoint) {
        let cur = NSCursor.arrow
        let size = cur.image.size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let v = NSImageView(frame: NSRect(origin: .zero, size: size)); v.image = cur.image
        panel.contentView = v
        pointer = panel
        place(p)
        panel.orderFrontRegardless()
    }

    private static var at = NSPoint.zero
    private static func place(_ p: NSPoint) {
        at = p
        let hs = NSCursor.arrow.hotSpot, s = NSCursor.arrow.image.size
        pointer?.setFrameOrigin(NSPoint(x: p.x - hs.x, y: p.y - (s.height - hs.y)))
    }

    /// Glides the pointer to a global point, calling `step` at each frame (for drags and hovers).
    private static func glide(to p: NSPoint, _ secs: Double = 0.45, step: ((NSPoint) -> Void)? = nil) async {
        let a = at, frames = max(1, Int(secs * 60))
        for i in 1...frames {
            let t = Double(i) / Double(frames), e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let q = NSPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e)
            place(q); step?(q)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func event(_ t: NSEvent.EventType, _ global: NSPoint, in w: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: w.convertPoint(fromScreen: global), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: Popup: open, hover, long-press to edit, drag, remove, add an app, Done

    private static func ring() async {
        RingLayout.scratch = [.action(.area), .action(.window), .action(.fullscreen),
                              .action(.scroll), .action(.page), .action(.ocr)] // the saved order is never touched
        let c = NSPoint(x: region.midX, y: region.midY)
        await glide(to: c, 0.5)
        ActionRing.show(at: c)
        await pause(0.5)
        guard let v = ActionRing.view, let w = v.window else { return }
        func g(_ i: Int) -> NSPoint { w.convertPoint(toScreen: v.convert(v.testCenter(i), to: nil)) }
        for i in [0, 1, 2, 5] { // hover a few buttons to show their names
            await glide(to: g(i), 0.35) { q in v.mouseMoved(with: event(.mouseMoved, q, in: w)) }
            await pause(0.45)
        }
        await glide(to: g(0), 0.35) { q in v.mouseMoved(with: event(.mouseMoved, q, in: w)) }
        v.mouseDown(with: event(.leftMouseDown, g(0), in: w)) // long press
        await pause(0.8)
        v.mouseUp(with: event(.leftMouseUp, g(0), in: w))
        await pause(0.9)
        // Drag the first button to the end of the top row.
        let from = g(0), to = g(2)
        v.mouseDown(with: event(.leftMouseDown, from, in: w))
        await glide(to: to, 0.8) { q in v.mouseDragged(with: event(.leftMouseDragged, q, in: w)) }
        v.mouseUp(with: event(.leftMouseUp, to, in: w))
        await pause(0.7)
        // Remove the fourth button with its minus badge.
        let c3 = v.testCenter(3)
        let badge = w.convertPoint(toScreen: v.convert(NSPoint(x: c3.x - ActionRing.tile / 2 + 3, y: c3.y + ActionRing.tile / 2 - 3), to: nil))
        await glide(to: badge, 0.5)
        v.mouseDown(with: event(.leftMouseDown, badge, in: w)); v.mouseUp(with: event(.leftMouseUp, badge, in: w))
        await pause(0.8)
        // Add two apps from the library (shown as if picked from the plus tile).
        await glide(to: g(v.testItemCount), 0.5)
        await pause(0.4)
        v.testAdd(.app("com.apple.Safari"))
        await pause(0.7)
        await glide(to: g(v.testItemCount), 0.35)
        await pause(0.3)
        v.testAdd(.app("com.apple.Notes"))
        await pause(1.0)
        let done = v.testDone
        let dp = w.convertPoint(toScreen: v.convert(NSPoint(x: done.midX, y: done.midY), to: nil))
        await glide(to: dp, 0.5)
        v.mouseDown(with: event(.leftMouseDown, dp, in: w))
        await pause(0.6)
        let c2 = NSPoint(x: w.frame.midX, y: w.frame.midY)
        await glide(to: c2, 0.4) { q in v.mouseMoved(with: event(.mouseMoved, q, in: w)) }
        await pause(1.0)
    }

    // MARK: Capture an area, then the quick-access thumbnail

    private static func capture(_ img: NSImage) async {
        guard let screen = NSScreen.screens.first,
              let c = try? await Capture.content(),
              let d = c.displays.first(where: { Capture.screen(for: $0) == screen }) else { return }
        // A frozen screen made of the scene on a plain backdrop, so the overlay shows only demo content.
        let scale = screen.backingScaleFactor, sf = screen.frame
        let full = NSImage(size: sf.size, flipped: false) { r in
            NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
            img.draw(in: region.offsetBy(dx: -sf.minX, dy: -sf.minY)); return true
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: sf.width * scale, height: sf.height * scale))
        guard let cg = full.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let frozen = Frozen(screen: screen, display: d, image: cg)
        var picked: CGRect?
        SelectionSession.start(frozen: [frozen], mode: .area, windows: []) { r in
            if case .area(_, let rr) = r { picked = rr }
        }
        await pause(0.4)
        guard let ow = NSApp.windows.first(where: { $0 is OverlayWindow && $0.isVisible }),
              let sv = ow.contentView as? SelectionView else { return }
        // Drag over the KPI cards.
        let a = NSPoint(x: region.minX + 36, y: region.maxY - 220), b = NSPoint(x: region.minX + 1166, y: region.maxY - 388)
        await glide(to: a, 0.6)
        sv.mouseDown(with: event(.leftMouseDown, a, in: ow))
        await glide(to: b, 1.1) { q in sv.mouseDragged(with: event(.leftMouseDragged, q, in: ow)) }
        await pause(0.3)
        sv.mouseUp(with: event(.leftMouseUp, b, in: ow))
        await pause(0.3)
        guard let r = picked, let shot = Capture.crop(frozen, r) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glint-demo-capture.png")
        try? NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])?.write(to: url)
        QuickAccess.show(url: url, isVideo: false)
        await pause(1.0)
        // Hover the thumbnail to reveal its actions.
        if let vf = screen.visibleFrame as NSRect? {
            await glide(to: NSPoint(x: vf.minX + 126, y: vf.minY + 70), 0.7)
        }
        await pause(2.2)
    }

    // MARK: Annotate: arrow, box, step numbers, highlight

    private static func annotate(_ scene: String) async {
        EditorWindow.open(URL(fileURLWithPath: scene))
        guard let m = EditorWindow.lastModel,
              let w = NSApp.windows.first(where: { $0.title.hasPrefix("Annotate") }) else { return }
        w.level = .floating
        w.setFrame(region, display: true)
        pointer?.orderOut(nil) // marks draw themselves here; no pointer
        await pause(0.8)
        func draw(_ t: Tool, _ a: CGPoint, _ b: CGPoint, color: NSColor = .systemRed, secs: Double = 0.6) async {
            m.tool = t; m.color = color
            await pause(0.35)
            var mk = Mark(tool: t, a: a, b: a, color: color, points: [a])
            let frames = Int(secs * 60)
            for i in 1...frames {
                let k = CGFloat(i) / CGFloat(frames)
                mk.b = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                if t == .pen { mk.points.append(mk.b) }
                m.draft = mk
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            m.draft = nil
            m.commit(mk)
            await pause(0.4)
        }
        await draw(.rect, CGPoint(x: 610, y: 233), CGPoint(x: 872, y: 376))
        await draw(.arrow, CGPoint(x: 480, y: 120), CGPoint(x: 600, y: 225))
        await draw(.highlight, CGPoint(x: 818, y: 470), CGPoint(x: 1128, y: 500), color: .systemYellow, secs: 0.5)
        m.tool = .counter
        await pause(0.4)
        for (i, p) in [CGPoint(x: 300, y: 300), CGPoint(x: 580, y: 300), CGPoint(x: 1130, y: 300)].enumerated() {
            m.commit(Mark(tool: .counter, a: p, b: p, color: .systemRed, number: i + 1))
            await pause(0.45)
        }
        await draw(.pixelate, CGPoint(x: 1040, y: 465), CGPoint(x: 1130, y: 700), secs: 0.5)
        await pause(0.6)
        // Edit a placed mark: select the box, move it to the next card, stretch it, recolor it.
        m.tool = .select
        await pause(0.5)
        guard let box = m.marks.firstIndex(where: { $0.tool == .rect }) else { return }
        m.selected = m.marks[box].id
        await pause(0.6)
        let orig = m.marks[box]
        m.beginEdit()
        for i in 1...36 {
            m.replaceSelected(orig.moved(by: CGVector(dx: -281 * CGFloat(i) / 36, dy: 0)))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        await pause(0.4)
        let moved = m.marks[box]
        m.beginEdit()
        for i in 1...24 {
            let k = CGFloat(i) / 24
            m.replaceSelected(moved.reshaped(handle: 2, to: CGPoint(x: moved.rect.maxX + 40 * k, y: moved.rect.maxY + 20 * k)))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        await pause(0.5)
        m.color = .systemBlue; m.recolorSelected(.systemBlue)
        await pause(0.8)
        m.selected = nil
        // Put it on a background with padding.
        m.backdrop = .ocean
        await pause(1.0)
        m.backdrop = .sunrise
        await pause(1.4)
    }
}

/// `--editor-selftest <png>`: exercises select/move/reshape/recolor/delete/undo on the editor model and
/// renders the image framed on a background to /tmp/glint-framed.png. Logs to /tmp/glint-scrolltest.log.
@MainActor
enum EditorSelfTest {
    static func run(_ path: String) {
        guard let cg = Store.cgImage(URL(fileURLWithPath: path)) else { ScrollTest.log("editor: no image"); NSApp.terminate(nil); return }
        let m = EditorModel(image: cg)
        func log(_ s: String) { ScrollTest.log("editor:", s) }
        m.commit(Mark(tool: .rect, a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 200), color: .systemRed))
        m.commit(Mark(tool: .arrow, a: CGPoint(x: 400, y: 400), b: CGPoint(x: 600, y: 450), color: .systemRed))
        m.commit(Mark(tool: .counter, a: CGPoint(x: 700, y: 300), b: CGPoint(x: 700, y: 300), color: .systemRed, number: 1))
        log("hit box edge: \(String(describing: m.hit(CGPoint(x: 100, y: 150)))) (want 0)")
        log("hit box middle: \(String(describing: m.hit(CGPoint(x: 200, y: 150)))) (want nil: boxes are hit on their outline)")
        log("hit arrow: \(String(describing: m.hit(CGPoint(x: 500, y: 425)))) (want 1)")
        log("hit counter: \(String(describing: m.hit(CGPoint(x: 705, y: 298)))) (want 2)")
        log("hit empty: \(String(describing: m.hit(CGPoint(x: 900, y: 700)))) (want nil)")
        m.selected = m.marks[0].id
        m.beginEdit(); m.replaceSelected(m.marks[0].moved(by: CGVector(dx: 50, dy: 20)))
        log("moved box a=\(m.marks[0].a) b=\(m.marks[0].b) (want 150,120 / 350,220)")
        m.beginEdit(); m.replaceSelected(m.marks[0].reshaped(handle: 2, to: CGPoint(x: 500, y: 300)))
        log("resized box rect=\(m.marks[0].rect) (want x150 y120 w350 h180)")
        m.selected = m.marks[1].id
        m.beginEdit(); m.replaceSelected(m.marks[1].reshaped(handle: 1, to: CGPoint(x: 650, y: 380)))
        log("re-aimed arrow b=\(m.marks[1].b) (want 650,380)")
        m.recolorSelected(.systemBlue)
        log("arrow color blue: \(m.marks[1].color == .systemBlue)")
        m.deleteSelected()
        log("after delete: \(m.marks.map(\.tool.rawValue)) (want rect,counter)")
        m.undo(); log("undo delete: \(m.marks.map(\.tool.rawValue)) (want rect,arrow,counter)")
        m.undo(); log("undo recolor: arrow blue=\(m.marks[1].color == .systemBlue) (want false)")
        m.undo(); m.undo()
        log("undo resize+move: box a=\(m.marks[0].rect.origin) size=\(m.marks[0].rect.size) (want 150,120 200x100 after one more undo)")
        m.undo(); log("undo move: box rect=\(m.marks[0].rect) (want x100 y100 w200 h100)")
        m.redo(); log("redo move: box origin=\(m.marks[0].rect.origin) (want 150,120)")
        m.backdrop = .ocean
        if let out = m.render() {
            log("framed \(out.width)x\(out.height) from \(cg.width)x\(cg.height), pad \(Int(m.pad)), alpha edges \(m.hasAlphaEdges)")
            try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/glint-framed.png"))
        }
        NSApp.terminate(nil)
    }
}

/// `--tour --tour-capture-test -tour.startStep 2`: with the tour on its "Try it" step, runs a real area
/// capture through the normal pipeline (overlay, selection, save, quick access) with a synthetic drag over
/// the tour window, then logs whether the step saw it. Logs the saved files so the test can remove them.
@MainActor
enum TourCaptureTest {
    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let tour = NSApp.windows.first(where: { $0.isVisible && $0.frame.width == 760 }) else {
                ScrollTest.log("tour-capture: no tour window"); return
            }
            let before = Date()
            ScrollTest.log("tour-capture: screen recording allowed =", CGPreflightScreenCaptureAccess())
            AppController.shared.perform(.area)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let ow = NSApp.windows.first(where: { $0 is OverlayWindow && $0.isVisible }),
                      let sv = ow.contentView as? SelectionView else { ScrollTest.log("tour-capture: no overlay"); return }
                func ev(_ t: NSEvent.EventType, _ g: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: ow.convertPoint(fromScreen: g), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: ow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                // Drag over the middle of the tour window (only Glint's own UI is in the shot).
                let a = NSPoint(x: tour.frame.minX + 200, y: tour.frame.minY + 160)
                let b = NSPoint(x: tour.frame.maxX - 200, y: tour.frame.maxY - 160)
                sv.mouseDown(with: ev(.leftMouseDown, a))
                for k in 1...10 {
                    let t = CGFloat(k) / 10
                    sv.mouseDragged(with: ev(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
                }
                sv.mouseUp(with: ev(.leftMouseUp, b))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let fm = FileManager.default
                    let dirs = [Store.savedDir, URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Glint/History")]
                    for d in dirs {
                        for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                            if let c = try? u.resourceValues(forKeys: [.creationDateKey]).creationDate, c > before {
                                ScrollTest.log("tour-capture: saved", u.path)
                            }
                        }
                    }
                    ScrollTest.log("tour-capture: done")
                }
            }
        }
    }
}
