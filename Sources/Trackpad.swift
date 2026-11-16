import AppKit
import CoreAudio
import Darwin
import ObjectiveC

// Trackpad edge controls. Raw touches come from Apple's private MultitouchSupport framework,
// loaded at runtime so Glint keeps working (with this feature off) if a macOS update changes it.
// Approach adapted from EdgePad (github.com/forkiron/EdgePad, MIT License).

// MARK: - Settings

enum EdgeControl: String, CaseIterable, Identifiable {
    case volume, brightness, off
    var id: String { rawValue }
    var title: String { ["volume": "Volume", "brightness": "Brightness", "off": "Off"][rawValue]! }
}

enum TrackpadSettings {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.bool(forKey: "trackpad.enabled") }
        set { d.set(newValue, forKey: "trackpad.enabled") }
    }
    static var leftEdge: EdgeControl {
        get { EdgeControl(rawValue: d.string(forKey: "trackpad.left") ?? "") ?? .volume }
        set { d.set(newValue.rawValue, forKey: "trackpad.left") }
    }
    static var rightEdge: EdgeControl {
        get { EdgeControl(rawValue: d.string(forKey: "trackpad.right") ?? "") ?? .brightness }
        set { d.set(newValue.rawValue, forKey: "trackpad.right") }
    }
    /// Touch-and-hold in a top corner: "off", "popup", or a Glint action's raw value.
    static var topLeft: String {
        get { d.string(forKey: "trackpad.topLeft") ?? "popup" }
        set { d.set(newValue, forKey: "trackpad.topLeft") }
    }
    static var topRight: String {
        get { d.string(forKey: "trackpad.topRight") ?? HotkeyAction.area.rawValue }
        set { d.set(newValue, forKey: "trackpad.topRight") }
    }
    static let cornerChoices: [(String, String)] = [("off", "Off"), ("popup", "Open the popup")] + HotkeyAction.allCases.map { ($0.rawValue, $0.title) }
    /// How far a full slide along the edge moves the value (1 = the whole height for 0 to 100%).
    static var sensitivity: Double {
        get { d.object(forKey: "trackpad.sensitivity") as? Double ?? 1.56 }
        set { d.set(newValue, forKey: "trackpad.sensitivity") }
    }
    /// Width of each edge zone as a fraction of the trackpad width.
    static var zone: Double {
        get { d.object(forKey: "trackpad.zone") as? Double ?? 0.09 }
        set { d.set(newValue, forKey: "trackpad.zone") }
    }
}

// MARK: - Touches

struct Touch {
    let id: Int32
    let x: Float, y: Float     // 0...1, origin bottom-left
    let size: Float            // contact size, a pressure proxy
    let major: Float, minor: Float
    let phase: Phase
    let time: Double
    enum Phase { case began, moved, ended }
    var aspect: Float { minor > 0.001 ? max(major, minor) / max(0.001, min(major, minor)) : 1 }
}

/// Memory layout of one contact as MultitouchSupport delivers it.
private struct MTContact {
    var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32
    var unknown1: Int32; var unknown2: Int32
    var posX: Float; var posY: Float; var velX: Float; var velY: Float
    var size: Float; var unknown3: Int32; var angle: Float; var majorAxis: Float; var minorAxis: Float
    var u4a: Float; var u4b: Float; var u4c: Float; var u4d: Float
    var unknown5a: Int32; var unknown5b: Int32; var unknown6: Float
}

private typealias MTCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// Reads raw contact frames from every full-size trackpad (built-in or Magic Trackpad).
@MainActor
enum MultitouchReader {
    private static var devices: [UnsafeMutableRawPointer] = []
    private static var unregister: (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void)?
    private static var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    static var onFrame: (([Touch]) -> Void)?
    private(set) static var deviceCount = 0

