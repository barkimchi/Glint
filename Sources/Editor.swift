import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case arrow, line, rect, filledRect, ellipse, pen, text, textBlock, highlight, pixelate, counter, crop
    var id: String { rawValue }
    static let shapes: [Tool] = [.rect, .filledRect, .ellipse, .line]
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .filledRect: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .textBlock: return "text.bubble"
        case .highlight: return "highlighter"
        case .pixelate: return "checkerboard.rectangle"
        case .counter: return "1.circle"
        case .crop: return "crop"
        }
    }
    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Box"
        case .filledRect: return "Filled box"
        case .ellipse: return "Ellipse"
        case .pen: return "Free draw"
        case .text: return "Text"
        case .textBlock: return "Text block"
        case .highlight: return "Highlight"
        case .pixelate: return "Pixelate"
        case .counter: return "Step number"
        case .crop: return "Crop"
        }
    }
}

/// One annotation. Points are in image pixels, top-left origin.
struct Mark: Identifiable {
    let id = UUID()
    var tool: Tool
    var a: CGPoint
    var b: CGPoint
    var color: NSColor
    var text = ""
    var number = 0
    var points: [CGPoint] = [] // free draw path
    var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
}

@MainActor
final class EditorModel: ObservableObject {
    let base: CGImage
    let pixelated: CGImage
    let unit: CGFloat
    @Published var marks: [Mark] = []
    @Published var draft: Mark?
    @Published var tool: Tool = .arrow
    @Published var shape: Tool = .rect
    @Published var color: NSColor = .systemRed
    @Published var crop: CGRect?
    @Published var textAt: CGPoint?
    @Published var textValue = ""
    var textTool: Tool = .text
    private var undoStack: [([Mark], CGRect?)] = []
    private var redoStack: [([Mark], CGRect?)] = []

    init(image: CGImage) {
        base = image
        unit = max(1, CGFloat(max(image.width, image.height)) / 1200)
        pixelated = Self.pixelate(image, unit: unit)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var nextNumber: Int { (marks.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1 }

    func commit(_ m: Mark) {
        snapshot()
        if m.tool == .crop { crop = m.rect.integral } else { marks.append(m) }
    }

    func commitText() {
        defer { textAt = nil; textValue = "" }
        guard let p = textAt, !textValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commit(Mark(tool: textTool, a: p, b: p, color: color, text: textValue))
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append((marks, crop)); (marks, crop) = s
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append((marks, crop)); (marks, crop) = s
    }

    private func snapshot() { undoStack.append((marks, crop)); redoStack.removeAll() }

    func render() -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)) // flip to top-left origin, same as the on-screen Canvas
        ctx.scaleBy(x: 1, y: -1)
        Renderer.draw(marks, base: base, pixelated: pixelated, unit: unit, in: ctx)
        guard let out = ctx.makeImage() else { return nil }
        if let c = crop, c.width > 2, c.height > 2 { return out.cropping(to: c) }
        return out
    }

    private static func pixelate(_ img: CGImage, unit: CGFloat) -> CGImage {
        let ci = CIImage(cgImage: img)
        let f = CIFilter.pixellate()
        f.inputImage = ci.clampedToExtent()
        f.scale = Float(14 * unit)
        f.center = .zero
        guard let out = f.outputImage?.cropped(to: ci.extent),
              let cg = CIContext().createCGImage(out, from: ci.extent) else { return img }
        return cg
    }
}

