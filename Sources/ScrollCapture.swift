import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Stitches successive captures of the same scrolling region into one tall image.
/// Each frame is reduced to a 64-column grayscale "signature"; we find the vertical shift
/// where the new frame's rows line up with the previous frame's rows, then append only the new rows.
final class Stitcher {
    private(set) var strips: [CGImage] = []
    private var lastSig: [UInt8] = []
    private var width = 0, height = 0
    private(set) var totalHeight = 0
    private(set) var skipped = 0 // frames that changed but could not be matched (scrolled too fast)
    static let cols = 64
    /// Signature columns used for matching. Full-page capture drops columns that never move (sidebars).
    var activeCols = Array(0..<Stitcher.cols)
    static let maxHeight = 40_000

    /// Returns true when the frame added new content.
    @discardableResult
    func add(_ img: CGImage) -> Bool {
        let sig = Self.signature(img)
        if strips.isEmpty {
            width = img.width; height = img.height
            strips = [img]; lastSig = sig; totalHeight = img.height
            return true
        }
        guard img.width == width, img.height == height, totalHeight < Self.maxHeight else { return false }
        let (d, err, err0) = Self.offset(prev: lastSig, next: sig, h: height, active: activeCols)
        guard err0 > 1.5 else { return false } // nothing moved
        guard d > 0, err < 8, err < err0 * 0.5 else { skipped += 1; return false }
        guard let strip = img.cropping(to: CGRect(x: 0, y: height - d, width: width, height: d)) else { return false }
        strips.append(strip)
        totalHeight += d
        lastSig = sig
        return true
    }

    func compose() -> CGImage? {
        guard let first = strips.first,
              let ctx = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = totalHeight // CG origin is bottom-left, so draw downward from the top
        for s in strips {
            top -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: top, width: s.width, height: s.height))
        }
        return ctx.makeImage()
    }

    static func signature(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: cols * img.height)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cols, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: cols, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: cols, height: img.height))
        }
        return buf // row 0 is the top of the image
    }

    /// Best shift d so that next[y] ≈ prev[y + d]. Returns (d, error at d, error with no shift).
    static func offset(prev: [UInt8], next: [UInt8], h: Int, active: [Int] = Array(0..<cols)) -> (Int, Double, Double) {
        let minOverlap = max(24, h / 6)
        let samples = 56
        return prev.withUnsafeBufferPointer { p in
            next.withUnsafeBufferPointer { n in
                func err(_ d: Int) -> Double {
                    let span = h - d
                    var total = 0, count = 0
                    for i in 0..<samples {
                        let y = (span - 1) * i / (samples - 1)
                        let a = (y + d) * cols, b = y * cols
                        for c in active { total += abs(Int(p[a + c]) - Int(n[b + c])) }
                        count += active.count
                    }
                    return Double(total) / Double(count)
                }
                let e0 = err(0)
                var best = (0, Double.greatestFiniteMagnitude)
                for d in 1...(h - minOverlap) {
                    let e = err(d)
                    if e < best.1 { best = (d, e) }
                }
                return (best.0, best.1, e0)
            }
        }
    }
}

/// Finds the part of a window that actually scrolls by comparing a frame before and after one scroll step.
enum PageProbe {
    /// Returns the moving band as pixel rows [top, bottom) and the signature columns that moved.
    /// nil means nothing scrolled.
    static func analyze(_ a: CGImage, _ b: CGImage) -> (top: Int, bottom: Int, cols: [Int])? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let sa = Stitcher.signature(a), sb = Stitcher.signature(b)
        let n = Stitcher.cols, h = a.height
        var rowHit = [Bool](repeating: false, count: h), colHit = [Bool](repeating: false, count: n)
        for y in 0..<h {
            for c in 0..<n where abs(Int(sa[y * n + c]) - Int(sb[y * n + c])) > 10 {
                rowHit[y] = true; colHit[c] = true
            }
        }
        guard let top = rowHit.firstIndex(of: true), let last = rowHit.lastIndex(of: true),
              rowHit.filter({ $0 }).count >= max(8, h / 50) else { return nil }
        let cols = (0..<n).filter { colHit[$0] }
        return (top, last + 1, cols.count >= 8 ? cols : Array(0..<n))
    }

    /// Stacks images top to bottom. All share one width.
    static func stack(_ parts: [CGImage]) -> CGImage? {
        guard let first = parts.first else { return nil }
        if parts.count == 1 { return first }
        let total = parts.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: first.width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = total
        for p in parts {
            top -= p.height
            ctx.draw(p, in: CGRect(x: 0, y: top, width: p.width, height: p.height))
        }
        return ctx.makeImage()
    }
}

