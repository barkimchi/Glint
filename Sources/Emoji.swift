import AppKit
import ApplicationServices

/// Opens the Mac's own emoji picker at the text box you're typing in, in any app.
/// Glint sends the system's Emoji & Symbols shortcut (Control-Command-Space) to the app in front.
/// Sending keys to other apps needs Accessibility access, which the popup already uses.
@MainActor
enum EmojiPicker {
    static func open() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            Toast.show("Emoji Picker needs Accessibility access for Glint")
            return
        }
        // Let the popup close and focus settle back on the text box, and wait for the shortcut's own
        // keys (Option, Shift) to come up so they don't mix with the keystroke sent.
        waitForModifiersUp(deadline: Date().addingTimeInterval(1.2)) { send() }
    }

    private static func waitForModifiersUp(deadline: Date, then run: @escaping @MainActor () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand])
        if held.isEmpty || Date() > deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { run() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForModifiersUp(deadline: deadline, then: run) }
        }
    }

    /// The keystroke, built separately so the test can check it without sending it.
    static func events() -> [CGEvent] {
        let src = CGEventSource(stateID: .hidSystemState)
        let space: CGKeyCode = 49
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: space, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: space, keyDown: false) else { return [] }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        return [down, up]
    }

    private static func send() {
        Diag.log("emoji: opening the system picker in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        for e in events() { e.post(tap: .cghidEventTap) }
    }
}

/// `--emoji-selftest`: checks the keystroke the Emoji Picker sends (without sending it), the default
/// shortcuts, and that the popup migration adds Emoji once and respects a later removal.
@MainActor
enum EmojiSelfTest {
    static func run() {
        let log = { (s: String) in ScrollTest.log("emoji-selftest " + s) }
        let e = EmojiPicker.events()
        let desc = e.map { "key=\($0.getIntegerValueField(.keyboardEventKeycode)) down=\($0.type == .keyDown) ctrl=\($0.flags.contains(.maskControl)) cmd=\($0.flags.contains(.maskCommand)) opt=\($0.flags.contains(.maskAlternate)) shift=\($0.flags.contains(.maskShift))" }
        log("events \(desc)")
        log("defaults " + HotkeyAction.allCases.map { "\($0.rawValue)=\($0.defaultShortcut.display)" }.joined(separator: " "))
        let custom = ["area", "window", "app:com.apple.Safari"]
        let first = RingLayout.migrate(order: custom, flags: [])
        log("customized first launch: \(first.order ?? []) set \(first.setFlags)")
        let removed = RingLayout.migrate(order: custom, flags: Set(first.setFlags))
        log("after user removed it: \(removed.order ?? []) set \(removed.setFlags)")
        let fresh = RingLayout.migrate(order: nil, flags: [])
        log("never customized: \(fresh.order.map { "\($0)" } ?? "default order (all actions)") set \(fresh.setFlags)")
        log("default popup has emoji: \(HotkeyAction.allCases.map { RingItem.action($0) }.contains(.action(.emoji)))")
        NSApp.terminate(nil)
    }
}
