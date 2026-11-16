import AppKit
import ApplicationServices
import SwiftUI

/// First-run welcome tour and the per-version What's New card.
/// New users get the tour once; people updating get What's New on the first two launches of each
/// version that has notes (one showing is easy to miss right after an update relaunch).
@MainActor
enum Onboarding {
    private static let d = UserDefaults.standard
    static let didCapture = Notification.Name("GlintDidCapture")

    // Test hooks, passed as launch arguments (never saved): -onboarding.simulateNewUser YES,
    // -onboarding.simulateVersion 0.2.0. While either is set nothing is written to the user's settings.
    private static var simulating: Bool { d.object(forKey: "onboarding.simulateNewUser") != nil || d.string(forKey: "onboarding.simulateVersion") != nil }
    private static var simNew: Bool { d.bool(forKey: "onboarding.simulateNewUser") }

    static var version: String {
        d.string(forKey: "onboarding.simulateVersion") ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    private static var tourDone: Bool {
        get { simNew ? false : d.bool(forKey: "onboarding.done") }
        set { if !simulating { d.set(newValue, forKey: "onboarding.done") } }
    }
    private static var lastSeen: String? {
        get { simNew ? nil : d.string(forKey: "whatsnew.lastSeen") }
        set { if !simulating { d.set(newValue, forKey: "whatsnew.lastSeen") } }
    }
    /// How many launches have shown What's New for `version` so far.
    static let launchesToShow = 2
    private static var simShows = 0
    private static var shows: Int {
        get { simulating ? simShows : (d.string(forKey: "whatsnew.showsVersion") == version ? d.integer(forKey: "whatsnew.shows") : 0) }
        set {
            if simulating { simShows = newValue; return }
            d.set(version, forKey: "whatsnew.showsVersion"); d.set(newValue, forKey: "whatsnew.shows")
        }
    }

    /// Someone who used Glint before the tour existed: they get What's New, not the tour.
    private static var isExistingUser: Bool {
        if simNew { return false }
        return ["hotkeys.v1", "edge.side", "edge.enabled", "ring.enabled", "ring.order", "rec.systemAudio"].contains { d.object(forKey: $0) != nil }
            || !Store.items().isEmpty
    }

    /// Called at launch. Returns true when it showed something (so launch skips other prompts).
    @discardableResult
    static func showIfNeeded() -> Bool {
        let shown = decide()
        if simulating { ScrollTest.log("onboarding: version \(version) new=\(simNew) -> \(shown)") }
        // Wait a moment: right after a Sparkle relaunch macOS can place a new window behind other apps
        // or on another Space.
        switch shown {
        case "tour": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showTour() }; return true
        case "whatsnew": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showWhatsNew() }; return true
        default: return false
        }
    }

    private static func decide() -> String {
        if !tourDone {
            if isExistingUser { tourDone = true } else { return "tour" }
        }
        if lastSeen != version {
            if WhatsNew.notes[version] != nil, shows < launchesToShow {
                shows += 1
                if shows >= launchesToShow { lastSeen = version }
                return "whatsnew"
            }
            lastSeen = version
        }
        return "none"
    }

    // MARK: Windows

    private static var tourWindow: NSWindow?
    private static var newWindow: NSWindow?

    static func showTour() {
        newWindow?.close()
        if let w = tourWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = makeWindow(size: NSSize(width: 760, height: 500))
        w.contentView = NSHostingView(rootView: TourView { finishTour() })
        tourWindow = w
        onClose(w) { // the red button counts as Skip
            if tourWindow != nil { tourWindow = nil; tourDone = true; lastSeen = version }
        }
        present(w)
    }

    static func finishTour() {
        tourDone = true
        lastSeen = version // a new user has nothing "new" to catch up on
        tourWindow?.close(); tourWindow = nil
        AppController.shared.flashStatusItem()
    }

    static func showWhatsNew() {
        guard let notes = WhatsNew.notes[version] ?? WhatsNew.notes.max(by: { $0.key.compare($1.key, options: .numeric) == .orderedAscending })?.value else { return }
        if let w = newWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = makeWindow(size: NSSize(width: 540, height: 150 + CGFloat(notes.features.count) * 112))
        // Closing doesn't mark it seen: decide() counts launches, so it comes back once more.
        w.contentView = NSHostingView(rootView: WhatsNewView(version: version, notes: notes) {
            newWindow?.close(); newWindow = nil
        })
        newWindow = w
        onClose(w) { newWindow = nil }
        present(w)
    }

    private static func onClose(_ w: NSWindow, _ run: @escaping @MainActor () -> Void) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { run() }
        }
    }

    private static func makeWindow(size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 0.086, green: 0.09, blue: 0.10, alpha: 1)
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        return w
    }

    /// Lets System Settings sit above the tour while the user grants a permission.
    static func lowerTour() { tourWindow?.level = .normal }

    private static func present(_ w: NSWindow) {
        // Float above other apps on the current Space; a background-launched app can't take focus.
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if simulating || CommandLine.arguments.contains("--tour") {
            let f = w.frame, ph = NSScreen.screens.first?.frame.height ?? 0
            ScrollTest.log("window", Int(f.minX), Int(ph - f.maxY), Int(f.width), Int(f.height)) // top-left origin, for recordings
        }
        w.alphaValue = 0
        w.orderFrontRegardless()
        w.makeKey()
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
    }
}