/// Live session: a border around the region, a small control bar, and a capture loop.
@MainActor
final class ScrollSession {
    static var active: ScrollSession?

    private let frozen: Frozen
    private let rect: CGRect // overlay view points (bottom-left origin), on frozen.screen
    private var source: CGRect
    private let fullSource: CGRect
    private let pageMode: Bool
    private var header: CGImage?
    private var footer: CGImage?
    private var bandBottomPx = 0
    private let stitcher = Stitcher()
    private var border: NSWindow?
    private var bar: NSPanel?
    private var label: NSTextField?
    private var autoButton: NSButton?
    private var running = true
    private var autoScroll = false
    private var idleTicks = 0
    private let onDone: (CGImage?) -> Void

    init(frozen: Frozen, rect: CGRect, page: Bool = false, onDone: @escaping (CGImage?) -> Void) {
        self.frozen = frozen
        self.rect = rect
        self.source = CGRect(x: rect.minX, y: frozen.screen.frame.height - rect.maxY,
                             width: rect.width, height: rect.height).integral
        self.fullSource = self.source
        self.pageMode = page
        self.onDone = onDone
    }

    func start() {
        if pageMode {
            // Full-page capture scrolls for you, and macOS only lets apps post scroll events with Accessibility access.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(opts) else {
                Toast.show("Full-page capture needs Accessibility access for Glint. Turn it on, then try again.")
                onDone(nil)
                return
            }
        }
        ScrollSession.active = self
        let global = rect.offsetBy(dx: frozen.screen.frame.minX, dy: frozen.screen.frame.minY)
        showBorder(global)
        showBar(below: global)
        Task { await loop() }
    }

    private func loop() async {
        do {
            let c = try await Capture.content() // fetched after our panels exist, so they are excluded
            let exclude = Capture.ownApps(c)
            if pageMode, !(try await preparePage(exclude)) { return }
            while running {
                let img = try await capture(exclude: exclude)
                let added = stitcher.add(img)
                idleTicks = added ? 0 : idleTicks + 1
                updateLabel()
                if autoScroll {
                    if idleTicks >= 6 { // reached the end
                        if pageMode, bandBottomPx > 0, let full = try? await capture(exclude: exclude, rect: fullSource),
                           bandBottomPx < full.height {
                            footer = full.cropping(to: CGRect(x: 0, y: bandBottomPx, width: full.width,
                                                              height: full.height - bandBottomPx))
                        }
                        finish(save: true); return
                    }
                    postScroll()
                }
                try await Task.sleep(nanoseconds: autoScroll ? 220_000_000 : 120_000_000)
            }
        } catch {
            Toast.show("Scrolling capture failed: \(error.localizedDescription)")
            finish(save: false)
        }
    }

    /// Scrolls to the top, finds which rows of the window really scroll (so toolbars and sticky
    /// headers are kept once instead of repeated), then hands over to the auto-scroll loop.
    private func preparePage(_ exclude: [SCRunningApplication]) async throws -> Bool {
        func toTop() async throws {
            for _ in 0..<4 { wheel(20_000) }
            try await Task.sleep(nanoseconds: 450_000_000)
        }
        try await toTop()
        var a = try await capture(exclude: exclude)
        var probe: (top: Int, bottom: Int, cols: [Int])?
        for attempt in 0..<2 {
            postScroll()
            try await Task.sleep(nanoseconds: 400_000_000)
            probe = PageProbe.analyze(a, try await capture(exclude: exclude))
            if probe != nil || attempt == 1 { break }
            // The click may have landed on a toolbar. Try again from the middle of the window.
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let g = rect.offsetBy(dx: frozen.screen.frame.minX, dy: frozen.screen.frame.minY)
            CGWarpMouseCursorPosition(CGPoint(x: g.midX, y: primaryH - g.midY))
            try await toTop()
            a = try await capture(exclude: exclude)
        }
        guard running else { return false }
        guard let p = probe else { // nothing scrolls: the window as it stands is the whole page
            running = false
            border?.orderOut(nil); bar?.orderOut(nil)
            ScrollSession.active = nil
            onDone(a)
            return false
        }
        let s = frozen.screen.backingScaleFactor
        let topPx = Int((CGFloat(p.top) / s).rounded(.up) * s)
        let botPx = Int((CGFloat(p.bottom) / s).rounded(.down) * s)
        guard botPx - topPx > 60 else { finish(save: false); return false }
        if topPx > 0 { header = a.cropping(to: CGRect(x: 0, y: 0, width: a.width, height: topPx)) }
        bandBottomPx = botPx
        source = CGRect(x: fullSource.minX, y: fullSource.minY + CGFloat(topPx) / s,
                        width: fullSource.width, height: CGFloat(botPx - topPx) / s)
        stitcher.activeCols = p.cols
        try await toTop()
        autoScroll = true
        return true
    }

    private func wheel(_ px: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: px, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func capture(exclude: [SCRunningApplication], rect: CGRect? = nil) async throws -> CGImage {
        let source = rect ?? self.source
        let filter = SCContentFilter(display: frozen.display, excludingApplications: exclude, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let s = frozen.screen.backingScaleFactor
        cfg.sourceRect = source
        cfg.width = Int(source.width * s)
        cfg.height = Int(source.height * s)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    // Auto-scroll posts real scroll-wheel events, which macOS only allows with Accessibility access.
    @objc private func toggleAuto() {
        if !autoScroll {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(opts) else {
                Toast.show("Auto-scroll needs Accessibility access for Glint. Scroll by hand meanwhile.")
                return
            }
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let g = rect.offsetBy(dx: frozen.screen.frame.minX, dy: frozen.screen.frame.minY)
            CGWarpMouseCursorPosition(CGPoint(x: g.midX, y: primaryH - g.midY))
        }
        autoScroll.toggle()
        idleTicks = 0
        autoButton?.title = autoScroll ? "Stop Auto" : "Auto-scroll"
    }

    private func postScroll() {
        wheel(-Int32(max(40, source.height * 0.45)))
    }

    @objc private func done() { finish(save: true) }
    @objc private func cancel() { finish(save: false) }

    private func finish(save: Bool) {
        guard running else { return }
        running = false
        border?.orderOut(nil); bar?.orderOut(nil)
        ScrollSession.active = nil
        if save, stitcher.strips.count > 1 || !stitcher.strips.isEmpty {
            if stitcher.skipped > 0 && stitcher.strips.count <= 1 {
                Toast.show("Couldn't follow the scroll. Try scrolling slower.")
            }
            let body = stitcher.compose()
            onDone(pageMode ? PageProbe.stack([header, body, footer].compactMap { $0 }) : body)
        } else {
            onDone(nil)
        }
    }

    private func updateLabel() {
        let pts = Int(CGFloat(stitcher.totalHeight) / frozen.screen.backingScaleFactor)
        var t = pageMode ? "Capturing the page. \(pts) pt so far" : "Scroll the content. Captured \(pts) pt tall"
        if stitcher.skipped > 0 { t += " · scroll slower" }
        label?.stringValue = t
    }

    private func showBorder(_ r: CGRect) {
        let w = NSWindow(contentRect: r.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = DashedBorder(color: .systemTeal)
        w.orderFrontRegardless()
        border = w
    }

    private func showBar(below r: CGRect) {
        let size = NSSize(width: 470, height: 44)
        let vf = frozen.screen.visibleFrame
        var origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 12)
        if origin.y < vf.minY { origin.y = r.minY + 12 } // no room below: sit inside the bottom edge
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 10
        let l = NSTextField(labelWithString: "Scroll the content. Captured 0 pt tall")
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.frame = NSRect(x: 14, y: 13, width: 220, height: 18)
        l.lineBreakMode = .byTruncatingTail
        let auto = NSButton(title: "Auto-scroll", target: self, action: #selector(toggleAuto))
        let cancelB = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let doneB = NSButton(title: "Done", target: self, action: #selector(done))
        doneB.keyEquivalent = "\r"
        cancelB.keyEquivalent = "\u{1b}"
        for (b, x, w) in [(auto, 238.0, 92.0), (cancelB, 332.0, 66.0), (doneB, 400.0, 60.0)] {
            b.bezelStyle = .rounded; b.controlSize = .small
            b.frame = NSRect(x: x, y: 9, width: w, height: 26)
            bg.addSubview(b)
        }
        bg.addSubview(l)
        p.contentView = bg
        p.orderFrontRegardless()
        if pageMode { auto.isHidden = true; l.stringValue = "Capturing the page…" }
        bar = p; label = l; autoButton = auto
    }
}

final class DashedBorder: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        color.setStroke()
        p.stroke()
    }
}
