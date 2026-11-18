import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import Sparkle
import UniformTypeIdentifiers

/// Every action that can have a global shortcut.
/// The app the "Go to" action opens. Claude by default; any installed app can be chosen in Settings.
enum AppTarget {
    static let claudeID = "com.anthropic.claudefordesktop"
    static var bundleID: String {
        get { UserDefaults.standard.string(forKey: "app.target") ?? claudeID }
        set { UserDefaults.standard.set(newValue == claudeID ? nil : newValue, forKey: "app.target") }
    }
    static var isClaude: Bool { bundleID == claudeID }
    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var name: String {
        if isClaude { return "Claude" }
        guard let u = url else { return "App" }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    static var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }
}

enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case area, window, fullscreen, scroll, page, ocr, record, claude, keepOnTop, emoji
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .keepOnTop: return "Keep Window on Top"
        case .fullscreen: return "Capture Fullscreen"
        case .scroll: return "Scrolling Capture"
        case .page: return "Capture Full Page"
        case .ocr: return "Grab Text (OCR)"
        case .record: return "Record Screen"
        case .claude: return "Go to \(AppTarget.name)"
        case .emoji: return "Emoji Picker"
        }
    }
    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .keepOnTop: return "pin.square"
        case .fullscreen: return "display"
        case .scroll: return "arrow.up.and.down.square"
        case .page: return "doc.viewfinder"
        case .ocr: return "text.viewfinder"
        case .record: return "record.circle"
        case .claude: return "bubble.left"
        case .emoji: return "face.smiling"
        }
    }
    var defaultShortcut: Shortcut {
        let cs = UInt32(optionKey | shiftKey) // Option-Shift-number for everything
        switch self {
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cs, key: "4")
        case .window: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: cs, key: "5")
        case .keepOnTop: return Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: cs, key: "0")
        case .fullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cs, key: "3")
        case .scroll: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: cs, key: "7")
        case .page: return Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: cs, key: "8")
        case .ocr: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: cs, key: "2")
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: cs, key: "6")
        case .claude: return Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: cs, key: "9")
        case .emoji: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: cs, key: "1")
        }
    }
}

/// A key plus Carbon modifier flags. `key` is the printable label shown in the UI.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var menuMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// Converts a key press into a shortcut. Needs at least one modifier unless it's an F-key,
    /// so a plain letter can never be stolen system-wide.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        let fKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
                                       100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label: String
        if let fk = fKeys[event.keyCode] {
            label = fk
        } else {
            guard m != 0, let c = event.charactersIgnoringModifiers?.uppercased(), !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            label = c
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }
}

@MainActor
final class HotkeySettings: ObservableObject {
    static let shared = HotkeySettings()
    private let defaultsKey = "hotkeys.v1"

    /// nil means the action has no shortcut (cleared on purpose).
    @Published private(set) var shortcuts: [HotkeyAction: Shortcut?] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([HotkeyAction: Shortcut?].self, from: data) {
            shortcuts = saved
        }
        for a in HotkeyAction.allCases where shortcuts[a] == nil { shortcuts[a] = .some(a.defaultShortcut) }
    }

    func shortcut(_ a: HotkeyAction) -> Shortcut? { shortcuts[a] ?? nil }

    /// Returns the action that already uses this shortcut, if any.
    func conflict(_ s: Shortcut, excluding a: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != a && shortcut($0) == s }
    }

    func set(_ s: Shortcut?, for a: HotkeyAction) {
        shortcuts[a] = .some(s)
        save()
    }

    func resetAll() {
        for a in HotkeyAction.allCases { shortcuts[a] = .some(a.defaultShortcut) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        AppController.shared.registerHotkeys()
    }
}

/// Audio options for screen recordings, stored in UserDefaults.
/// Beta builds come through the same update feed, marked with Sparkle's "beta" channel.
/// A beta build opts in by default, so installing one keeps you on betas until you turn it off.
enum BetaUpdates {
    static var isBetaBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "GlintBetaTag") != nil }
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "updates.beta") as? Bool ?? isBetaBuild }
        set { UserDefaults.standard.set(newValue, forKey: "updates.beta") }
    }
    static let delegate = Delegate()
    final class Delegate: NSObject, SPUUpdaterDelegate {
        func allowedChannels(for updater: SPUUpdater) -> Set<String> { BetaUpdates.enabled ? ["beta"] : [] }
    }
}