    /// Returns false when the framework or a trackpad isn't available.
    @discardableResult
    static func start() -> Bool {
        guard devices.isEmpty else { return true }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let createList = dlsym(h, "MTDeviceCreateList"),
              let register = dlsym(h, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(h, "MTDeviceStart") else { Diag.log("trackpad: MultitouchSupport unavailable"); return false }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        typealias Dims = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
        if let s = dlsym(h, "MTUnregisterContactFrameCallback") { unregister = unsafeBitCast(s, to: (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void).self) }
        if let s = dlsym(h, "MTDeviceStop") { stopDevice = unsafeBitCast(s, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self) }
        let dims = dlsym(h, "MTDeviceGetSensorDimensions").map { unsafeBitCast($0, to: Dims.self) }
        guard let list = unsafeBitCast(createList, to: CreateList.self)()?.takeRetainedValue() else { return false }
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var rows: Int32 = 0, cols: Int32 = 0
            _ = dims?(dev, &rows, &cols)
            Diag.log("trackpad: device \(i) sensor \(rows)x\(cols)")
            guard rows >= 10 else { continue } // skip auxiliary sensors (e.g. 60x2 strips)
            unsafeBitCast(register, to: Register.self)(dev, contactCallback)
            unsafeBitCast(startSym, to: Start.self)(dev, 0)
            devices.append(dev)
        }
        deviceCount = devices.count
        Diag.log("trackpad: started \(devices.count) device(s)")
        return !devices.isEmpty
    }

    static func stop() {
        for d in devices { unregister?(d, contactCallback); stopDevice?(d) }
        devices.removeAll(); deviceCount = 0
    }

    fileprivate static func deliver(_ touches: [Touch]) { onFrame?(touches) }
}

private func contactCallback(_ device: Int32, _ data: UnsafeMutableRawPointer?, _ n: Int32, _ time: Double, _ frame: Int32) -> Int32 {
    var touches: [Touch] = []
    if let data, n > 0 {
        let c = data.assumingMemoryBound(to: MTContact.self)
        for i in 0..<Int(n) {
            let t = c[i]
            let phase: Touch.Phase
            switch t.state { case 1, 3: phase = .began; case 5, 7: phase = .ended; default: phase = .moved }
            touches.append(Touch(id: t.identifier, x: t.posX, y: t.posY, size: t.size, major: t.majorAxis, minor: t.minorAxis, phase: phase, time: time))
        }
    }
    let snapshot = touches
    DispatchQueue.main.async { MainActor.assumeIsolated { MultitouchReader.deliver(snapshot) } }
    return 0
}

// MARK: - Gestures

/// Turns touch frames into edge slides and corner holds. Pure logic, so it can be tested with made-up touches.
@MainActor
final class EdgeGestures {
    enum Edge { case left, right }
    enum Corner { case topLeft, topRight }
    var onSlideBegan: ((Edge) -> Void)?
    var onSlide: ((Edge, Float) -> Void)?   // total vertical travel since the slide began (+ = up)
    var onSlideEnded: ((Edge) -> Void)?
    var onCornerHold: ((Corner) -> Void)?

    var zone: Float = 0.09
    let cornerSize: Float = 0.14
    let deadZone: Float = 0.012     // travel before a slide counts, so a resting finger does nothing
    let holdTime: Double = 0.45
    let holdSlop: Float = 0.02
    let typingPause: Double = 0.3
    var lastKeyTime: Double = -1000

    private var track: (id: Int32, edge: Edge?, corner: Corner?, startX: Float, startY: Float, startTime: Double, sliding: Bool, fired: Bool)?
    private var ignored: Set<Int32> = []

    private func isPalm(_ t: Touch) -> Bool { t.size > 2.2 || (t.size > 1.3 && t.aspect > 1.8) }

