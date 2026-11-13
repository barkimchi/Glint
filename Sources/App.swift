import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            SelfTest.run(out: URL(fileURLWithPath: args[i + 1]))
            return
        }
        AppController.shared.start()
        if args.contains("--settings") { SettingsWindow.show() }
        if args.contains("--ring-open") { ActionRing.show() } // for screenshots of the ring
        if args.contains("--widget-open") { EdgeWidget.place(expanded: true) } // for screenshots of the widget
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            EditorWindow.open(URL(fileURLWithPath: args[i + 1])) // handy for testing the editor
        }
        if let i = args.firstIndex(of: "--shots"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Shots.write(to: dir); NSApp.terminate(nil) }
        }
    }
}

/// Owns the menu bar item, hotkeys and every capture flow.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyCenter()
    private var recorder: Recorder?
    private var recordBorder: NSWindow?
    private var clickOverlay: ClickOverlay?
    private var recordTimer: Timer?
    private var recordStart = Date()

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotkeys()
        EdgeWidget.restore()
        MiddleClick.start()

        Store.prune()
        if !CGPreflightScreenCaptureAccess() { _ = Permissions.ensure() }
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        hotkeys.unregisterAll()
        for a in HotkeyAction.allCases {
            guard let s = HotkeySettings.shared.shortcut(a) else { continue }
            hotkeys.register(Int(s.keyCode), Int(s.modifiers)) { [weak self] in self?.perform(a) }
        }
    }

    func unregisterHotkeys() { hotkeys.unregisterAll() }

    func perform(_ a: HotkeyAction) {
        switch a {
        case .area: captureArea()
        case .window: captureWindow()
        case .fullscreen: captureFullscreen()
        case .scroll: captureScrolling()
        case .page: capturePage()
        case .ocr: grabText()
        case .record: toggleRecording()
        case .claude: goToClaude()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if recorder != nil {
            menu.addItem(item("Stop Recording", .record, #selector(toggleRecording)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Capture Area", .area, #selector(captureArea)))
        menu.addItem(item("Capture Window", .window, #selector(captureWindow)))
        menu.addItem(item("Capture Fullscreen", .fullscreen, #selector(captureFullscreen)))
        menu.addItem(item("Scrolling Capture", .scroll, #selector(captureScrolling)))
        menu.addItem(item("Capture Full Page", .page, #selector(capturePage)))
        menu.addItem(item("Grab Text (OCR)", .ocr, #selector(grabText)))
        if recorder == nil { menu.addItem(item("Record Screen", .record, #selector(toggleRecording))) }
        menu.addItem(.separator())
        menu.addItem(item("Capture History…", nil, #selector(openHistory)))
        menu.addItem(item("Open Save Folder", nil, #selector(openSaved)))
        menu.addItem(item("Unlock Pinned Screenshots", nil, #selector(unlockPins)))
        menu.addItem(.separator())
        let settings = item("Settings…", nil, #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        let edge = item("Edge Widget", nil, #selector(toggleEdgeWidget))
        edge.state = EdgeWidget.isVisible ? .on : .off
        menu.addItem(edge)
        let ring = item("Middle-Click Action Ring", nil, #selector(toggleRing))
        ring.state = MiddleClick.enabled ? .on : .off
        menu.addItem(ring)
        let login = item("Launch at Login", nil, #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Grant Screen Recording Access…", nil, #selector(askPermission)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Menu items show the user's current global shortcut, if it is a single character.
    private func item(_ title: String, _ hotkey: HotkeyAction?, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let a = hotkey, let s = HotkeySettings.shared.shortcut(a), s.key.count == 1 {
            i.keyEquivalent = s.key.lowercased()
            i.keyEquivalentModifierMask = s.menuMask
        }
        i.target = self
        return i
    }

    private func setIdleIcon() {
        statusItem.button?.title = ""
        statusItem.button?.image = EdgeGlyph.menuBarImage()
    }

    // MARK: Actions

    @objc func captureArea() { select(.area) }
    @objc func captureWindow() { select(.window) }
    @objc func grabText() { select(.ocr) }
    /// Brings the Claude desktop app's window to the front, launching it if needed.
    @objc func goToClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            Toast.show("Claude desktop app not found"); return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
    @objc func capturePage() { if ScrollSession.active == nil { select(.page) } }
    @objc func toggleRing() { MiddleClick.enabled.toggle() }
    @objc func toggleEdgeWidget() { EdgeWidget.enabled = !EdgeWidget.isVisible }
    @objc func captureScrolling() { if ScrollSession.active == nil { select(.scroll) } }
    @objc func toggleRecording() { recorder != nil ? stopRecording() : select(.record) }
    @objc func openHistory() { HistoryWindow.show() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func openSaved() { NSWorkspace.shared.open(Store.savedDir) }
    @objc func unlockPins() { Pins.unlockAll() }
    @objc func askPermission() { _ = Permissions.ensure() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { Toast.show("Launch at login failed: \(error.localizedDescription)") }
    }

    @objc func captureFullscreen() {
        guard Permissions.ensure() else { return }
        Task {
            do {
                let c = try await Capture.content()
                let mouse = NSEvent.mouseLocation
                guard let scr = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
                      let d = c.displays.first(where: { Capture.screen(for: $0) == scr }) else { return }
                deliver(try await Capture.snapshot(d, content: c))
            } catch { fail(error) }
        }
    }

    private func select(_ mode: CaptureMode) {
        guard SelectionSession.active == nil, Permissions.ensure() else { return }
        Task {
            do {
                let c = try await Capture.content()
                var frozen: [Frozen] = []
                for d in c.displays {
                    guard let s = Capture.screen(for: d) else { continue }
                    frozen.append(Frozen(screen: s, display: d, image: try await Capture.snapshot(d, content: c)))
                }
                let wins = mode.picksWindow ? Capture.pickableWindows(c) : []
                SelectionSession.start(frozen: frozen, mode: mode, windows: wins) { [weak self] r in
                    self?.handle(r, mode: mode)
                }
            } catch { fail(error) }
        }
    }

    private func handle(_ r: SelectionResult, mode: CaptureMode) {
        switch r {
        case .cancel: return
        case .window(let w):
            Task {
                do { deliver(try await Capture.window(w)) } catch { fail(error) }
            }
        case .page(let f, let rect, let w):
            // Bring the clicked app forward so nothing covers the page while it scrolls.
            if let pid = w.owningApplication?.processID { NSRunningApplication(processIdentifier: pid)?.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ScrollSession(frozen: f, rect: rect, page: true) { [weak self] img in
                    if let img { self?.deliver(img) }
                }.start()
            }
        case .area(let f, let rect):
            switch mode {
            case .record:
                startRecording(f, rect)
            case .scroll:
                ScrollSession(frozen: f, rect: rect) { [weak self] img in
                    if let img { self?.deliver(img) }
                }.start()
            case .ocr:
                guard let img = Capture.crop(f, rect) else { return }
                Task {
                    let text = await OCR.recognize(img)
                    if text.isEmpty { Toast.show("No text found"); return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    let n = text.split(separator: "\n").count
                    Toast.show("Copied \(n) line\(n == 1 ? "" : "s") of text")
                }
            default:
                if let img = Capture.crop(f, rect) { deliver(img) }
            }
        }
    }

    private func deliver(_ img: CGImage) {
        guard let url = Store.savePNG(img) else { Toast.show("Could not save capture"); return }
        QuickAccess.show(url: url, isVideo: false)
    }

    private func fail(_ error: Error) {
        Toast.show("Capture failed: \(error.localizedDescription)")
    }

    // MARK: Recording

    private func startRecording(_ f: Frozen, _ r: CGRect) {
        let src = CGRect(x: r.minX, y: f.screen.frame.height - r.maxY, width: r.width, height: r.height).integral
        let rec = Recorder(url: Store.newURL(ext: "mp4"))
        recorder = rec
        let global = r.offsetBy(dx: f.screen.frame.minX, dy: f.screen.frame.minY)
        showBorder(global)
        let showKeys = RecordingSettings.showKeystrokes && AXIsProcessTrusted()
        if RecordingSettings.highlightClicks || showKeys {
            let o = ClickOverlay(globalRect: global, clicks: RecordingSettings.highlightClicks, keys: showKeys)
            o.show()
            clickOverlay = o
        }
        Task {
            do {
                // Re-fetch so our border window's app is known and can be excluded from the video.
                let c = try await Capture.content()
                var audio = AudioOptions(system: RecordingSettings.systemAudio, microphone: RecordingSettings.microphone)
                if audio.microphone, !(await RecordingSettings.ensureMicAccess()) {
                    audio.microphone = false
                    Toast.show("Microphone access is off for Glint, recording without it")
                }
                let include = clickOverlay.flatMap { $0.scWindow(in: c) }.map { [$0] } ?? []
                try await rec.start(display: f.display, source: src, scale: f.screen.backingScaleFactor,
                                    exclude: Capture.ownApps(c), include: include, audio: audio)
                recordStart = Date()
                statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
                recordTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                tick()
            } catch {
                recorder = nil
                hideBorder()
                fail(error)
            }
        }
    }

    private func tick() {
        let s = Int(Date().timeIntervalSince(recordStart))
        statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
    }

    private func stopRecording() {
        guard let rec = recorder else { return }
        recorder = nil
        recordTimer?.invalidate(); recordTimer = nil
        hideBorder()
        setIdleIcon()
        Task {
            if RecordingSettings.systemAudio && RecordingSettings.microphone { Toast.show("Mixing audio…") }
            if let url = await rec.stop() { QuickAccess.show(url: url, isVideo: true) }
            else { Toast.show("Recording failed (no frames captured)") }
        }
    }

    private func showBorder(_ r: CGRect) {
        let w = NSWindow(contentRect: r.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = BorderView()
        w.orderFrontRegardless()
        recordBorder = w
    }

    private func hideBorder() {
        recordBorder?.orderOut(nil)
        recordBorder = nil
        clickOverlay?.hide()
        clickOverlay = nil
    }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        p.stroke()
    }
}

// MARK: - Hotkeys

/// Global shortcuts via Carbon's RegisterEventHotKey: old API, still the standard way
/// to get system-wide hotkeys without Accessibility permission.
final class HotkeyCenter {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotkeyCenter>.fromOpaque(ctx!).takeUnretainedValue()
            let id = hk.id
            DispatchQueue.main.async { me.handlers[id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func unregisterAll() {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    func register(_ keyCode: Int, _ modifiers: Int, _ action: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x474C_4E54), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Permissions

@MainActor
enum Permissions {
    /// Returns true when we may capture. Otherwise explains and offers System Settings.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Glint needs Screen Recording access"
        a.informativeText = "Turn on Glint in System Settings > Privacy & Security > Screen & System Audio Recording. macOS may ask you to quit and reopen Glint afterwards."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

// MARK: - Toast

@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 36)
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        bg.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        bg.addSubview(label)
        p.contentView = bg
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}

/// Renders every open Glint window straight to a PNG, with no desktop behind it.
/// Used to make the README screenshots: `Glint --settings --ring-open --shots <dir>`.
@MainActor
enum Shots {
    static func write(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for w in NSApp.windows where w.isVisible {
            guard let content = w.contentView else { continue }
            let view = w.styleMask.contains(.titled) ? (content.superview ?? content) : content
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = w.title.isEmpty ? "panel-\(Int(view.bounds.width))x\(Int(view.bounds.height))" : w.title.lowercased().filter { $0.isLetter }
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }
}
