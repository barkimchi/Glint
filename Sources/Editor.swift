import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, filledRect, ellipse, pen, text, textBlock, highlight, pixelate, counter, crop
    var id: String { rawValue }
    static let shapes: [Tool] = [.rect, .filledRect, .ellipse, .line]
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
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
        case .select: return "Select: move, resize, recolor or delete a mark"
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

    /// Points that can be dragged to reshape the mark: the two ends of an arrow or line, the corners of a box.
    var handles: [CGPoint] {
        switch tool {
        case .arrow, .line: return [a, b]
        case .rect, .filledRect, .ellipse, .highlight, .pixelate:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default: return []
        }
    }

    func moved(by d: CGVector) -> Mark {
        var m = self
        m.a = CGPoint(x: a.x + d.dx, y: a.y + d.dy)
        m.b = CGPoint(x: b.x + d.dx, y: b.y + d.dy)
        m.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return m
    }

    /// Moves handle `i` (an index into `handles`) to `p`.
    func reshaped(handle i: Int, to p: CGPoint) -> Mark {
        var m = self
        switch tool {
        case .arrow, .line:
            if i == 0 { m.a = p } else { m.b = p }
        default:
            let r = rect
            let opposite = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][i]
            m.a = opposite; m.b = p
        }
        return m
    }
}

/// Background behind a screenshot: a soft gradient with padding, for posts, decks and docs.
enum Backdrop: Int, CaseIterable, Identifiable {
    case none, sunrise, ocean, mint, grape, slate, paper
    var id: Int { rawValue }
    var name: String { ["None", "Sunrise", "Ocean", "Mint", "Grape", "Slate", "Paper"][rawValue] }
    var colors: [NSColor] {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .none: return []
        case .sunrise: return [c(0xFF9A6B), c(0xFF5E8A)]
        case .ocean: return [c(0x4FACFE), c(0x6A5CFF)]
        case .mint: return [c(0x43E1A6), c(0x2BB8C9)]
        case .grape: return [c(0xA770EF), c(0xF6A6D8)]
        case .slate: return [c(0x434A54), c(0x1F2328)]
        case .paper: return [c(0xF4F1EA), c(0xE2DDD2)]
        }
    }

    /// Draws the gradient over `r` (any CG context).
    func fill(_ r: CGRect, in ctx: CGContext) {
        guard colors.count == 2,
              let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.saveGState(); ctx.clip(to: r)
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        ctx.restoreGState()
    }
}

enum Geometry {
    /// Distance from p to the segment a-b.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
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
    @Published var selected: UUID? // the mark the Select tool is editing
    @Published var backdrop: Backdrop = .none
    @Published var padding: CGFloat = 0.07 // fraction of the image's longer side
    /// Whether the capture already has transparent edges (a window shot with its shadow).
    lazy var hasAlphaEdges: Bool = Self.cornerIsTransparent(base)
    /// Padding in image pixels (0 with no background).
    var pad: CGFloat { backdrop == .none ? 0 : (padding * CGFloat(max(base.width, base.height))).rounded() }
    var cornerRadius: CGFloat { hasAlphaEdges ? 0 : (0.012 * CGFloat(max(base.width, base.height))).rounded() }
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

    // MARK: Editing placed marks

    var selectedIndex: Int? { selected.flatMap { id in marks.firstIndex { $0.id == id } } }