/// How long screenshots wait in the corner. 0 means until you close them.
enum CornerSettings {
    static let choices: [(Int, String)] = [(0, "Until I close them"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes")]
    static var hideAfter: Int {
        get { UserDefaults.standard.object(forKey: "corner.hideAfter") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "corner.hideAfter") }
    }
}

enum RecordingSettings {
    static var systemAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "rec.systemAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "rec.systemAudio") }
    }
    static var microphone: Bool {
        get { UserDefaults.standard.bool(forKey: "rec.microphone") }
        set { UserDefaults.standard.set(newValue, forKey: "rec.microphone") }
    }

    /// Defaults to on.
    static var highlightClicks: Bool {
        get { UserDefaults.standard.object(forKey: "rec.highlightClicks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rec.highlightClicks") }
    }

    static var showKeystrokes: Bool {
        get { UserDefaults.standard.bool(forKey: "rec.showKeystrokes") }
        set { UserDefaults.standard.set(newValue, forKey: "rec.showKeystrokes") }
    }

    static func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

// MARK: - Window

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        let isNew = window == nil
        let w = window ?? {
            // Sized to the open sections by fit(contentHeight:); scrolls when that's taller than the screen.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            // Test builds carry their tag (added by the release workflow) so you can tell them apart.
            let beta = Bundle.main.object(forInfoDictionaryKey: "GlintBetaTag") as? String
            w.title = beta.map { "Glint Settings (\($0))" } ?? "Glint Settings"
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView())
            host.sizingOptions = []
            w.contentView = host
            w.contentMinSize = NSSize(width: 460, height: 200)
            w.contentMaxSize = NSSize(width: 460, height: 2000)
            window = w
            return w
        }()
        Front.show(w, center: isNew)
    }

    /// Grows or shrinks the window to the open sections, keeping its top edge where it is.
    static func fit(contentHeight h: CGFloat) {
        guard let w = window, h > 0 else { return }
        let maxH = (w.screen ?? NSScreen.main).map { $0.visibleFrame.height - 40 } ?? 900
        let target = min(h, maxH)
        let current = w.contentRect(forFrameRect: w.frame).height
        guard abs(current - target) > 1 else { return }
        var f = w.frame
        let newFrame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 460, height: target))
        f.origin.y += f.height - newFrame.height
        f.size.height = newFrame.height
        w.setFrame(f, display: true, animate: w.isVisible)
    }
}

private struct SettingsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsView: View {
    @ObservedObject private var settings = HotkeySettings.shared
    @State private var recording: HotkeyAction?
    @State private var message = "Click a shortcut, then press the new key combination."
    @State private var monitor: Any?
    @State private var saveDir = Store.savedDir
    @State private var hideAfter = CornerSettings.hideAfter
    @State private var betaUpdates = BetaUpdates.enabled
    @State private var look = GlintLook.current
    @State private var highlightClicks = RecordingSettings.highlightClicks
    @State private var showKeys = RecordingSettings.showKeystrokes
    @State private var axMissing = RecordingSettings.showKeystrokes && !AXIsProcessTrusted()
    @State private var systemAudio = RecordingSettings.systemAudio
    @State private var microphone = RecordingSettings.microphone
    @State private var micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    @State private var appName = AppTarget.name
    @State private var tpOn = TrackpadSettings.enabled
    @State private var tpLeft = TrackpadSettings.leftEdge
    @State private var tpRight = TrackpadSettings.rightEdge
    @State private var tpTL = TrackpadSettings.topLeft
    @State private var tpTR = TrackpadSettings.topRight
    @State private var tpSens = TrackpadSettings.sensitivity
    @State private var tpZone = TrackpadSettings.zone
    @State private var tpStatus = TrackpadControls.status
    @State private var appIcon = AppTarget.icon
    @State private var open = Set(UserDefaults.standard.stringArray(forKey: "settings.openSections") ?? [])

