import AppKit
import SwiftUI

/// Glint's appearance: the original dark look, or Glass, which blurs what's behind the popup,
/// the edge widget and the screenshot pile.
enum GlintLook: String, CaseIterable, Identifiable {
    case dark, glass
    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : "Glass" }
    static let key = "look"
    static var current: GlintLook {
        get { GlintLook(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    static var isGlass: Bool { current == .glass }
}

enum Glass {
    /// A behind-window blur with rounded corners (a mask image, since the blur ignores layer corner radius).
    static func view(radius: CGFloat) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        v.maskImage = mask(radius)
        return v
    }

    static func mask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    static let tile = NSColor.white.withAlphaComponent(0.16)
    static let tileLit = NSColor.white.withAlphaComponent(0.34)
    static let border = NSColor.white.withAlphaComponent(0.32)
}

/// SwiftUI background: Glass blur plus a hairline, or the given solid color for the dark look.
struct LookBackground: View {
    let radius: CGFloat
    let dark: Color
    @AppStorage(GlintLook.key) private var look = GlintLook.dark.rawValue
    var body: some View {
        if look == GlintLook.glass.rawValue {
            GlassBlur(radius: radius)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(nsColor: Glass.border), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(dark)
        }
    }
}

struct GlassBlur: NSViewRepresentable {
    let radius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView { Glass.view(radius: radius) }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
