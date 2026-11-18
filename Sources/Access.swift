import AppKit
import ApplicationServices

/// Accessibility access (Emoji Picker, auto-scroll, full-page capture, keystrokes, swallowing middle clicks).
///
/// macOS's own prompt shows at most once per launch. If Glint is still not trusted after that, it's almost always a
/// stale entry: System Settings shows Glint switched on, but the switch belongs to an older copy of Glint that was
/// signed differently, so macOS doesn't recognize this one and keeps asking, however often you flip it. Glint then
/// offers to clear its own entry and ask fresh, which adds an entry for this copy.
@MainActor
enum Access {
    static var trusted: Bool { AXIsProcessTrusted() }
    private static var askedThisLaunch = false
    private static var watch: Timer?
    private static var waitingFor: String?

    /// True when Glint has access. Otherwise asks (macOS's prompt the first time this launch, Glint's own
    /// explanation after that) and returns false, so the caller just stops.
    @discardableResult
    static func ensure(_ feature: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        if !askedThisLaunch {
            askedThisLaunch = true
            Diag.log("access: asking macOS for Accessibility (\(feature))")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            waitForGrant(feature)
            Toast.show("\(feature) needs Accessibility access for Glint")
        } else {
            explain(feature)
        }
        return false
    }

    /// Glint's own explanation, with a way out of the stale-entry loop.
    static func explain(_ feature: String? = nil) {
        if AXIsProcessTrusted() { Toast.show("Glint already has Accessibility access"); return }
        let a = NSAlert()
        a.messageText = "Glint doesn't have Accessibility access yet"
        a.informativeText = (feature.map { "\($0) needs it. " } ?? "")
            + "If System Settings already shows Glint switched on, that switch belongs to an older copy of Glint, "
            + "so macOS doesn't recognize this one.\n\nReset and Ask Again clears Glint's old entry. macOS then asks once more: "
            + "choose Open System Settings and switch Glint on."
        a.addButton(withTitle: "Reset and Ask Again")
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        Front.raise(a.window)
        switch a.runModal() {
        case .alertFirstButtonReturn: reset(feature)
        case .alertSecondButtonReturn: openSettings(); waitForGrant(feature)
        default: break
        }
    }

    /// Clears Glint's Accessibility entry (only Glint's) and asks again, so the new entry matches this copy.
    static func reset(_ feature: String?) {
        let id = Bundle.main.bundleIdentifier ?? "com.barkimchi.glint"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
        Diag.log("access: tccutil reset Accessibility \(id) -> \(ok ? "ok" : "failed")")
        if ok {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        } else {
            Toast.show("Couldn't reset it here. In System Settings, select Glint, click −, then add it again.")
            openSettings()
        }
        waitForGrant(feature)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Watches for the switch for a few minutes, says so when it takes, and starts what needed it.
    private static func waitForGrant(_ feature: String?) {
        waitingFor = feature
        watch?.invalidate()
        var ticks = 0
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            MainActor.assumeIsolated {
                ticks += 1
                if AXIsProcessTrusted() {
                    t.invalidate(); watch = nil
                    Diag.log("access: granted")
                    MiddleClick.start()   // swallow middle clicks from now on
                    Toast.show("Accessibility is on" + (waitingFor.map { ". \($0) is ready." } ?? "."))
                } else if ticks > 240 {
                    t.invalidate(); watch = nil
                }
            }
        }
    }
}
