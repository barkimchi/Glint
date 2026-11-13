import AppKit
import SwiftUI

// MARK: - Quick access thumbnail

final class ThumbState: ObservableObject {
    @Published var hovering = false {
        didSet {
            if hovering {
                cancelDismiss()
                showControls()
            } else {
                armDismiss()
                scheduleHideControls()
            }
        }
    }
    /// Controls stay in the view hierarchy and fade; inserting them on hover made
    /// early clicks land on nothing and a 1px slip could hide a button mid-click.
    @Published var controlsVisible = false
    weak var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    /// Unpinned thumbnails dismiss themselves; the file stays in the save folder.
    /// Hovering pauses the countdown, leaving restarts it.
    func armDismiss(after delay: TimeInterval = 30) {
        dismissWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let panel else { return }
            MainActor.assumeIsolated { QuickAccess.close(panel) }
        }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func showControls() {
        hideWork?.cancel()
        hideWork = nil
        controlsVisible = true
    }

    private func scheduleHideControls() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.controlsVisible = false }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
}

@MainActor
enum QuickAccess {
    private static var panels: [(NSPanel, ThumbState)] = []
    private static let width: CGFloat = 220

    static func show(url: URL, isVideo: Bool) {
        Task {
            let image = await Thumbs.make(url, size: 440) ?? NSImage(contentsOf: url) ?? NSImage()
            let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.6
            let h = min(max(width * aspect, 110), 260)
            let state = ThumbState()
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = QuickAccessView(url: url, isVideo: isVideo, image: image, height: h, state: state) { [weak p] in
                if let p { close(p) }
            }
            p.contentView = NSHostingView(rootView: view)
            state.panel = p
            panels.append((p, state))
            layout()
            p.orderFrontRegardless()
            state.armDismiss()
        }
    }

    /// Screenshots open in Preview; videos open in their default player.
    static func openInViewer(_ url: URL, isVideo: Bool) {
        if !isVideo, let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func close(_ p: NSPanel) {
        p.orderOut(nil)
        panels.removeAll { $0.0 === p }
        layout()
    }

    private static func layout() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        var y = vf.minY + 16
        for (p, _) in panels {
            p.setFrameOrigin(NSPoint(x: vf.minX + 16, y: y))
            y += p.frame.height + 10
        }
    }
}

struct QuickAccessView: View {
    let url: URL
    let isVideo: Bool
    let image: NSImage
    let height: CGFloat
    @ObservedObject var state: ThumbState
    let close: () -> Void

    var body: some View {
        ZStack {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 220, height: height).clipped()
            if isVideo && !state.controlsVisible {
                Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9))
            }
            overlay
        }
        .frame(width: 220, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25), lineWidth: 1))
        .onHover { state.hovering = $0 }
        .onTapGesture(count: 2) { QuickAccess.openInViewer(url, isVideo: isVideo) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }

    /// Always in the hierarchy so the buttons exist the instant the pointer arrives;
    /// they fade in and out instead of being inserted and removed.
    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    action("doc.on.doc", "Copy") { Store.copyToPasteboard(url); Toast.show("Copied") }
                    action("square.and.arrow.down", "Save") {
                        if let u = Store.exportCopy(url) { Toast.show("Saved to \(u.deletingLastPathComponent().lastPathComponent)") }
                        else { Toast.show("Save failed") }
                    }
                }
                HStack(spacing: 8) {
                    if isVideo {
                        action("photo.stack", "GIF") {
                            Toast.show("Making GIF…")
                            Task {
                                do { QuickAccess.show(url: try await GIF.make(from: url), isVideo: false) }
                                catch { Toast.show("GIF failed") }
                            }
                        }
                        action("folder", "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } else {
                        action("pencil.tip.crop.circle", "Annotate") { EditorWindow.open(url) }
                        action("pin", "Pin") { Pins.pin(url); close() }
                    }
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.9))
                    }.buttonStyle(.plain).padding(6)
                }
                Spacer()
            }
        }
        .opacity(state.controlsVisible ? 1 : 0)
        .allowsHitTesting(state.controlsVisible)
        .animation(.easeOut(duration: 0.12), value: state.controlsVisible)
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 70, height: 40)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}

// MARK: - Pinned screenshots

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
enum Pins {
    private static var all: [PinPanel] = []

    static func pin(_ url: URL) {
        guard let cg = Store.cgImage(url) else { return }
        pin(cg)
    }