    /// Topmost mark under a point (image pixels), with a little slack for thin strokes.
    func hit(_ p: CGPoint) -> Int? {
        let tol = 8 * unit
        for i in marks.indices.reversed() {
            let mk = marks[i]
            switch mk.tool {
            case .arrow, .line:
                if Geometry.distance(p, mk.a, mk.b) <= tol + 2 * unit { return i }
            case .pen:
                if zip(mk.points, mk.points.dropFirst()).contains(where: { Geometry.distance(p, $0, $1) <= tol }) { return i }
            case .counter:
                if hypot(p.x - mk.b.x, p.y - mk.b.y) <= 18 * unit { return i }
            case .rect, .ellipse:
                let r = mk.rect
                if r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p) { return i }
            default:
                if Renderer.bounds(mk, unit: unit, imageWidth: CGFloat(base.width)).insetBy(dx: -tol, dy: -tol).contains(p) { return i }
            }
        }
        return nil
    }

    /// Records an undo step before an edit (a drag counts as one step).
    func beginEdit() { snapshot() }

    func replaceSelected(_ mk: Mark) {
        guard let i = selectedIndex else { return }
        marks[i] = mk
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        snapshot()
        marks.remove(at: i)
        selected = nil
    }

    func recolorSelected(_ c: NSColor) {
        guard let i = selectedIndex, marks[i].tool != .pixelate else { return }
        snapshot()
        marks[i].color = c
    }

    func undo() {
        selected = nil
        guard let s = undoStack.popLast() else { return }
        redoStack.append((marks, crop)); (marks, crop) = s
    }

    func redo() {
        selected = nil
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
        guard var out = ctx.makeImage() else { return nil }
        if let c = crop, c.width > 2, c.height > 2, let cropped = out.cropping(to: c) { out = cropped }
        return backdrop == .none ? out : framed(out)
    }

    /// The finished image on its background: padding all round, rounded corners and a soft shadow
    /// for plain screenshots (window shots already carry their own shadow and corners).
    func framed(_ img: CGImage) -> CGImage {
        let p = pad, w = CGFloat(img.width), h = CGFloat(img.height)
        let size = CGSize(width: w + 2 * p, height: h + 2 * p)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        backdrop.fill(CGRect(origin: .zero, size: size), in: ctx)
        let r = CGRect(x: p, y: p, width: w, height: h)
        if !hasAlphaEdges {
            let path = CGPath(roundedRect: r, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -p * 0.12), blur: p * 0.45, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path); ctx.clip()
        }
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    static func cornerIsTransparent(_ img: CGImage) -> Bool {
        var px = [UInt8](repeating: 255, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height))) // pixel (0,0) is the bottom-left corner
        return px[3] < 200
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
            case .crop, .select:
                break
            }
        }
    }

    /// The area a mark covers, for hit-testing and the selection outline.
    static func bounds(_ m: Mark, unit: CGFloat, imageWidth: CGFloat) -> CGRect {
        switch m.tool {
        case .arrow, .line:
            return m.rect.insetBy(dx: -10 * unit, dy: -10 * unit)
        case .pen:
            let xs = m.points.map(\.x), ys = m.points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -4 * unit, dy: -4 * unit)
        case .counter:
            return CGRect(x: m.b.x - 15 * unit, y: m.b.y - 15 * unit, width: 30 * unit, height: 30 * unit)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24 * unit, weight: .bold)]
            let z = (m.text as NSString).size(withAttributes: attrs)
            return CGRect(x: m.a.x, y: m.a.y, width: z.width, height: z.height)
        case .textBlock:
            let font = NSFont.systemFont(ofSize: 20 * unit, weight: .semibold)
            let maxW = max(80 * unit, min(420 * unit, imageWidth - m.a.x - 28 * unit))
            let b = (m.text as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let pad = 10 * unit
            return CGRect(x: m.a.x, y: m.a.y, width: ceil(b.width) + pad * 2, height: ceil(b.height) + pad * 2)
        default:
            return m.rect
        }
    }

    /// Dashed outline and handles around the selected mark (preview only, never exported).
    static func selection(_ m: Mark, unit: CGFloat, imageWidth: CGFloat, viewScale s: CGFloat, in ctx: CGContext) {
        let px = 1 / s // one screen point, in image pixels
        ctx.saveGState()
        if m.tool != .arrow && m.tool != .line {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 * px)
            ctx.setLineDash(phase: 0, lengths: [5 * px, 3 * px])
            ctx.stroke(bounds(m, unit: unit, imageWidth: imageWidth).insetBy(dx: -3 * px, dy: -3 * px))
        }
        ctx.setLineDash(phase: 0, lengths: [])
        for h in m.handles {
            let r = CGRect(x: h.x - 5 * px, y: h.y - 5 * px, width: 10 * px, height: 10 * px)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(2 * px); ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
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
    private enum EditDrag { case none, move(CGPoint, Mark), handle(Int, Mark) }
    @State private var editDrag: EditDrag?
    @State private var editRecorded = false
    @State private var showBackdrop = false
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let pad = m.pad
                let outer = CGSize(width: CGFloat(m.base.width) + 2 * pad, height: CGFloat(m.base.height) + 2 * pad)
                let s = min(geo.size.width / outer.width, geo.size.height / outer.height)
                let size = CGSize(width: outer.width * s, height: outer.height * s)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        ctx.withCGContext { cg in
                            cg.scaleBy(x: s, y: s)
                            if pad > 0 { // background preview, then the image inset by the padding
                                m.backdrop.fill(CGRect(origin: .zero, size: outer), in: cg)
                                cg.translateBy(x: pad, y: pad)
                                let r = CGRect(x: 0, y: 0, width: m.base.width, height: m.base.height)
                                if !m.hasAlphaEdges {
                                    let path = CGPath(roundedRect: r, cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius, transform: nil)
                                    cg.saveGState()
                                    cg.setShadow(offset: CGSize(width: 0, height: pad * 0.12), blur: pad * 0.45 * s,
                                                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
                                    cg.addPath(path); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
                                    cg.restoreGState()
                                    cg.addPath(path); cg.clip()
                                }
                            }
                            var all = m.marks
                            if let d = m.draft, d.tool != .crop { all.append(d) }
                            Renderer.draw(all, base: m.base, pixelated: m.pixelated, unit: m.unit, in: cg)
                            let crop = m.draft?.tool == .crop ? m.draft?.rect : m.crop
                            if let c = crop {
                                Renderer.cropOverlay(c, size: CGSize(width: m.base.width, height: m.base.height),
                                                     unit: m.unit, in: cg)
                            }
                            if m.tool == .select, let i = m.selectedIndex {
                                Renderer.selection(m.marks[i], unit: m.unit, imageWidth: CGFloat(m.base.width),
                                                   viewScale: s, in: cg)
                            }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(drag(scale: s, pad: pad))

                    if let p = m.textAt {
                        TextField(m.textTool == .textBlock ? "Text block, then Return" : "Type, then Return",
                                  text: $m.textValue, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .focused($textFocused)
                            .onSubmit { m.commitText() }
                            .onAppear { textFocused = true }
                            .offset(x: (p.x + pad) * s, y: (p.y + pad) * s)
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

    private func drag(scale s: CGFloat, pad: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = CGPoint(x: v.location.x / s - pad, y: v.location.y / s - pad)
                if m.tool == .select { selectDrag(start: CGPoint(x: v.startLocation.x / s - pad, y: v.startLocation.y / s - pad), to: p, scale: s); return }
                if m.textAt != nil { m.commitText() }
                guard m.tool != .text, m.tool != .textBlock, m.tool != .counter else { return }
                if m.draft == nil { m.draft = Mark(tool: m.tool, a: p, b: p, color: m.color, points: [p]) }
                else { m.draft?.b = p; if m.tool == .pen { m.draft?.points.append(p) } }
            }
            .onEnded { v in
                let p = CGPoint(x: v.location.x / s - pad, y: v.location.y / s - pad)
                if m.tool == .select { editDrag = nil; editRecorded = false; return }
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

    /// Select tool: press on a handle to reshape, on a mark to select and move it, on nothing to deselect.
    private func selectDrag(start: CGPoint, to p: CGPoint, scale s: CGFloat) {
        if editDrag == nil {
            if let i = m.selectedIndex,
               let h = m.marks[i].handles.firstIndex(where: { hypot($0.x - start.x, $0.y - start.y) <= 9 / s }) {
                editDrag = .handle(h, m.marks[i])
            } else if let i = m.hit(start) {
                m.selected = m.marks[i].id
                editDrag = .move(start, m.marks[i])
            } else {
                m.selected = nil
                editDrag = EditDrag.none
            }
        }
        guard hypot(p.x - start.x, p.y - start.y) > 0.5 else { return }
        switch editDrag {
        case .move(let st, let orig)?:
            if !editRecorded { m.beginEdit(); editRecorded = true }
            m.replaceSelected(orig.moved(by: CGVector(dx: p.x - st.x, dy: p.y - st.y)))
        case .handle(let h, let orig)?:
            if !editRecorded { m.beginEdit(); editRecorded = true }
            m.replaceSelected(orig.reshaped(handle: h, to: p))
        default: break
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
                Button { m.color = c; m.recolorSelected(c) } label: {
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
            if m.tool == .select, m.selected != nil {
                Button { m.deleteSelected() } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: []).help("Delete the selected mark (Delete)")
            }
            if m.crop != nil {
                Button("Reset Crop") { m.commit(Mark(tool: .crop, a: .zero, b: .zero, color: .clear)); m.crop = nil }
            }
            Spacer()
            Button { showBackdrop.toggle() } label: {
                Label("Background", systemImage: "rectangle.inset.filled").fixedSize()
            }
            .help("Background and padding")
            .popover(isPresented: $showBackdrop, arrowEdge: .bottom) { backdropPicker }
            Button { pin() } label: { Image(systemName: "pin") }.help("Pin to screen")
            Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down").fixedSize() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: m.tool) { _, t in if t != .select { m.selected = nil } }
    }

    private var backdropPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background").font(.headline)
            HStack(spacing: 8) {
                ForEach(Backdrop.allCases) { b in
                    Button { m.backdrop = b } label: {
                        ZStack {
                            if b == .none {
                                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                                Image(systemName: "nosign").foregroundStyle(.secondary)
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: b.colors.map { Color(nsColor: $0) },
                                                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                        }
                        .frame(width: 34, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(m.backdrop == b ? Color.accentColor : .gray.opacity(0.3),
                                                                          lineWidth: m.backdrop == b ? 2.5 : 1))
                    }
                    .buttonStyle(.plain).help(b.name)
                }
            }
            HStack {
                Text("Padding").frame(width: 60, alignment: .leading)
                Slider(value: $m.padding, in: 0.02...0.16).frame(width: 200)
            }
            .disabled(m.backdrop == .none)
        }
        .padding(14)
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
    static var lastModel: EditorModel? // for --demo
    private static var open: [NSWindow] = []

    static func open(_ url: URL) {
        guard let cg = Store.cgImage(url) else { return }
        let model = EditorModel(image: cg)
        lastModel = model
        let screen = Front.pointerScreen
        let scale = screen?.backingScaleFactor ?? 2
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(CGFloat(cg.width) / scale + 40, 860), vf.width * 0.85)
        let h = min(max(CGFloat(cg.height) / scale + 100, 420), vf.height * 0.85)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Annotate · \(url.deletingPathExtension().lastPathComponent)"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: EditorView(m: model) { [weak win] in win?.close() })
        win.contentMinSize = NSSize(width: 860, height: 360)
        open.append(win)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { n in
            MainActor.assumeIsolated { open.removeAll { $0 === n.object as AnyObject } }
        }
        Front.show(win, center: true)
    }
}