// MARK: - What's New content

struct WhatsNew {
    struct Feature: Identifiable { let id = UUID(); let title: String; let body: String; let media: String }
    let headline: String
    let features: [Feature]

    /// Notes per version. Add an entry when a release has something worth showing; versions without one stay quiet.
    static let notes: [String: WhatsNew] = [
        "0.2.3": WhatsNew(headline: "Shots pile up, send them together", features: [
            Feature(title: "Screenshot pile", body: "Take a few shots in a row and they stack in the corner. Drag the pile into Claude or any app to send them all, or click it to pick one.", media: "sf:square.stack.3d.up.fill"),
            Feature(title: "Copy all", body: "Hover the pile and hit Copy all to paste every shot at once.", media: "sf:doc.on.doc.fill"),
            Feature(title: "Stays until you're done", body: "Corner thumbnails now wait until you close them. Prefer them to fade? Settings > Corner Thumbnails.", media: "sf:clock.fill"),
        ]),
        "0.2.2": WhatsNew(headline: "Pin a window, swipe the edges", features: [
            Feature(title: "Keep a window on top", body: "Press Control-Shift-0 and click any window. It stays above everything until you unlock it from the menu bar.", media: "sf:pin.square.fill"),
            Feature(title: "Trackpad edge controls", body: "Slide one finger along the left edge for volume, the right edge for brightness. Hold a top corner to run an action. Turn it on in Glint Settings.", media: "sf:hand.point.up.left.fill"),
        ]),
        "0.2.0": WhatsNew(headline: "Edit marks, then make it pretty", features: [
            Feature(title: "Marks stay editable", body: "Pick the pointer tool to move, resize, recolour or delete anything you drew.", media: "edit-marks.gif"),
            Feature(title: "Backgrounds", body: "Padding, rounded corners and a gradient in one click. Find it in the editor.", media: "backgrounds.png"),
            Feature(title: "Your popup, your apps", body: "Long-press the middle-click popup to rearrange it and add any app as a button.", media: "popup-apps.gif"),
        ]),
    ]
}

// MARK: - Shared look

private enum Tone {
    static let ink = Color(red: 0.957, green: 0.949, blue: 0.933)
    static let mute = Color(red: 0.60, green: 0.61, blue: 0.64)
    static let panel = Color(red: 0.12, green: 0.13, blue: 0.145)
    static let line = Color.white.opacity(0.08)
    static let amber = Color(red: 1, green: 0.698, blue: 0.102)
    static let tile = Color(red: 0.29, green: 0.30, blue: 0.32)
}

