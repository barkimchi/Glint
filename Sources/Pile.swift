import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Screenshot pile
//
// Screenshots taken while the previous one is still in the corner stack into one pile, newest on top.
// Drag the pile and every screenshot goes along (into Claude, Slack, Finder...). Click it to fan them
// out; there each card drags, right-clicks and closes on its own. A small button copies them all.

struct PileItem: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
    var aspect: CGFloat { image.size.width > 0 ? image.size.height / image.size.width : 0.6 }
}

@MainActor
final class PileModel: ObservableObject {
    @Published var items: [PileItem] = []
    @Published var expanded = false
    var urls: [URL] { items.map(\.url) }
}

@MainActor
enum PileLayout {
    static let width: CGFloat = 220
    static let peek: CGFloat = 6          // how far each card behind the top one shows
    static let maxPeeks = 2
    static let stripHeight: CGFloat = 132 // card height when fanned out
    static let header: CGFloat = 34

    static func cardHeight(_ item: PileItem) -> CGFloat { min(max(width * item.aspect, 110), 260) }
    static func stripWidth(_ item: PileItem) -> CGFloat { min(max(stripHeight / max(item.aspect, 0.1), 90), 260) }

    /// Panel size for the pile's current state.
    static func size(_ m: PileModel, maxWidth: CGFloat) -> NSSize {
        guard let top = m.items.last else { return NSSize(width: width, height: 110) }
        if m.items.count == 1 { return NSSize(width: width, height: cardHeight(top)) }
        if m.expanded {
            let cards = m.items.reduce(CGFloat(0)) { $0 + stripWidth($1) } + CGFloat(m.items.count - 1) * 10
            return NSSize(width: min(cards + 24, maxWidth), height: stripHeight + header + 24)
        }
        let peeks = CGFloat(min(m.items.count - 1, maxPeeks)) * peek
        return NSSize(width: width + peeks, height: cardHeight(top) + peeks)
    }
}

enum PileClipboard {
    /// One pasteboard item per screenshot, each carrying the file and the PNG, so apps that take
    /// files and apps that take images both get every shot.
    @MainActor static func copy(_ urls: [URL], to pb: NSPasteboard = .general) {
        pb.clearContents()
        let items: [NSPasteboardItem] = urls.map { u in
            let it = NSPasteboardItem()
            it.setString(u.absoluteString, forType: .fileURL)
            if let data = try? Data(contentsOf: u) { it.setData(data, forType: .png) }
            return it
        }
        pb.writeObjects(items)
    }
}

struct PileRootView: View {
    @ObservedObject var model: PileModel
    @ObservedObject var state: ThumbState
    let close: () -> Void

    var body: some View {
        Group {
            if model.items.count == 1, let only = model.items.first {
                QuickAccessView(url: only.url, isVideo: false, image: only.image,
                                height: PileLayout.cardHeight(only), state: state, close: close)
            } else if model.expanded {
                PileExpandedView(model: model, state: state, close: close)
            } else {
                PileCollapsedView(model: model, state: state, close: close)
            }
        }
    }
}

/// The stacked pile: the newest shot on top, older ones peeking out behind, a count badge.
struct PileCollapsedView: View {
    @ObservedObject var model: PileModel
    @ObservedObject var state: ThumbState
    let close: () -> Void

    var body: some View {
        let top = model.items.last!
        let h = PileLayout.cardHeight(top)
        let peeks = min(model.items.count - 1, PileLayout.maxPeeks)
        ZStack(alignment: .bottomLeading) {
            // Cards behind, offset up and to the right.
            ForEach(Array((0..<peeks).reversed()), id: \.self) { i in
                let off = CGFloat(i + 1) * PileLayout.peek
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.22 - Double(i) * 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18), lineWidth: 1))
                    .frame(width: PileLayout.width, height: h)
                    .offset(x: off, y: -off)
            }
            ZStack {
                Image(nsImage: top.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: PileLayout.width, height: h).clipped()
                // Drag takes the whole pile; a click fans it out; right-click acts on the top shot.
                PileDragArea(urls: model.urls, preview: model.items.map(\.image),
                             onClick: { model.expanded = true },
                             menu: { PileMenus.forPile(model: model, close: close) })
                overlay
            }
            .frame(width: PileLayout.width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onHover { state.hovering = $0 }
    }

    private var overlay: some View {
        ZStack {
            Color.black.opacity(state.controlsVisible ? 0.35 : 0).allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    Text("\(model.items.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 22, minHeight: 22).padding(.horizontal, 2)
                        .background(Color(red: 1, green: 0.698, blue: 0.102), in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain).padding(6)
                    .help("Clear all")
                    .opacity(state.controlsVisible ? 1 : 0).allowsHitTesting(state.controlsVisible)
                }
                Spacer()
                if state.controlsVisible {
                    Text("Click to see all · drag to send all")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .allowsHitTesting(false)
                }
                Button {
                    PileClipboard.copy(model.urls); Toast.show("Copied \(model.items.count) screenshots")
                } label: {
                    Label("Copy all", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding(.bottom, 8)
                .opacity(state.controlsVisible ? 1 : 0).allowsHitTesting(state.controlsVisible)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.controlsVisible)
    }
}

/// The fanned-out pile: every shot side by side, each one on its own.
struct PileExpandedView: View {
    @ObservedObject var model: PileModel
    @ObservedObject var state: ThumbState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(model.items.count) screenshots").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                headerButton("doc.on.doc", "Copy all") {
                    PileClipboard.copy(model.urls); Toast.show("Copied \(model.items.count) screenshots")
                }
                headerButton("rectangle.stack", "Stack") { model.expanded = false }
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                }.buttonStyle(.plain).help("Clear all")
            }
            .frame(height: PileLayout.header - 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Oldest on the left, newest on the right: the order they were taken.
                    ForEach(model.items) { item in PileCard(item: item, model: model, close: close) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18), lineWidth: 1))
        .onHover { state.hovering = $0 }
    }

    private func headerButton(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.white.opacity(0.16), in: Capsule()).foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}