    func handle(_ touches: [Touch]) {
        // Only single-finger gestures; two or more fingers belong to macOS (scrolling, swipes).
        if touches.count != 1 {
            if let s = track, s.sliding, let e = s.edge { onSlideEnded?(e) }
            track = nil
            touches.forEach { ignored.insert($0.id) }
            if touches.isEmpty { ignored.removeAll() }
            return
        }
        let t = touches[0]
        if t.phase == .ended || ignored.contains(t.id) {
            if let s = track, s.id == t.id, s.sliding, let e = s.edge { onSlideEnded?(e) }
            if t.phase == .ended { track = nil; ignored.remove(t.id) }
            return
        }
        guard let s = track, s.id == t.id else {
            // A new finger: it only counts if it lands in an edge zone or corner, and isn't a palm or typing.
            if isPalm(t) || t.time - lastKeyTime < typingPause { ignored.insert(t.id); return }
            let corner: Corner? = t.y > 1 - cornerSize ? (t.x < cornerSize ? .topLeft : (t.x > 1 - cornerSize ? .topRight : nil)) : nil
            let edge: Edge? = t.x < zone ? .left : (t.x > 1 - zone ? .right : nil)
            if corner == nil && edge == nil { ignored.insert(t.id); return }
            track = (t.id, edge, corner, t.x, t.y, t.time, false, false)
            return
        }
        if isPalm(t) { if s.sliding, let e = s.edge { onSlideEnded?(e) }; track = nil; ignored.insert(t.id); return }
        let dx = t.x - s.startX, dy = t.y - s.startY
        if s.sliding, let e = s.edge {
            // Keep sliding while the finger stays near its edge.
            let near = e == .left ? t.x < zone * 2.2 : t.x > 1 - zone * 2.2
            if near { onSlide?(e, dy) } else { onSlideEnded?(e); track = nil; ignored.insert(t.id) }
            return
        }
        // Corner hold: still finger for holdTime.
        if let c = s.corner, !s.fired, abs(dx) < holdSlop, abs(dy) < holdSlop, t.time - s.startTime >= holdTime {
            track?.fired = true
            onCornerHold?(c)
            return
        }
        // Edge slide: mostly vertical travel past the dead zone.
        if let e = s.edge, !s.fired, abs(dy) > deadZone {
            if abs(dx) > abs(dy) * 0.8 { track = nil; ignored.insert(t.id); return } // a horizontal swipe, not a slide
            track?.sliding = true
            track?.startY = t.y
            onSlideBegan?(e)
        }
    }
}

// MARK: - System controls

@MainActor
enum SystemVolume {
    private static func device() -> AudioObjectID? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr ? id : nil
    }
    static var value: Float {
        get {
            guard let dev = device() else { return 0 }
            var best: Float = 0
            for el: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
                guard AudioObjectHasProperty(dev, &a) else { continue }
                var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { best = max(best, v) }
            }
            return best
        }
        set {
            guard let dev = device() else { return }
            var v = Float32(max(0, min(1, newValue)))
            let size = UInt32(MemoryLayout<Float32>.size)
            var main = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(dev, &main), AudioObjectSetPropertyData(dev, &main, 0, nil, size, &v) == noErr { return }
            for ch: AudioObjectPropertyElement in [1, 2] {
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: ch)
                if AudioObjectHasProperty(dev, &a) { AudioObjectSetPropertyData(dev, &a, 0, nil, size, &v) }
            }
        }
    }
}