/// The four-point glint from the app icon.
private struct Spark: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var path = Path()
        path.move(to: p(0.5, 0))
        path.addCurve(to: p(1, 0.5), control1: p(0.53, 0.35), control2: p(0.65, 0.47))
        path.addCurve(to: p(0.5, 1), control1: p(0.65, 0.53), control2: p(0.53, 0.65))
        path.addCurve(to: p(0, 0.5), control1: p(0.47, 0.65), control2: p(0.35, 0.53))
        path.addCurve(to: p(0.5, 0), control1: p(0.35, 0.47), control2: p(0.47, 0.35))
        return path
    }
}

private struct Keycap: View {
    let text: String
    var lit = false
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(lit ? Color.black : Tone.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(lit ? Tone.amber : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12)))
    }
}

/// Plays a GIF (or shows a still) from the app bundle.
private struct BundleMedia: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        // Let SwiftUI's frame decide the size, not the image's natural size.
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            v.setContentHuggingPriority(.defaultLow, for: o)
            v.setContentCompressionResistancePriority(.defaultLow, for: o)
        }
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        if name.hasPrefix("sf:") { // an SF Symbol on a tile, for features without a recording
            v.imageScaling = .scaleNone
            v.image = NSImage(systemSymbolName: String(name.dropFirst(3)), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
            v.contentTintColor = NSColor(srgbRed: 1, green: 0.698, blue: 0.102, alpha: 1)
            v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            return v
        }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "WhatsNew")
            ?? Bundle.main.url(forResource: base, withExtension: ext) {
            v.image = NSImage(contentsOf: url)
        }
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {}
}

// MARK: - Tour

private struct TourView: View {
    let done: () -> Void
    @State private var step = min(4, max(0, UserDefaults.standard.integer(forKey: "tour.startStep"))) // -tour.startStep N for screenshots
    private let count = 5

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .top, startRadius: 0, endRadius: 520)
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: PermissionStep()
                case 2: TryItStep()
                case 3: WaysStep()
                default: DoneStep()
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
                                    removal: .opacity))
            .padding(.horizontal, 56).padding(.top, 40).padding(.bottom, 84)
            VStack {
                HStack { Spacer(); if step < count - 1 { Button("Skip") { done() }.buttonStyle(.plain).foregroundStyle(Tone.mute) } }
                    .padding(.top, 14).padding(.trailing, 18)
                Spacer()
                HStack {
                    Button("Back") { go(step - 1) }.buttonStyle(.plain).foregroundStyle(Tone.mute).opacity(step == 0 ? 0 : 1)
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule().fill(i == step ? Tone.amber : Color.white.opacity(0.15)).frame(width: i == step ? 20 : 7, height: 7)
                        }
                    }
                    Spacer()
                    Button { step == count - 1 ? done() : go(step + 1) } label: {
                        Text(["Get Started", "Continue", "Next", "Next", "Start using Glint"][step])
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Tone.amber))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 28).padding(.bottom, 22)
            }
        }
        .foregroundStyle(Tone.ink)
        .frame(width: 760, height: 500)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
    }

    private func go(_ i: Int) { step = max(0, min(count - 1, i)) }
}

private struct WelcomeStep: View {
    @State private var shown = false
    @State private var glow = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Tone.tile).frame(width: 116, height: 116)
                    .shadow(color: Tone.amber.opacity(glow ? 0.28 : 0), radius: 34)
                Spark().fill(Tone.ink).frame(width: 64, height: 64)
                    .scaleEffect(shown ? 1 : 0.2).rotationEffect(.degrees(shown ? 0 : -45)).opacity(shown ? 1 : 0)
                Circle().fill(Tone.amber).frame(width: 14, height: 14)
                    .offset(x: 30, y: shown ? -30 : -46).opacity(shown ? 1 : 0)
            }
            Text("Welcome to Glint").font(.system(size: 40, weight: .bold)).kerning(-1).padding(.top, 24)
            Text("Capture, mark up and share anything on your screen.\nOne middle-click away.")
                .font(.system(size: 16)).foregroundStyle(Tone.mute).multilineTextAlignment(.center).padding(.top, 8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55).delay(0.1)) { shown = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever().delay(0.8)) { glow = true }
        }
    }
}