/// One shot in the fanned-out pile: drag takes just this one, right-click for its actions.
struct PileCard: View {
    let item: PileItem
    @ObservedObject var model: PileModel
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: PileLayout.stripWidth(item), height: PileLayout.stripHeight).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hover ? 0.6 : 0.2), lineWidth: 1))
            if hover {
                Button { QuickAccess.removeFromPile(item.url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }.buttonStyle(.plain).padding(4).help("Remove from pile")
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { QuickAccess.openInViewer(item.url, isVideo: false) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Copy") { Store.copyToPasteboard(item.url); Toast.show("Copied") }
            Button("Annotate") { EditorWindow.open(item.url) }
            Button("Pin") { Pins.pin(item.url); QuickAccess.removeFromPile(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from Pile") { QuickAccess.removeFromPile(item.url) }
        }
    }
}

@MainActor
enum PileMenus {
    /// Right-click on the stacked pile: actions for the top shot, plus the whole pile.
    static func forPile(model: PileModel, close: @escaping () -> Void) -> NSMenu {
        let m = NSMenu()
        guard let top = model.items.last else { return m }
        m.addItem(BlockMenuItem("Copy This Screenshot") { Store.copyToPasteboard(top.url); Toast.show("Copied") })
        m.addItem(BlockMenuItem("Annotate") { EditorWindow.open(top.url) })
        m.addItem(BlockMenuItem("Pin") { Pins.pin(top.url); QuickAccess.removeFromPile(top.url) })
        m.addItem(BlockMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([top.url]) })
        m.addItem(BlockMenuItem("Remove from Pile") { QuickAccess.removeFromPile(top.url) })
        m.addItem(.separator())
        m.addItem(BlockMenuItem("Copy All \(model.items.count)") {
            PileClipboard.copy(model.urls); Toast.show("Copied \(model.items.count) screenshots")
        })
        m.addItem(BlockMenuItem("Show All") { model.expanded = true })
        m.addItem(BlockMenuItem("Clear Pile", close))
        return m
    }
}

final class BlockMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Transparent AppKit layer over the top card: a drag carries every screenshot as files
/// (SwiftUI's onDrag can only carry one), a plain click calls `onClick`.
struct PileDragArea: NSViewRepresentable {
    let urls: [URL]
    let preview: [NSImage]
    let onClick: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> PileDragNSView { PileDragNSView() }
    func updateNSView(_ v: PileDragNSView, context: Context) {
        v.urls = urls; v.preview = preview; v.onClick = onClick; v.makeMenu = menu
    }
}

final class PileDragNSView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var preview: [NSImage] = []
    var onClick: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    private var downAt: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
        dragging = false
        if event.clickCount == 2, let last = urls.last { QuickAccess.openInViewer(last, isVideo: false); downAt = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, !dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        beginDraggingSession(with: Self.items(urls: urls, preview: preview, at: start), event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard downAt != nil, !dragging, event.clickCount <= 1 else { return }
        onClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    /// One dragging item per screenshot, fanned slightly under the pointer so it reads as a stack.
    static func items(urls: [URL], preview: [NSImage], at point: NSPoint) -> [NSDraggingItem] {
        let w: CGFloat = 120
        return urls.enumerated().map { i, u in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let img = i < preview.count ? preview[i] : NSImage()
            let h = img.size.width > 0 ? w * img.size.height / img.size.width : w * 0.6
            let off = CGFloat(urls.count - 1 - i) * 4
            item.setDraggingFrame(NSRect(x: point.x - w / 2 + off, y: point.y - h / 2 - off, width: w, height: h), contents: img)
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Test

/// `--pile-test <dir>`: takes three made-up screenshots in a row, renders the stacked and fanned-out
/// pile into <dir>, clicks the pile, and logs what a drag and Copy all would carry. Copy all goes to a
/// private pasteboard, never the clipboard.
@MainActor
enum PileTest {
    static func run(_ dir: URL) {
        Task {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glint-pile-test")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let colors: [NSColor] = [.systemBlue, .systemGreen, .systemPink]
            var urls: [URL] = []
            for (i, c) in colors.enumerated() {
                let u = tmp.appendingPathComponent("shot-\(i + 1).png")
                let img = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { r in
                    c.setFill(); r.fill()
                    let s = "Shot \(i + 1)" as NSString
                    s.draw(at: NSPoint(x: 300, y: 210), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 72), .foregroundColor: NSColor.white])
                    return true
                }
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: u)
                }
                urls.append(u)
                QuickAccess.show(url: u, isVideo: false)
                try? await Task.sleep(for: .milliseconds(700))
            }
            let log = { (s: String) in ScrollTest.log("pile-test " + s) }
            log("count=\(QuickAccess.pileURLs.count) order=\(QuickAccess.pileURLs.map(\.lastPathComponent)) size=\(QuickAccess.pilePanel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")")
            QuickAccess.pileState?.hovering = true
            try? await Task.sleep(for: .milliseconds(400))
            Shots.write(to: dir.appendingPathComponent("stacked"))
            // What a drag of the stacked pile carries.
            let items = PileDragNSView.items(urls: QuickAccess.pileURLs, preview: [], at: .zero)
            let carried = items.compactMap { ($0.item as? NSURL)?.lastPathComponent }
            log("drag items=\(items.count) files=\(carried)")
            // Copy all, into a private pasteboard.
            let pb = NSPasteboard(name: NSPasteboard.Name("com.barkimchi.glint.piletest"))
            PileClipboard.copy(QuickAccess.pileURLs, to: pb)
            let pbItems = pb.pasteboardItems ?? []
            log("copy-all items=\(pbItems.count) types=\(pbItems.first?.types.map(\.rawValue) ?? []) files=\(pbItems.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent })")
            pb.releaseGlobally()
            // A plain click on the pile fans it out.
            if let v = QuickAccess.pilePanel?.contentView.flatMap(findDragView), let w = v.window {
                let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        type == .leftMouseDown ? v.mouseDown(with: e) : v.mouseUp(with: e)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            log("after click expanded=\(QuickAccess.pileExpanded) size=\(QuickAccess.pilePanel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")")
            Shots.write(to: dir.appendingPathComponent("expanded"))
            // Removing one from the fanned-out pile, then down to one: the pile turns back into a plain card.
            QuickAccess.removeFromPile(urls[1])
            log("after remove count=\(QuickAccess.pileURLs.count) order=\(QuickAccess.pileURLs.map(\.lastPathComponent))")
            QuickAccess.removeFromPile(urls[0])
            try? await Task.sleep(for: .milliseconds(400))
            log("down to one size=\(QuickAccess.pilePanel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")")
            Shots.write(to: dir.appendingPathComponent("single"))
            // A new shot after the pile was cleared starts a fresh pile.
            QuickAccess.removeFromPile(urls[2])
            log("cleared panel=\(QuickAccess.pilePanel == nil ? "gone" : "still there")")
            QuickAccess.show(url: urls[0], isVideo: false)
            try? await Task.sleep(for: .milliseconds(500))
            log("fresh pile count=\(QuickAccess.pileURLs.count)")
            // Three captures in the same instant still make one pile, in order.
            if let p = QuickAccess.pilePanel { QuickAccess.close(p) }
            for u in urls { QuickAccess.show(url: u, isVideo: false) }
            try? await Task.sleep(for: .milliseconds(1500))
            log("rapid count=\(QuickAccess.pileURLs.count) order=\(QuickAccess.pileURLs.map(\.lastPathComponent)) piles=\(NSApp.windows.filter { $0.isVisible && $0 is NSPanel && $0.frame.width >= 200 }.count)")
            log("hideAfter=\(CornerSettings.hideAfter)")
            try? FileManager.default.removeItem(at: tmp)
            NSApp.terminate(nil)
        }
    }

    private static func findDragView(_ v: NSView) -> PileDragNSView? {
        if let d = v as? PileDragNSView { return d }
        for s in v.subviews { if let d = findDragView(s) { return d } }
        return nil
    }
}
