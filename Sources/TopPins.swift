import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Keep on Top. macOS doesn't let one app raise another app's window level, so a locked window is
/// shown as a live ScreenCaptureKit view in a floating panel placed exactly over it. While you work
/// in another app the live view sits on top; click it and the real window comes forward (the view
/// steps aside), and it returns on top as soon as you switch away.
@MainActor
enum TopPins {
    private(set) static var all: [TopPin] = []

    static func lock(_ w: SCWindow) {
        Diag.log("keep on top: lock window \(w.windowID) \(w.owningApplication?.applicationName ?? "?")")
        guard !all.contains(where: { $0.windowID == w.windowID }) else { Toast.show("That window is already on top"); return }
        let pin = TopPin(w)
        all.append(pin)
        pin.start()
        Toast.show("\(pin.name) stays on top. Hover it to unlock.")
    }

    static func unlock(_ pin: TopPin) {
        pin.stop()
        all.removeAll { $0 === pin }
    }

    static func unlockAll() { all.forEach { $0.stop() }; all.removeAll() }
}

@MainActor
final class TopPin: NSObject {
    let windowID: CGWindowID
    let pid: pid_t
    let name: String
    private let scWindow: SCWindow
    private var stream: SCStream?
    private var output: TopPinOutput?
    private let panel: TopPinPanel
    private let view: TopPinView
    private var timer: Timer?
    private var frame: CGRect = .zero // Cocoa coordinates
    private var streamSize: CGSize = .zero

    init(_ w: SCWindow) {
        scWindow = w
        windowID = w.windowID
        pid = w.owningApplication?.processID ?? 0
        let app = w.owningApplication?.applicationName ?? "Window"
        name = (w.title?.isEmpty == false) ? "\(app): \(w.title!)" : app
        panel = TopPinPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = TopPinView()
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        view.onClick = { [weak self] in self?.bringForward() }
        view.onUnlock = { [weak self] in if let self { TopPins.unlock(self) } }
    }

    func start() {
        guard let f = Self.currentFrame(windowID) else { Diag.log("keep on top: no frame for window \(windowID)"); return }
        Diag.log("keep on top: started at \(f)")
        place(f)
        panel.orderFrontRegardless()
        startStream()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stream?.stopCapture { _ in }
        stream = nil
        panel.orderOut(nil)
    }

    // MARK: Live view

    private func startStream() {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        streamSize = frame.size
        cfg.width = max(2, Int(frame.width * scale))
        cfg.height = max(2, Int(frame.height * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.queueDepth = 4
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let out = TopPinOutput { [weak self] surface in self?.view.show(surface) }
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        do {
            try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "glint.toppin"))
            s.startCapture { error in
                if let error { DispatchQueue.main.async { Toast.show("Couldn't keep it on top: \(error.localizedDescription)") } }
            }
            stream = s; output = out
        } catch {
            Toast.show("Couldn't keep it on top: \(error.localizedDescription)")
        }
    }

