import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Every action that can have a global shortcut.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case area, window, fullscreen, scroll, page, ocr, record, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .scroll: return "Scrolling Capture"
        case .page: return "Capture Full Page"
        case .ocr: return "Grab Text (OCR)"
        case .record: return "Record Screen"
        case .claude: return "Go to Claude"
        }
    }
    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .scroll: return "arrow.up.and.down.square"
        case .page: return "doc.viewfinder"
        case .ocr: return "text.viewfinder"
        case .record: return "record.circle"
        case .claude: return "bubble.left"
        }
    }
    var defaultShortcut: Shortcut {
        let cs = UInt32(controlKey | shiftKey)
        switch self {
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cs, key: "4")
        case .window: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: cs, key: "5")
        case .fullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cs, key: "3")
        case .scroll: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: cs, key: "7")
        case .page: return Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: cs, key: "8")
        case .ocr: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: cs, key: "2")
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: cs, key: "6")
        case .claude: return Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: cs, key: "9")
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
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 740),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Glint Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = HotkeySettings.shared
    @State private var recording: HotkeyAction?
    @State private var message = "Click a shortcut, then press the new key combination."
    @State private var monitor: Any?
    @State private var saveDir = Store.savedDir
    @State private var highlightClicks = RecordingSettings.highlightClicks
    @State private var showKeys = RecordingSettings.showKeystrokes
    @State private var axMissing = RecordingSettings.showKeystrokes && !AXIsProcessTrusted()
    @State private var systemAudio = RecordingSettings.systemAudio
    @State private var microphone = RecordingSettings.microphone
    @State private var micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts").font(.headline)
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
            Divider()
            Text("Recording").font(.headline)
            Toggle("Highlight clicks (yellow ring, blue for right-click)", isOn: $highlightClicks)
                .onChange(of: highlightClicks) { _, v in RecordingSettings.highlightClicks = v }
            Toggle("Show keystrokes", isOn: $showKeys)
                .onChange(of: showKeys) { _, v in
                    RecordingSettings.showKeystrokes = v
                    if v {
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        axMissing = !AXIsProcessTrustedWithOptions(opts)
                    } else { axMissing = false }
                }
            if axMissing {
                HStack {
                    Text("Needs Accessibility access for Glint. Keys won't show until it's on.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.controlSize(.small)
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
            Divider()
            Text("Save Folder").font(.headline)
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
        .padding(20)
        .frame(width: 460)
        .onDisappear { stopRecording() }
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