    static func pin(_ cg: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        let p = PinPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentAspectRatio = size
        p.contentView = PinView(image: cg)
        all.append(p)
        if EdgeWidget.isVisible, EdgeWidget.frame != nil {
            dockAll()
        } else { // widget hidden: drop the pin at the pointer, as before
            let mouse = NSEvent.mouseLocation
            p.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2))
        }
        p.orderFrontRegardless()
    }

    static func remove(_ p: NSPanel) {
        p.orderOut(nil)
        all.removeAll { $0 === p }
        dockAll()
    }

    /// Pins hang directly under the edge widget (above it when the widget sits on the
    /// bottom edge, where there is no room below) and follow it wherever it is dragged.
    static func dockAll() {
        guard EdgeWidget.isVisible, let wf = EdgeWidget.frame else { return }
        let vf = EdgeWidget.screen.visibleFrame
        let gap: CGFloat = 8
        var offset: CGFloat = 0
        for p in all {
            let s = p.frame.size
            let below = EdgeWidget.edge != .bottom
            var o = NSPoint(x: wf.midX - s.width / 2,
                            y: below ? wf.minY - gap - s.height - offset : wf.maxY + gap + offset)
            offset += s.height + gap
            o.x = min(max(o.x, vf.minX + 4), max(vf.minX + 4, vf.maxX - s.width - 4))
            o.y = min(max(o.y, vf.minY + 4), max(vf.minY + 4, vf.maxY - s.height - 4))
            p.setFrameOrigin(o)
        }
    }

    static func unlockAll() {
        all.forEach { $0.ignoresMouseEvents = false; $0.alphaValue = max($0.alphaValue, 0.4) }
    }
}

final class PinView: NSView {
    let image: CGImage
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
        NSColor.white.withAlphaComponent(0.3).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { if let w = window { Pins.remove(w as! NSPanel) }; return }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let w = window as? NSPanel { Pins.remove(w) } else { super.keyDown(with: event) }
    }

    /// Scroll to fade the pin in and out.
    override func scrollWheel(with event: NSEvent) {
        guard let w = window else { return }
        w.alphaValue = min(1, max(0.2, w.alphaValue + event.scrollingDeltaY * 0.01))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
        m.addItem(.separator())
        for pct in [100, 75, 50, 25] {
            let i = m.addItem(withTitle: "Opacity \(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            i.tag = pct; i.target = self
        }
        m.addItem(withTitle: "Lock (click through)", action: #selector(lock), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
    }
    @objc private func annotate() {
        if let url = Store.savePNG(image) { EditorWindow.open(url) }
    }
    @objc private func setOpacity(_ i: NSMenuItem) { window?.alphaValue = CGFloat(i.tag) / 100 }
    @objc private func lock() {
        window?.ignoresMouseEvents = true
        Toast.show("Pin locked. Unlock from the Glint menu.")
    }
    @objc private func closePin() { if let w = window as? NSPanel { Pins.remove(w) } }
}

// MARK: - History

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Glint History"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: HistoryView())
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct HistoryView: View {
    @State private var items: [URL] = Store.items()
    private let cols = [GridItem(.adaptive(minimum: 180), spacing: 14)]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                Text("No captures yet. Press \(HotkeySettings.shared.shortcut(.area)?.display ?? "the Capture Area shortcut") to capture an area.")
                    .foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(items, id: \.self) { u in
                    HistoryCell(url: u)
                        .onTapGesture(count: 2) { open(u) }
                        .contextMenu {
                            if u.pathExtension == "png" {
                                Button("Annotate") { EditorWindow.open(u) }
                                Button("Pin") { Pins.pin(u) }
                            }
                            Button("Copy") { Store.copyToPasteboard(u) }
                            Button("Save") { _ = Store.exportCopy(u) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Divider()
                            Button("Move to Trash") {
                                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                                items = Store.items()
                            }
                        }
                }
            }.padding(16)
        }
    }

    private func open(_ u: URL) {
        if u.pathExtension == "png" { EditorWindow.open(u) } else { NSWorkspace.shared.open(u) }
    }
}

struct HistoryCell: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                if let thumb { Image(nsImage: thumb).resizable().scaledToFit().padding(4) }
                if url.pathExtension == "mp4" {
                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                }
            }.frame(height: 120)
            Text(Store.created(url).formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task { thumb = await Thumbs.make(url, size: 360) }
    }
}