/// Shared drawing for the live preview and the exported PNG. The context must be y-down, in pixels.
enum Renderer {
    static func draw(_ marks: [Mark], base: CGImage, pixelated: CGImage, unit: CGFloat, in ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        image(base, in: full, ctx)
        for m in marks {
            switch m.tool {
            case .pixelate:
                ctx.saveGState(); ctx.clip(to: m.rect); image(pixelated, in: full, ctx); ctx.restoreGState()
            case .highlight:
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(m.color.withAlphaComponent(0.45).cgColor)
                ctx.fill(m.rect)
                ctx.restoreGState()
            case .rect:
                ctx.saveGState()
                ctx.setStrokeColor(m.color.cgColor)
                ctx.setLineWidth(3 * unit)
                ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil))
                ctx.strokePath()
                ctx.restoreGState()
            case .arrow:
                arrow(m, unit, ctx)
            case .line:
                ctx.saveGState()
                ctx.setStrokeColor(m.color.cgColor); ctx.setLineWidth(4 * unit); ctx.setLineCap(.round)
                ctx.move(to: m.a); ctx.addLine(to: m.b); ctx.strokePath()
                ctx.restoreGState()
            case .filledRect:
                ctx.saveGState()
                ctx.setFillColor(m.color.cgColor)
                ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            case .ellipse:
                ctx.saveGState()
                ctx.setStrokeColor(m.color.cgColor); ctx.setLineWidth(3 * unit)
                ctx.strokeEllipse(in: m.rect)
                ctx.restoreGState()
            case .pen:
                guard let first = m.points.first else { break }
                ctx.saveGState()
                ctx.setStrokeColor(m.color.cgColor); ctx.setLineWidth(4 * unit)
                ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.move(to: first)
                // Midpoint smoothing: quadratic curves through stroke midpoints.
                for i in 1..<max(m.points.count, 1) {
                    let p0 = m.points[i - 1], p1 = m.points[i]
                    ctx.addQuadCurve(to: CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), control: p0)
                }
                if let last = m.points.last { ctx.addLine(to: last) }
                ctx.strokePath()
                ctx.restoreGState()
            case .textBlock:
                let font = NSFont.systemFont(ofSize: 20 * unit, weight: .semibold)
                let fg: NSColor = [NSColor.white, .systemYellow].contains(m.color) ? .black : .white
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                let maxW = max(80 * unit, min(420 * unit, full.width - m.a.x - 28 * unit))
                let bounds = (m.text as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin], attributes: attrs)
                let pad = 10 * unit
                let box = CGRect(x: m.a.x, y: m.a.y, width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2)
                ctx.saveGState()
                ctx.setFillColor(m.color.cgColor)
                ctx.setShadow(offset: CGSize(width: 0, height: 2 * unit), blur: 6 * unit,
                              color: NSColor.black.withAlphaComponent(0.3).cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8 * unit, cornerHeight: 8 * unit, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
                withNS(ctx) {
                    (m.text as NSString).draw(with: box.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin],
                                              attributes: attrs)
                }
            case .counter:
                let r = 15 * unit
                ctx.setFillColor(m.color.cgColor)
                ctx.fillEllipse(in: CGRect(x: m.b.x - r, y: m.b.y - r, width: 2 * r, height: 2 * r))
                text("\(m.number)", font: .systemFont(ofSize: 17 * unit, weight: .bold), color: .white,
                     centeredAt: m.b, ctx)
            case .text:
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 24 * unit, weight: .bold),
                    .foregroundColor: m.color,
                    .strokeColor: NSColor.white,
                    .strokeWidth: -3.0,
                ]
                withNS(ctx) { (m.text as NSString).draw(at: m.a, withAttributes: attrs) }
            case .crop:
                break
            }
        }
    }

    static func cropOverlay(_ c: CGRect, size: CGSize, unit: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addRect(CGRect(origin: .zero, size: size))
        ctx.addRect(c)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 * unit)
        ctx.setLineDash(phase: 0, lengths: [6 * unit, 4 * unit])
        ctx.stroke(c)
        ctx.restoreGState()
    }

    private static func image(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private static func arrow(_ m: Mark, _ unit: CGFloat, _ ctx: CGContext) {
        let head = 20 * unit
        let ang = atan2(m.b.y - m.a.y, m.b.x - m.a.x)
        let neck = CGPoint(x: m.b.x - cos(ang) * head * 0.8, y: m.b.y - sin(ang) * head * 0.8)
        ctx.saveGState()
        ctx.setStrokeColor(m.color.cgColor)
        ctx.setFillColor(m.color.cgColor)
        ctx.setLineWidth(4 * unit)
        ctx.setLineCap(.round)
        ctx.move(to: m.a); ctx.addLine(to: neck); ctx.strokePath()
        ctx.move(to: m.b)
        ctx.addLine(to: CGPoint(x: m.b.x - cos(ang - 0.45) * head, y: m.b.y - sin(ang - 0.45) * head))
        ctx.addLine(to: CGPoint(x: m.b.x - cos(ang + 0.45) * head, y: m.b.y - sin(ang + 0.45) * head))
        ctx.closePath(); ctx.fillPath()
        ctx.restoreGState()
    }

    private static func text(_ s: String, font: NSFont, color: NSColor, centeredAt p: CGPoint, _ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        withNS(ctx) { (s as NSString).draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs) }
    }

    /// AppKit text drawing needs an NSGraphicsContext; `flipped: true` matches our y-down space.
    private static func withNS(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct EditorView: View {
    @ObservedObject var m: EditorModel
    let close: () -> Void
    @FocusState private var textFocused: Bool
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let s = min(geo.size.width / CGFloat(m.base.width), geo.size.height / CGFloat(m.base.height))
                let size = CGSize(width: CGFloat(m.base.width) * s, height: CGFloat(m.base.height) * s)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        ctx.withCGContext { cg in
                            cg.scaleBy(x: s, y: s)
                            var all = m.marks
                            if let d = m.draft, d.tool != .crop { all.append(d) }
                            Renderer.draw(all, base: m.base, pixelated: m.pixelated, unit: m.unit, in: cg)
                            let crop = m.draft?.tool == .crop ? m.draft?.rect : m.crop
                            if let c = crop {
                                Renderer.cropOverlay(c, size: CGSize(width: m.base.width, height: m.base.height),
                                                     unit: m.unit, in: cg)
                            }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(drag(scale: s))

                    if let p = m.textAt {
                        TextField(m.textTool == .textBlock ? "Text block, then Return" : "Type, then Return",
                                  text: $m.textValue, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .focused($textFocused)
                            .onSubmit { m.commitText() }
                            .onAppear { textFocused = true }
                            .offset(x: p.x * s, y: p.y * s)
                    }
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(20)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func drag(scale s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = CGPoint(x: v.location.x / s, y: v.location.y / s)
                if m.textAt != nil { m.commitText() }
                guard m.tool != .text, m.tool != .textBlock, m.tool != .counter else { return }
                if m.draft == nil { m.draft = Mark(tool: m.tool, a: p, b: p, color: m.color, points: [p]) }
                else { m.draft?.b = p; if m.tool == .pen { m.draft?.points.append(p) } }
            }
            .onEnded { v in
                let p = CGPoint(x: v.location.x / s, y: v.location.y / s)
                defer { m.draft = nil }
                switch m.tool {
                case .text, .textBlock: m.textTool = m.tool; m.textAt = p
                case .counter: m.commit(Mark(tool: .counter, a: p, b: p, color: m.color, number: m.nextNumber))
                default:
                    guard var d = m.draft else { return }
                    d.b = p
                    if m.tool == .pen { d.points.append(p); if d.points.count > 2 { m.commit(d) } }
                    else if hypot(d.b.x - d.a.x, d.b.y - d.a.y) > 6 * m.unit { m.commit(d) }
                }
            }
    }

    private func toolButton(_ t: Tool) -> some View {
        Button { m.tool = t } label: {
            Image(systemName: t.symbol).frame(width: 30, height: 26)
                .background(m.tool == t ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(t.label)
    }

    /// One toolbar slot for all shapes: click uses the last shape, the arrow picks another.
    private var shapeMenu: some View {
        Menu {
            ForEach(Tool.shapes) { t in
                Button { m.shape = t; m.tool = t } label: { Label(t.label, systemImage: t.symbol) }
            }
        } label: {
            Image(systemName: m.shape.symbol)
        } primaryAction: {
            m.tool = m.shape
        }
        .menuStyle(.borderlessButton)
        .frame(width: 44, height: 26)
        .background(Tool.shapes.contains(m.tool) ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .help("Shapes")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases.filter { !Tool.shapes.contains($0) || $0 == .rect }) { t in
                if t == .rect { shapeMenu } else { toolButton(t) }
            }
            Divider().frame(height: 20)
            ForEach(colors, id: \.self) { c in
                Button { m.color = c } label: {
                    Circle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(m.color == c ? Color.primary : Color.gray.opacity(0.4),
                                                 lineWidth: m.color == c ? 2 : 1))
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 20)
            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!m.canUndo).help("Undo")
            Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!m.canRedo).help("Redo")
            if m.crop != nil {
                Button("Reset Crop") { m.commit(Mark(tool: .crop, a: .zero, b: .zero, color: .clear)); m.crop = nil }
            }
            Spacer()
            Button { pin() } label: { Image(systemName: "pin") }.help("Pin to screen")
            Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down").fixedSize() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func copy() {
        guard let img = m.render() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: .zero)])
        Toast.show("Copied")
    }

    private func save() {
        guard let img = m.render(), let url = Store.savePNG(img), Store.exportCopy(url) != nil else {
            Toast.show("Save failed"); return
        }
        Toast.show("Saved to \(Store.savedDir.lastPathComponent)")
        close()
    }

    private func pin() {
        guard let img = m.render() else { return }
        Pins.pin(img)
    }
}

@MainActor
enum EditorWindow {
    private static var open: [NSWindow] = []

    static func open(_ url: URL) {
        guard let cg = Store.cgImage(url) else { return }
        let model = EditorModel(image: cg)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(CGFloat(cg.width) / scale + 40, 860), vf.width * 0.85)
        let h = min(max(CGFloat(cg.height) / scale + 100, 420), vf.height * 0.85)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Annotate · \(url.deletingPathExtension().lastPathComponent)"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: EditorView(m: model) { [weak win] in win?.close() })
        win.contentMinSize = NSSize(width: 860, height: 360)
        win.center()
        open.append(win)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { n in
            MainActor.assumeIsolated { open.removeAll { $0 === n.object as AnyObject } }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