/// Built-in and Apple display brightness, through the private DisplayServices framework.
@MainActor
enum DisplayBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let fns: (Get, Set)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: Get.self), unsafeBitCast(s, to: Set.self))
    }()
    private static var display: CGDirectDisplayID {
        let m = NSEvent.mouseLocation
        let s = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        return (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    /// nil when the display under the pointer can't be dimmed this way (most third-party monitors).
    static var value: Float? {
        guard let (get, _) = fns else { return nil }
        var v: Float = -1
        return get(display, &v) == 0 && v >= 0 ? v : nil
    }
    static func set(_ v: Float) { if let (_, set) = fns { _ = set(display, max(0, min(1, v))) } }
}

/// The system's own volume and brightness bubble (private OSD framework); does nothing if unavailable.
@MainActor
enum SystemHUD {
    private typealias Show = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
    private static let loaded: (AnyObject, Selector, Show)? = {
        guard let b = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework"), b.load(),
              let cls = NSClassFromString("OSDManager"),
              let shared = class_getClassMethod(cls, NSSelectorFromString("sharedManager")) else { return nil }
        typealias Shared = @convention(c) (AnyClass, Selector) -> AnyObject
        let mgr = unsafeBitCast(method_getImplementation(shared), to: Shared.self)(cls, NSSelectorFromString("sharedManager"))
        let sel = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard let m = class_getInstanceMethod(cls, sel) else { return nil }
        return (mgr, sel, unsafeBitCast(method_getImplementation(m), to: Show.self))
    }()
    static func volume(_ v: Float) { show(v <= 0.001 ? 4 : 3, v) }
    static func brightness(_ v: Float) { show(1, v) }
    private static func show(_ graphic: Int64, _ v: Float) {
        guard let (mgr, sel, f) = loaded else { return }
        f(mgr, sel, graphic, CGMainDisplayID(), 0x1F4, 1000, UInt32((max(0, min(1, v)) * 16).rounded()), 16, false)
    }
}

// MARK: - Controller

@MainActor
enum TrackpadControls {
    private static let gestures = EdgeGestures()
    private static var startValue: Float = 0
    private static var keyMonitor: Any?
    private static var warnedBrightness = false

    static func apply() { stop(); if TrackpadSettings.enabled { start() } }

    static func start() {
        gestures.zone = Float(TrackpadSettings.zone)
        gestures.onSlideBegan = { edge in
            CGAssociateMouseAndMouseCursorPosition(0) // hold the pointer still while sliding
            switch control(edge) {
            case .volume: startValue = SystemVolume.value
            case .brightness:
                if let v = DisplayBrightness.value { startValue = v }
                else if !warnedBrightness { warnedBrightness = true; Toast.show("This display's brightness can't be changed from the trackpad. Pick another control in Settings.") }
            case .off: break
            }
        }
        gestures.onSlide = { edge, travel in
            let v = max(0, min(1, startValue + travel * Float(TrackpadSettings.sensitivity)))
            switch control(edge) {
            case .volume: SystemVolume.value = v; SystemHUD.volume(v)
            case .brightness: if DisplayBrightness.value != nil { DisplayBrightness.set(v); SystemHUD.brightness(v) }
            case .off: break
            }
        }
        gestures.onSlideEnded = { _ in CGAssociateMouseAndMouseCursorPosition(1) }
        gestures.onCornerHold = { corner in
            guard (corner == .topLeft ? TrackpadSettings.topLeft : TrackpadSettings.topRight) != "off" else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            let choice = corner == .topLeft ? TrackpadSettings.topLeft : TrackpadSettings.topRight
            if choice == "popup" { ActionRing.toggle() }
            else if let a = HotkeyAction(rawValue: choice) { AppController.shared.perform(a) }
        }
        MultitouchReader.onFrame = { gestures.handle($0) }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
                MainActor.assumeIsolated { gestures.lastKeyTime = ProcessInfo.processInfo.systemUptime }
            }
        }
        if !MultitouchReader.start() { Toast.show("No trackpad found for trackpad controls") }
    }

    static func stop() {
        MultitouchReader.stop()
        MultitouchReader.onFrame = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    /// One line for Settings: whether Glint is reading a trackpad right now.
    static var status: String {
        guard TrackpadSettings.enabled else { return "Off" }
        let n = MultitouchReader.deviceCount
        return n == 0 ? "No trackpad found on this Mac" : "Listening to \(n == 1 ? "the trackpad" : "\(n) trackpads")"
    }

    private static func control(_ e: EdgeGestures.Edge) -> EdgeControl { e == .left ? TrackpadSettings.leftEdge : TrackpadSettings.rightEdge }

    // MARK: Self-test with made-up touches

    /// `--trackpad-selftest`: feeds synthetic touches through the gesture logic and logs what fired.
    static func selfTest() {
        let g = EdgeGestures()
        var log: [String] = []
        g.onSlideBegan = { log.append("slideBegan \($0)") }
        g.onSlide = { e, d in if log.last?.hasPrefix("slide \(e)") == true { log.removeLast() }; log.append("slide \(e) \(String(format: "%.2f", d))") }
        g.onSlideEnded = { log.append("slideEnded \($0)") }
        g.onCornerHold = { log.append("cornerHold \($0)") }
        func t(_ id: Int32, _ x: Float, _ y: Float, _ p: Touch.Phase, _ time: Double, size: Float = 0.8, major: Float = 8, minor: Float = 7) -> [Touch] {
            [Touch(id: id, x: x, y: y, size: size, major: major, minor: minor, phase: p, time: time)]
        }
        func run(_ name: String, _ frames: [[Touch]]) {
            log = []
            frames.forEach { g.handle($0) }
            g.handle([])
            ScrollTest.log("trackpad-selftest \(name): \(log.isEmpty ? "nothing" : log.joined(separator: ", "))")
        }
        /// Frames 1...n of one finger moving by (dx, dy) per frame from (x0, y0).
        func moves(_ id: Int32, _ n: Int, _ x0: Float, _ y0: Float, dx: Float, dy: Float, t0: Double = 0,
                   size: Float = 0.8, major: Float = 8, minor: Float = 7) -> [[Touch]] {
            var out: [[Touch]] = []
            for i in 1...n {
                let f = Float(i)
                let time: Double = t0 + Double(i) * 0.016
                out.append(t(id, x0 + f * dx, y0 + f * dy, .moved, time, size: size, major: major, minor: minor))
            }
            return out
        }
        // Left edge slide up 0.3
        run("left slide up", [t(1, 0.04, 0.3, .began, 0)] + moves(1, 10, 0.04, 0.3, dx: 0, dy: 0.03) + [t(1, 0.04, 0.6, .ended, 0.2)])
        // Right edge slide down
        run("right slide down", [t(2, 0.96, 0.6, .began, 0)] + moves(2, 8, 0.96, 0.6, dx: 0, dy: -0.025) + [t(2, 0.96, 0.4, .ended, 0.2)])
        // Middle of the pad: ordinary cursor movement, must do nothing
        run("middle move", [t(3, 0.5, 0.5, .began, 0)] + moves(3, 10, 0.5, 0.5, dx: 0, dy: 0.03))
        // Horizontal swipe starting at the left edge: not a slide
        run("edge horizontal swipe", [t(4, 0.04, 0.5, .began, 0)] + moves(4, 10, 0.04, 0.5, dx: 0.04, dy: 0.002))
        // Resting finger in the left edge, jittering a hair: nothing
        var resting: [[Touch]] = [t(5, 0.04, 0.5, .began, 0)]
        for i in 1...30 { resting.append(t(5, 0.04, i % 2 == 0 ? 0.5 : 0.502, .moved, Double(i) * 0.016)) }
        run("edge resting finger", resting)
        // Top-right corner hold
        run("top-right hold", [t(6, 0.95, 0.95, .began, 0)] + moves(6, 40, 0.95, 0.95, dx: 0, dy: 0))
        // Top-left corner hold that drifts: no fire
        run("top-left drift", [t(7, 0.05, 0.95, .began, 0)] + moves(7, 40, 0.05, 0.95, dx: 0.002, dy: 0))
        // Palm on the edge
        run("edge palm", [t(8, 0.04, 0.3, .began, 0, size: 2.6, major: 20, minor: 9)] + moves(8, 10, 0.04, 0.3, dx: 0, dy: 0.03, size: 2.6, major: 20, minor: 9))
        // Slide right after typing: suppressed
        g.lastKeyTime = 5.0
        run("slide while typing", [t(9, 0.04, 0.3, .began, 5.1)] + moves(9, 10, 0.04, 0.3, dx: 0, dy: 0.03, t0: 5.1))
        g.lastKeyTime = -1000
        // Two fingers at the edge (macOS scroll): nothing
        log = []
        for i in 0..<10 {
            g.handle([Touch(id: 10, x: 0.04, y: 0.3 + Float(i) * 0.03, size: 0.8, major: 8, minor: 7, phase: i == 0 ? .began : .moved, time: Double(i) * 0.016),
                      Touch(id: 11, x: 0.12, y: 0.3 + Float(i) * 0.03, size: 0.8, major: 8, minor: 7, phase: i == 0 ? .began : .moved, time: Double(i) * 0.016)])
        }
        g.handle([])
        ScrollTest.log("trackpad-selftest two fingers: \(log.isEmpty ? "nothing" : log.joined(separator: ", "))")
        ScrollTest.log("trackpad-selftest devices: started=\(MultitouchReader.start()) count=\(MultitouchReader.deviceCount) volume=\(SystemVolume.value) brightness=\(DisplayBrightness.value.map { String($0) } ?? "unavailable")")
        MultitouchReader.stop()
    }
}