    var body: some View {
        ScrollView { content }.frame(width: 460)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("shortcuts", "Keyboard Shortcuts", "keyboard", "\(HotkeyAction.allCases.filter { settings.shortcut($0) != nil }.count) set") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(HotkeyAction.allCases) { a in
                        GridRow {
                            Text(a.title).frame(width: 150, alignment: .leading)
                            Button { startRecording(a) } label: {
                                Text(recording == a ? "Press keys…" : (settings.shortcut(a)?.display ?? "None"))
                                    .font(.system(.body, design: .rounded).monospacedDigit())
                                    .frame(width: 120)
                            }
                            .buttonStyle(.bordered)
                            .tint(recording == a ? .accentColor : nil)
                            Button { settings.set(nil, for: a) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear shortcut")
                                .opacity(settings.shortcut(a) == nil ? 0 : 1)
                        }
                    }
                }
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Restore Default Shortcuts") { stopRecording(); settings.resetAll(); message = "Defaults restored." }
                    Spacer()
                }
            }
            section("look", "Appearance", "paintpalette", look.title) {
                Picker("", selection: $look) { ForEach(GlintLook.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .onChange(of: look) { _, v in GlintLook.current = v; EdgeWidget.reload() }
                Text("Glass blurs what's behind the popup, the edge widget and the screenshot pile.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("goto", "Go-to App", "arrow.up.forward.app", appName) {
                HStack(spacing: 8) {
                    Text("Go-to button opens").frame(width: 150, alignment: .leading)
                    if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 20, height: 20) }
                    Text(appName).fontWeight(.medium)
                    Spacer()
                    Button("Choose App…") { chooseApp() }
                    if appName != "Claude" { Button("Use Claude") { setApp(AppTarget.claudeID) } }
                }
                Text("The Go-to button in the popup and its shortcut bring this app forward.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            section("trackpad", "Trackpad", "hand.point.up.left", tpOn ? "On" : "Off") {
                Toggle("Trackpad edge controls", isOn: $tpOn)
                    .onChange(of: tpOn) { _, v in TrackpadSettings.enabled = v; TrackpadControls.apply(); tpStatus = TrackpadControls.status }
                if tpOn {
                    Label(tpStatus, systemImage: tpStatus.hasPrefix("No") ? "exclamationmark.triangle" : "hand.point.up.left")
                        .font(.callout).foregroundStyle(tpStatus.hasPrefix("No") ? .orange : .secondary)
                }
                if tpOn {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Slide left edge").frame(width: 150, alignment: .leading)
                            Picker("", selection: $tpLeft) { ForEach(EdgeControl.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
                                .onChange(of: tpLeft) { _, v in TrackpadSettings.leftEdge = v }
                        }
                        GridRow {
                            Text("Slide right edge")
                            Picker("", selection: $tpRight) { ForEach(EdgeControl.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
                                .onChange(of: tpRight) { _, v in TrackpadSettings.rightEdge = v }
                        }
                        GridRow {
                            Text("Hold top-left corner")
                            Picker("", selection: $tpTL) { ForEach(TrackpadSettings.cornerChoices, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 200)
                                .onChange(of: tpTL) { _, v in TrackpadSettings.topLeft = v }
                        }
                        GridRow {
                            Text("Hold top-right corner")
                            Picker("", selection: $tpTR) { ForEach(TrackpadSettings.cornerChoices, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 200)
                                .onChange(of: tpTR) { _, v in TrackpadSettings.topRight = v }
                        }
                        GridRow {
                            Text("Sensitivity")
                            Slider(value: $tpSens, in: 0.6...3.5).frame(width: 200)
                                .onChange(of: tpSens) { _, v in TrackpadSettings.sensitivity = v }
                        }
                        GridRow {
                            Text("Edge zone width")
                            Slider(value: $tpZone, in: 0.05...0.22).frame(width: 200)
                                .onChange(of: tpZone) { _, v in TrackpadSettings.zone = v; TrackpadControls.apply(); tpStatus = TrackpadControls.status }
                        }
                    }
                    Text("Slide one finger along an edge to change volume or brightness; the pointer holds still while you slide. Hold a finger still in a top corner for half a second to run its action. Pauses while you type. Brightness works on built-in and Apple displays.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Slide along the trackpad's edges for volume and brightness, hold a top corner to run an action.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            section("recording", "Recording", "record.circle", recordingSummary) {
                Toggle("Highlight clicks (yellow ring, blue for right-click)", isOn: $highlightClicks)
                    .onChange(of: highlightClicks) { _, v in RecordingSettings.highlightClicks = v }
                Toggle("Show keystrokes", isOn: $showKeys)
                    .onChange(of: showKeys) { _, v in
                        RecordingSettings.showKeystrokes = v
                        axMissing = v && !Access.ensure("Show keystrokes")
                    }
                if axMissing {
                    HStack {
                        Text("Needs Accessibility access for Glint. Keys won't show until it's on.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Fix…") { Access.explain("Show keystrokes") }.controlSize(.small)
                    }
                }
                Toggle("Record system audio (sound from apps)", isOn: $systemAudio)
                    .onChange(of: systemAudio) { _, v in RecordingSettings.systemAudio = v }
                Toggle("Record microphone", isOn: $microphone)
                    .onChange(of: microphone) { _, v in
                        RecordingSettings.microphone = v
                        guard v else { return }
                        Task {
                            let ok = await RecordingSettings.ensureMicAccess()
                            micDenied = !ok
                            if !ok { microphone = false; RecordingSettings.microphone = false }
                        }
                    }
                if micDenied {
                    HStack {
                        Text("Microphone access is off for Glint.").font(.callout).foregroundStyle(.secondary)
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }.controlSize(.small)
                    }
                }
            }
            section("corner", "Corner Thumbnails", "rectangle.stack", CornerSettings.choices.first { $0.0 == hideAfter }?.1 ?? "") {
                HStack {
                    Text("Keep screenshots in the corner").frame(width: 200, alignment: .leading)
                    Picker("", selection: $hideAfter) { ForEach(CornerSettings.choices, id: \.0) { Text($0.1).tag($0.0) } }
                        .labelsHidden().frame(width: 180)
                        .onChange(of: hideAfter) { _, v in CornerSettings.hideAfter = v }
                }
                Text("Screenshots taken while one is still showing stack into a pile. Drag the pile to send them all.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("updates", "Updates", "arrow.triangle.2.circlepath", betaUpdates ? "Beta builds" : "Regular releases") {
                Toggle("Get beta builds", isOn: $betaUpdates)
                    .onChange(of: betaUpdates) { _, v in BetaUpdates.enabled = v }
                Text("Try new features before they ship. Check for Updates in the menu offers betas too. Turn it off and you move to the next regular release when it comes out.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("save", "Save Folder", "folder", saveDir.lastPathComponent) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: saveDir.path)).resizable().frame(width: 20, height: 20)
                    Text(saveDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                HStack {
                    Text("Every new screenshot lands here automatically. History is kept separately for 30 days.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if saveDir != Store.defaultSaveDir {
                        Button("Use Default") {
                            UserDefaults.standard.removeObject(forKey: Store.saveFolderKey)
                            saveDir = Store.savedDir
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(GeometryReader { g in Color.clear.preference(key: SettingsHeightKey.self, value: g.size.height) })
        .onPreferenceChange(SettingsHeightKey.self) { h in MainActor.assumeIsolated { SettingsWindow.fit(contentHeight: h) } }
        .onDisappear { stopRecording() }
    }

    private var recordingSummary: String {
        let on = [(highlightClicks, "Clicks"), (showKeys, "Keys"), (systemAudio, "Audio"), (microphone, "Mic")].filter(\.0).map(\.1)
        return on.isEmpty ? "Screen only" : on.joined(separator: ", ")
    }

    /// A card with a clickable header (icon, title, current state, chevron) that opens to its settings.
    private func section<C: View>(_ id: String, _ title: String, _ icon: String, _ summary: String,
                                  @ViewBuilder _ body: () -> C) -> some View {
        let isOpen = open.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isOpen { open.remove(id) } else { open.insert(id) }
                }
                UserDefaults.standard.set(Array(open), forKey: "settings.openSections")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.698, blue: 0.102)).frame(width: 20)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 12) { body() }
                    .padding(.horizontal, 12).padding(.bottom, 14).padding(.top, 2)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Pick the app the Go-to button and its shortcut should open."
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        setApp(id)
    }

    private func setApp(_ id: String) {
        AppTarget.bundleID = id
        appName = AppTarget.name
        appIcon = AppTarget.icon
        EdgeWidget.reload()
        ActionRing.close()
    }

    private func startRecording(_ a: HotkeyAction) {
        stopRecording()
        recording = a
        message = "Press the new shortcut for \(a.title). Esc cancels."
        // Global hotkeys would swallow the press, so pause them while recording.
        AppController.shared.unregisterHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); message = "Cancelled."; return nil }
            guard let s = Shortcut(event: e) else {
                message = "Use at least one modifier (⌃ ⌥ ⇧ ⌘), or an F-key."
                return nil
            }
            if let other = settings.conflict(s, excluding: a) {
                message = "\(s.display) is already used by \(other.title)."
                return nil
            }
            settings.set(s, for: a) // also re-registers hotkeys
            message = "\(a.title) is now \(s.display)."
            stopRecording()
            return nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDir
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let u = panel.url {
            UserDefaults.standard.set(u.path, forKey: Store.saveFolderKey)
            saveDir = Store.savedDir
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording != nil { recording = nil; AppController.shared.registerHotkeys() }
    }
}