    /// Rescales the stream after the window is resized.
    private func resizeStream() {
        guard let s = stream, abs(streamSize.width - frame.width) > 1 || abs(streamSize.height - frame.height) > 1 else { return }
        streamSize = frame.size
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        cfg.width = max(2, Int(frame.width * scale))
        cfg.height = max(2, Int(frame.height * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.queueDepth = 4
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        s.updateConfiguration(cfg) { _ in }
    }

    // MARK: Following the real window

    private func tick() {
        guard let f = Self.currentFrame(windowID) else { TopPins.unlock(self); return } // closed
        if f != frame { place(f); resizeStream() }
        // Step aside while the real window is the one in use; float on top otherwise.
        let inUse = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && Self.frontWindow(of: pid) == windowID
        let minimized = !Self.isOnScreen(windowID)
        if inUse || minimized {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func place(_ f: CGRect) {
        frame = f
        panel.setFrame(f, display: true)
    }

    func testBringForward() { bringForward() }

    /// Activates the owning app and raises this exact window, then hides the live view over it.
    private func bringForward() {
        panel.orderOut(nil)
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            var list: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success, let wins = list as? [AXUIElement] {
                let target = wins.first { Self.axFrame($0).map { abs($0.minX - frame.minX) < 3 && abs($0.width - frame.width) < 3 } ?? false }
                if let t = target {
                    AXUIElementPerformAction(t, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(t, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: Window geometry (CGWindowList is top-left; Cocoa is bottom-left)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func currentFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)
    }

    static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// The app's frontmost normal window, from the window server's front-to-back order.
    static func frontWindow(of pid: pid_t) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func axFrame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }
}

/// Receives frames off the main thread and hands complete ones over as IOSurfaces.
final class TopPinOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @MainActor (IOSurfaceRef) -> Void
    init(onFrame: @escaping @MainActor (IOSurfaceRef) -> Void) { self.onFrame = onFrame }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(px)?.takeUnretainedValue() else { return }
        let cb = onFrame
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(surface) } }
    }
}

final class TopPinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Shows the live frames, a thin amber edge so you can tell it's locked, and an unlock button on hover.
final class TopPinView: NSView {
    var onClick: (() -> Void)?
    var onUnlock: (() -> Void)?
    private let content = CALayer()
    private let edge = CALayer()
    private let unlock = NSButton()
    private var hovering = false { didSet { unlock.isHidden = !hovering } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        content.contentsGravity = .resize
        content.cornerRadius = 10
        content.masksToBounds = true
        layer?.addSublayer(content)
        edge.borderColor = NSColor(srgbRed: 1, green: 0.698, blue: 0.102, alpha: 0.75).cgColor
        edge.borderWidth = 1.5
        edge.cornerRadius = 10
        layer?.addSublayer(edge)
        unlock.bezelStyle = .rounded
        unlock.isBordered = false
        unlock.wantsLayer = true
        unlock.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        unlock.layer?.cornerRadius = 13
        unlock.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Unlock")
        unlock.contentTintColor = .white
        unlock.title = " Unlock"
        unlock.imagePosition = .imageLeading
        unlock.font = .systemFont(ofSize: 12, weight: .semibold)
        unlock.attributedTitle = NSAttributedString(string: " Unlock", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        unlock.target = self
        unlock.action = #selector(unlockTapped)
        unlock.isHidden = true
        addSubview(unlock)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurfaceRef) {
        TopPinTest.frames += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.contents = surface
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = bounds
        edge.frame = bounds
        CATransaction.commit()
        unlock.frame = NSRect(x: bounds.maxX - 96, y: bounds.maxY - 38, width: 84, height: 26)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Unlock", action: #selector(unlockTapped), keyEquivalent: "").target = self
        return m
    }

    @objc private func unlockTapped() { onUnlock?() }
}

/// `--toptest <App Name>`: locks that app's front window on top and logs frames, placement and
/// visibility once a second for 12 seconds, then unlocks. Logs to /tmp/glint-scrolltest.log.
@MainActor
enum TopPinTest {
    static var frames = 0
    static func run(_ app: String) {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let c = try? await Capture.content(),
                  let w = Capture.pickableWindows(c).first(where: { $0.owningApplication?.applicationName == app || $0.title == app }) else {
                ScrollTest.log("toptest: no window for", app); NSApp.terminate(nil); return
            }
            TopPins.lock(w)
            for i in 1...12 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if i == 7 { ScrollTest.log("toptest: clicking the live view (AX trusted: \(AXIsProcessTrusted()))"); TopPins.all.first?.testBringForward() }
                guard let p = TopPins.all.first else { ScrollTest.log("toptest: pin gone at", i); break }
                let f = TopPin.currentFrame(w.windowID) ?? .zero
                let panel = NSApp.windows.first { $0 is TopPinPanel }
                ScrollTest.log("toptest t=\(i)s frames=\(frames) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") panelVisible=\(panel?.isVisible ?? false) panel=\(panel.map { NSStringFromRect($0.frame) } ?? "-") window=\(NSStringFromRect(f)) name=\(p.name)")
            }
            TopPins.unlockAll()
            ScrollTest.log("toptest: done")
        }
    }
}

/// `--pickertest <window title>`: runs the real Keep on Top action (picker overlay), clicks that window
/// with synthetic events, and logs each stage. Logs to /tmp/glint-scrolltest.log.
@MainActor
enum TopPickerTest {
    static func run(_ title: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ScrollTest.log("picker: screen recording =", CGPreflightScreenCaptureAccess(), "shortcut =", HotkeySettings.shared.shortcut(.keepOnTop)?.display ?? "none")
            AppController.shared.perform(.keepOnTop)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let ow = NSApp.windows.first(where: { $0 is OverlayWindow && $0.isVisible }),
                      let sv = ow.contentView as? SelectionView else { ScrollTest.log("picker: no overlay appeared"); NSApp.terminate(nil); return }
                ScrollTest.log("picker: overlay up, \(sv.windows.count) pickable windows")
                guard let target = sv.windows.first(where: { $0.0.title == title }) else {
                    ScrollTest.log("picker: target not in list:", sv.windows.prefix(6).map { $0.0.title ?? "?" }); NSApp.terminate(nil); return
                }
                let p = NSPoint(x: target.1.midX, y: target.1.midY)
                func ev(_ t: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: sv.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: ow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                sv.mouseMoved(with: ev(.mouseMoved)); sv.mouseDown(with: ev(.leftMouseDown)); sv.mouseUp(with: ev(.leftMouseUp))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ScrollTest.log("picker: locked windows =", TopPins.all.map(\.name), "frames =", TopPinTest.frames)
                    TopPins.unlockAll(); NSApp.terminate(nil)
                }
            }
        }
    }
}