private struct PermissionStep: View {
    @State private var granted = CGPreflightScreenCaptureAccess()
    @State private var asked = false
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            Text("One permission, and you're set").font(.system(size: 28, weight: .bold)).kerning(-0.5)
            Text("macOS asks before any app can see your screen. Glint only looks when you capture, and nothing leaves your Mac.")
                .font(.system(size: 15)).foregroundStyle(Tone.mute).multilineTextAlignment(.center).frame(maxWidth: 470).padding(.top, 8)
            HStack(spacing: 14) {
                Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 20)).frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording").font(.system(size: 14, weight: .semibold))
                    Text("Needed for screenshots and recordings").font(.system(size: 12.5)).foregroundStyle(Tone.mute)
                }
                Spacer()
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(asked ? "Open Settings" : "Allow…") { ask() }.controlSize(.large)
                }
            }
            .padding(16).frame(width: 450)
            .background(RoundedRectangle(cornerRadius: 14).fill(Tone.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tone.line))
            .padding(.top, 26)
            Group {
                if granted {
                    Text("All set. Press Continue.")
                } else if asked {
                    VStack(spacing: 6) {
                        Text("Turn on Glint in the list. This updates on its own.")
                        Button("Turned it on but nothing changed? Relaunch Glint") { relaunch() }.buttonStyle(.link)
                    }
                } else {
                    Text("You can also do this later from the menu bar.")
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(Tone.mute).padding(.top, 14)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
        .onReceive(timer) { _ in if !granted { granted = CGPreflightScreenCaptureAccess() } }
    }

    private func ask() {
        Onboarding.lowerTour()
        if !asked { CGRequestScreenCaptureAccess() }
        asked = true
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }

    /// macOS often applies a new Screen Recording grant only after the app restarts.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

private struct TryItStep: View {
    @State private var captured = false
    @State private var lit = 0
    private var keys: [String] {
        guard let s = HotkeySettings.shared.shortcut(.area) else { return [] }
        return s.display.map { String($0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(captured ? "Nice. That's a Glint." : "Try it now").font(.system(size: 28, weight: .bold)).kerning(-0.5)
                .contentTransition(.opacity)
            Text(captured ? "It's saved, and waiting in the bottom-left corner. Hover it for Copy, Annotate and Pin."
                          : (keys.isEmpty ? "Middle-click anywhere and pick Capture Area, then drag over anything."
                                          : "Press the shortcut, then drag over anything on your screen."))
                .font(.system(size: 15)).foregroundStyle(Tone.mute).multilineTextAlignment(.center).frame(maxWidth: 470).padding(.top, 8)
            ZStack {
                if captured {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(.green)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    HStack(spacing: 8) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { i, k in Keycap(text: k, lit: lit > i).scaleEffect(1.5) }
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 140)
            if !captured {
                Button("Take a capture now") { AppController.shared.perform(.area) }.buttonStyle(.link).font(.system(size: 13))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: captured)
        .onAppear { animateKeys() }
        .onReceive(NotificationCenter.default.publisher(for: Onboarding.didCapture)) { _ in
            captured = true
            ScrollTest.log("tour: try-it step saw the capture")
        }
    }

    private func animateKeys() {
        for i in 0...keys.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.35) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { lit = i + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(keys.count + 2) * 0.35 + 1.2) {
            guard !captured else { return }
            withAnimation(.easeOut(duration: 0.2)) { lit = 0 }
            animateKeys()
        }
    }
}

private struct WaysStep: View {
    @State private var wobble = false
    @State private var axGranted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            Text("Three ways to capture").font(.system(size: 28, weight: .bold)).kerning(-0.5)
            Text("Use whichever feels natural. They all do the same things.")
                .font(.system(size: 15)).foregroundStyle(Tone.mute).padding(.top, 8)
            HStack(spacing: 14) {
                card("Middle-click", "A popup of actions under your pointer. Long-press to rearrange.") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 3), spacing: 6) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 7).fill(Tone.tile).frame(width: 26, height: 26)
                                .rotationEffect(.degrees(wobble ? (i % 2 == 0 ? 3 : -3) : (i % 2 == 0 ? -3 : 3)))
                        }
                    }
                }
                card("Edge widget", "A slim tab on any screen edge. Hover to open.") {
                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).stroke(i % 2 == 0 ? Color.white : Tone.amber, lineWidth: 2).frame(width: 12, height: 12)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tone.tile))
                }
                card("Shortcuts", "Every action has one. Change them in Settings.") {
                    HStack(spacing: 5) { Keycap(text: "⌃"); Keycap(text: "⇧"); Keycap(text: "2…9") }
                }
            }
            .padding(.top, 24)
            HStack(spacing: 6) {
                if axGranted {
                    Label("Middle-click is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("The middle-click popup needs Accessibility access.").foregroundStyle(Tone.mute)
                    Button("Turn it on") {
                        Onboarding.lowerTour()
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(opts)
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: 13)).padding(.top, 16)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true } }
        .onReceive(timer) { _ in
            let now = AXIsProcessTrusted()
            if now && !axGranted { MiddleClick.start() } // swallow middle clicks from now on
            axGranted = now
        }
    }

    private func card<M: View>(_ title: String, _ body: String, @ViewBuilder media: () -> M) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack { RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)); media() }.frame(height: 104)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(body).font(.system(size: 12.5)).foregroundStyle(Tone.mute).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14).frame(width: 200, height: 210)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tone.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tone.line))
    }
}

