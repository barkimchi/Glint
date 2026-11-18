import AppKit

/// Brings one of Glint's windows in front of every app.
///
/// Glint is a menu bar app, and macOS only activates an app when the app in front lets it go. So
/// `makeKeyAndOrderFront` + `NSApp.activate()` often left Annotate or Settings behind whatever you were using
/// (measured on macOS 27: the window opened under the front app's window). Ordering it in front regardless, at a
/// floating level, puts it on top whether or not activation goes through. It stays floating until you click into it,
/// close it, or switch to another app yourself; then it's a normal window again and doesn't float over other apps.
/// Measured on macOS 27: even when Glint does get activated, macOS hands focus back to the app you were in about two
/// seconds later, so app switches in the first few seconds don't count.
@MainActor
enum Front {
    private struct Watch { var notes: [NSObjectProtocol] = []; var appSwitch: NSObjectProtocol?; var clicks: Any? }
    private static var watchers: [ObjectIdentifier: Watch] = [:]
    nonisolated private static let handBackWindow: TimeInterval = 4

    static func show(_ w: NSWindow, center: Bool = false) {
        if center { centerOnPointerScreen(w) }
        if !w.collectionBehavior.contains(.canJoinAllSpaces) { w.collectionBehavior.insert(.moveToActiveSpace) }
        w.level = .floating
        w.orderFrontRegardless()
        w.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        settleLater(w)
    }

    /// Back to a normal window once you've clicked into it, closed it, or moved to another app yourself.
    private static func settleLater(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        stopWatching(id)
        let shown = Date()
        let settle = { [weak w] in
            MainActor.assumeIsolated {
                if let w, w.level == .floating { w.level = .normal }
                stopWatching(id)
            }
        }
        let nc = NotificationCenter.default
        let mine = ProcessInfo.processInfo.processIdentifier
        var watch = Watch()
        watch.notes = [nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in settle() }]
        watch.appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != mine, Date().timeIntervalSince(shown) > handBackWindow { settle() }
        }
        watch.clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak w] e in
            if let w, e.window === w { settle() }
            return e
        }
        watchers[id] = watch
    }

    private static func stopWatching(_ id: ObjectIdentifier) {
        guard let watch = watchers.removeValue(forKey: id) else { return }
        watch.notes.forEach { NotificationCenter.default.removeObserver($0) }
        if let o = watch.appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let m = watch.clicks { NSEvent.removeMonitor(m) }
    }

    /// Keeps an alert or open panel above other apps while it's up.
    static func raise(_ w: NSWindow) {
        w.level = .floating
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The screen with the pointer, where you're looking (the main screen follows the focused window instead).
    static var pointerScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Centers the window on the pointer's screen, a little above the middle like `NSWindow.center()`.
    static func centerOnPointerScreen(_ w: NSWindow) {
        guard let vf = pointerScreen?.visibleFrame else { w.center(); return }
        let s = w.frame.size
        let x = vf.midX - s.width / 2
        let y = min(vf.midY - s.height / 2 + (vf.height - s.height) / 6, vf.maxY - s.height)
        w.setFrameOrigin(NSPoint(x: x, y: max(y, vf.minY)))
    }
}
