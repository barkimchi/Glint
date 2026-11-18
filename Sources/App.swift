import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import Sparkle

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
        if args.contains("--ring-open") { ActionRing.show(); if let f = ActionRing.frame { ScrollTest.log("ring frame", Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) } } // for screenshots of the ring
        if args.contains("--ring-selftest") { RingSelfTest.run() }
        if let i = args.firstIndex(of: "--pile-test"), i + 1 < args.count { PileTest.run(URL(fileURLWithPath: args[i + 1])); return }
        if args.contains("--emoji-selftest") { EmojiSelfTest.run(); return }
        if args.contains("--trackpad-selftest") { TrackpadControls.selfTest(); NSApp.terminate(nil); return }
        if args.contains("--tour-capture-test") { TourCaptureTest.run() }
        if let i = args.firstIndex(of: "--toptest"), i + 1 < args.count { TopPinTest.run(args[i + 1]) }
        if let i = args.firstIndex(of: "--pickertest"), i + 1 < args.count { TopPickerTest.run(args[i + 1]) }
        if let i = args.firstIndex(of: "--frame"), i + 3 < args.count { // --frame in.png out.png <preset>: README stills
            if let cg = Store.cgImage(URL(fileURLWithPath: args[i + 1])) {
                let m = EditorModel(image: cg)
                m.backdrop = Backdrop.allCases.first { $0.name.lowercased() == args[i + 3].lowercased() } ?? .sunrise
                if let out = m.render() { try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2])) }
            }
            NSApp.terminate(nil); return
        }
        if let i = args.firstIndex(of: "--editor-selftest"), i + 1 < args.count { EditorSelfTest.run(args[i + 1]); return }
        if let i = args.firstIndex(of: "--demo"), i + 3 < args.count { Demo.run(args[i + 1], scene: args[i + 2], rect: args[i + 3]) }
        if args.contains("--ring-edit") { // for screenshots of the ring's edit mode; logs the panel frame
            ActionRing.showEditing()
            if let f = ActionRing.frame { ScrollTest.log("ring frame", Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        }
        if args.contains("--widget-open") { EdgeWidget.place(expanded: true) } // for screenshots of the widget
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            EditorWindow.open(URL(fileURLWithPath: args[i + 1])) // handy for testing the editor
        }
        if let i = args.firstIndex(of: "--pin"), i + 1 < args.count {
            Pins.pin(URL(fileURLWithPath: args[i + 1])) // handy for testing pin sizing
        }
        if let i = args.firstIndex(of: "--scrolltest"), i + 1 < args.count {
            ScrollTest.log("scrolltest: start", args[i + 1]); ScrollTest.run(args[i + 1]) // "x,y,w,h" in screen points, top-left origin
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
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: BetaUpdates.delegate, userDriverDelegate: nil)

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotkeys()
        EdgeWidget.restore()
        MiddleClick.start()
        TrackpadControls.apply()
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { RingLayout.addNewActionsOnce() } // tests never touch the saved popup

        Store.prune()
        // New users get the welcome tour (it handles the permission); updaters get What's New.
        let args = CommandLine.arguments
        if args.contains("--tour") { Onboarding.showTour() }
        else if args.contains("--whats-new") { Onboarding.showWhatsNew() }
        else if args.contains(where: { $0.hasPrefix("--") }) { } // test and demo runs stay quiet
        else if !Onboarding.showIfNeeded(), !CGPreflightScreenCaptureAccess() { _ = Permissions.ensure() }
    }

    /// Blinks the menu bar icon so a new user can find it.
    func flashStatusItem() {
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.28) { [weak self] in
                self?.statusItem.button?.highlight(i % 2 == 0)
            }
        }
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        hotkeys.unregisterAll()
        for a in HotkeyAction.allCases {
            guard let s = HotkeySettings.shared.shortcut(a) else { continue }
            Diag.log("hotkey for \(a.rawValue): \(s.display)")
            hotkeys.register(Int(s.keyCode), Int(s.modifiers)) { [weak self] in self?.perform(a) }
        }
    }

    func unregisterHotkeys() { hotkeys.unregisterAll() }

    func perform(_ a: HotkeyAction) {
        Diag.log("perform \(a.rawValue)")
        switch a {
        case .area: captureArea()
        case .window: captureWindow()
        case .fullscreen: captureFullscreen()
        case .scroll: captureScrolling()
        case .page: capturePage()
        case .ocr: grabText()
        case .record: toggleRecording()
        case .claude: goToClaude()
        case .keepOnTop: keepWindowOnTop()
        case .emoji: EmojiPicker.open()
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
        menu.addItem(item("Keep Window on Top…", .keepOnTop, #selector(keepWindowOnTop)))
        if !TopPins.all.isEmpty {
            let top = NSMenuItem(title: "Windows on Top", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, p) in TopPins.all.enumerated() {
                let it = NSMenuItem(title: "Unlock \(p.name)", action: #selector(unlockTopPin(_:)), keyEquivalent: "")
                it.target = self; it.tag = i
                sub.addItem(it)
            }
            sub.addItem(.separator())
            let allItem = NSMenuItem(title: "Unlock All", action: #selector(unlockAllTopPins), keyEquivalent: "")
            allItem.target = self
            sub.addItem(allItem)
            top.submenu = sub
            menu.addItem(top)
        }
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
        if !Access.trusted {
            menu.addItem(item("Fix Accessibility Access…", nil, #selector(fixAccess)))
        }
        menu.addItem(item("Welcome Tour…", nil, #selector(openTour)))
        menu.addItem(item("What's New…", nil, #selector(openWhatsNew)))
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = updaterController
        menu.addItem(updates)
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
    @objc func keepWindowOnTop() { select(.keepOnTop) }
    @objc func unlockTopPin(_ m: NSMenuItem) {
        if TopPins.all.indices.contains(m.tag) { TopPins.unlock(TopPins.all[m.tag]) }
    }
    @objc func unlockAllTopPins() { TopPins.unlockAll() }
    @objc func grabText() { select(.ocr) }
    /// Brings the chosen app (Claude unless changed in Settings) to the front, launching it if needed.
    @objc func goToClaude() {
        guard let url = AppTarget.url else { Toast.show("\(AppTarget.name) not found"); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
    @objc func capturePage() { if ScrollSession.active == nil { select(.page) } }
    @objc func toggleRing() { MiddleClick.enabled.toggle() }
    @objc func fixAccess() { Access.explain() }
    @objc func toggleEdgeWidget() { EdgeWidget.enabled = !EdgeWidget.isVisible }
    @objc func captureScrolling() { if ScrollSession.active == nil { select(.scroll) } }
    @objc func toggleRecording() { recorder != nil ? stopRecording() : select(.record) }
    @objc func openHistory() { HistoryWindow.show() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func openTour() { Onboarding.showTour() }
    @objc func openWhatsNew() { Onboarding.showWhatsNew() }
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
        Diag.log("select \(mode) active=\(SelectionSession.active != nil) screenRecording=\(CGPreflightScreenCaptureAccess())")
        guard SelectionSession.active == nil, Permissions.ensure() else { Diag.log("select \(mode) blocked"); return }
        Task {
            do {
                let c = try await Capture.content()
                var frozen: [Frozen] = []
                for d in c.displays {
                    guard let s = Capture.screen(for: d) else { continue }
                    frozen.append(Frozen(screen: s, display: d, image: try await Capture.snapshot(d, content: c)))
                }
                let wins = mode.picksWindow ? Capture.pickableWindows(c) : []
                Diag.log("picker shown: \(frozen.count) displays, \(wins.count) windows")
                SelectionSession.start(frozen: frozen, mode: mode, windows: wins) { [weak self] r in
                    self?.handle(r, mode: mode)
                }
            } catch { Diag.log("select failed: \(error)"); fail(error) }
        }
    }

    private func handle(_ r: SelectionResult, mode: CaptureMode) {
        Diag.log("selection result \(r) mode=\(mode)")
        switch r {
        case .cancel: return
        case .window(let w) where mode == .keepOnTop:
            TopPins.lock(w)
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
                // Starts scrolling on its own; press Stop Auto on the bar to scroll by hand instead.
                ScrollSession(frozen: f, rect: rect, auto: true) { [weak self] img in
                    if let img { self?.deliver(img) }
                }.start()
            case .ocr:
                guard let img = Capture.crop(f, rect) else { Diag.log("ocr: crop failed for \(rect)"); return }
                Task {
                    let text = await OCR.recognize(img)
                    Diag.log("ocr: \(img.width)x\(img.height) -> \(text.split(separator: "\n").count) lines")
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
        // Every screenshot also lands in the save folder right away.
        if Store.exportCopy(url) == nil { Toast.show("Could not save a copy to your save folder") }
        QuickAccess.show(url: url, isVideo: false)
        NotificationCenter.default.post(name: Onboarding.didCapture, object: nil)
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
/// Plain-text trace of actions, for diagnosing "nothing happened" reports: ~/Library/Logs/Glint/glint.log.
enum Diag {
    private static let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Glint")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glint.log")
    }()
    /// Off unless turned on: defaults write com.barkimchi.glint debug.log -bool YES
    static func log(_ s: String) {
        guard UserDefaults.standard.bool(forKey: "debug.log") else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

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
            Diag.log("hotkey pressed id=\(id)")
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
        let st = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x474C_4E54), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        Diag.log("register hotkey id=\(id) key=\(keyCode) mods=\(modifiers) status=\(st)")
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
        Front.raise(a.window)
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
        // On the screen you're working on (NSScreen.main follows the focused window, often another display).
        guard let screen = Front.pointerScreen else { return }
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

/// `--scrolltest x,y,w,h`: runs an auto-scrolling capture on that region (top-left origin points),
/// prints the stitched height and saves it to /tmp/glint-scrolltest.png, then quits.
@MainActor
enum ScrollTest {
    static func log(_ items: Any...) {
        let line = items.map { "\($0)" }.joined(separator: " ") + "\n"
        let url = URL(fileURLWithPath: "/tmp/glint-scrolltest.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
    static func run(_ spec: String) {
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { log("scrolltest: need x,y,w,h"); NSApp.terminate(nil); return }
        Task {
            do {
                let c = try await Capture.content()
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                let g = CGRect(x: n[0], y: primaryH - n[1] - n[3], width: n[2], height: n[3]) // to bottom-left global
                guard let d = c.displays.first(where: { Capture.screen(for: $0)?.frame.intersects(g) == true }),
                      let s = Capture.screen(for: d) else { log("scrolltest: no display"); NSApp.terminate(nil); return }
                let f = Frozen(screen: s, display: d, image: try await Capture.snapshot(d, content: c))
                let local = g.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY)
                log("scrolltest: AX trusted =", AXIsProcessTrusted())
                ScrollSession(frozen: f, rect: local, auto: true) { img in
                    if let img {
                        log("scrolltest: stitched \(img.width)x\(img.height) px")
                        let rep = NSBitmapImageRep(cgImage: img)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/glint-scrolltest.png"))
                    } else { log("scrolltest: no image") }
                    NSApp.terminate(nil)
                }.start()
            } catch { log("scrolltest: \(error)"); NSApp.terminate(nil) }
        }
    }
}