private struct DoneStep: View {
    @State private var ping = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Tone.amber, lineWidth: 2).frame(width: 70, height: 70).scaleEffect(ping ? 1.6 : 0.6).opacity(ping ? 0 : 1)
                Spark().fill(Tone.ink).frame(width: 34, height: 34)
            }
            .frame(height: 90)
            Text("You're all set").font(.system(size: 28, weight: .bold)).kerning(-0.5)
            Text("Glint lives in your menu bar. Look for the sparkle.").font(.system(size: 15)).foregroundStyle(Tone.mute).padding(.top, 8)
            LazyVGrid(columns: [GridItem(.fixed(300), spacing: 10), GridItem(.fixed(300), spacing: 10)], spacing: 10) {
                tip("Saved automatically", Store.savedDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                tip("Mark it up", "Hover the thumbnail, then Annotate")
                tip("Make it pretty", "Background adds padding and a gradient")
                tip("See this again", "Menu bar, then Welcome Tour")
            }
            .padding(.top, 22)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ping = true } }
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tone.amber)
            Text(body).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Tone.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tone.line))
    }
}

// MARK: - What's New

private struct WhatsNewView: View {
    let version: String
    let notes: WhatsNew
    let done: () -> Void
    @State private var shown = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT'S NEW IN \(version)").font(.system(size: 11.5, weight: .semibold)).kerning(0.8).foregroundStyle(Tone.amber)
            Text(notes.headline).font(.system(size: 26, weight: .bold)).kerning(-0.5).padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(notes.features.enumerated()), id: \.element.id) { i, f in
                    HStack(spacing: 16) {
                        BundleMedia(name: f.media).frame(width: 140, height: 88).clipped()
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tone.line))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.system(size: 14.5, weight: .semibold))
                            Text(f.body).font(.system(size: 13)).foregroundStyle(Tone.mute).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(shown > i ? 1 : 0).offset(x: shown > i ? 0 : -12)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 16)
            HStack {
                Button("All updates") { NSWorkspace.shared.open(URL(string: "https://github.com/barkimchi/Glint/releases")!) }
                    .buttonStyle(.plain).foregroundStyle(Tone.mute).font(.system(size: 13))
                Spacer()
                Button(action: done) {
                    Text("Got it").font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Tone.amber))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(Tone.ink)
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 22)
        .frame(width: 540)
        .onAppear {
            for i in 0..<notes.features.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.15) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { shown = i + 1 }
                }
            }
        }
    }
}
