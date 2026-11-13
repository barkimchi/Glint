import AppKit
import AVFoundation
import ScreenCaptureKit

/// `Glint.app/Contents/MacOS/Glint --selftest <outDir>` exercises the real pipelines headlessly:
/// fullscreen capture, area crop, annotation render, OCR and a 3 second recording, then exits.
@MainActor
enum SelfTest {
    static func syntheticPage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rng = SystemRandomNumberGenerator()
        for i in 0..<220 {
            let hue = CGFloat(i % 12) / 12
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
            ctx.fill(CGRect(x: Int.random(in: 0..<width - 60, using: &rng), y: Int.random(in: 0..<height - 20, using: &rng),
                            width: Int.random(in: 20...200, using: &rng), height: Int.random(in: 6...28, using: &rng)))
        }
        return ctx.makeImage()!
    }

    static func same(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let sa = Stitcher.signature(a), sb = Stitcher.signature(b)
        let diff = zip(sa, sb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(diff) / Double(sa.count) < 1.0
    }

    static func run(out: URL) {
        Task {
            var log: [String] = []
            func note(_ s: String) { log.append(s); print(s) }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            note("screenRecordingPermission=\(CGPreflightScreenCaptureAccess())")
            do {
                let c = try await Capture.content()
                guard let d = c.displays.first, let scr = Capture.screen(for: d) else { throw CocoaError(.featureUnsupported) }
                let full = try await Capture.snapshot(d, content: c)
                note("fullscreen=\(full.width)x\(full.height)")
                _ = Store.savePNG(full, to: out.appendingPathComponent("1-fullscreen.png"))

                let f = Frozen(screen: scr, display: d, image: full)
                let area = CGRect(x: 100, y: scr.frame.height - 500, width: 600, height: 400)
                guard let crop = Capture.crop(f, area) else { throw CocoaError(.featureUnsupported) }
                note("area=\(crop.width)x\(crop.height)")
                _ = Store.savePNG(crop, to: out.appendingPathComponent("2-area.png"))
                if let saved = Store.exportCopy(out.appendingPathComponent("2-area.png")) {
                    note("saveFolder=\(saved.deletingLastPathComponent().path)")
                    try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                }

                let m = EditorModel(image: crop)
                let W = CGFloat(crop.width), H = CGFloat(crop.height)
                m.commit(Mark(tool: .rect, a: CGPoint(x: W * 0.1, y: H * 0.1), b: CGPoint(x: W * 0.5, y: H * 0.45), color: .systemRed))
                m.commit(Mark(tool: .arrow, a: CGPoint(x: W * 0.9, y: H * 0.9), b: CGPoint(x: W * 0.55, y: H * 0.5), color: .systemRed))
                m.commit(Mark(tool: .highlight, a: CGPoint(x: W * 0.1, y: H * 0.6), b: CGPoint(x: W * 0.6, y: H * 0.7), color: .systemYellow))
                m.commit(Mark(tool: .pixelate, a: CGPoint(x: W * 0.6, y: H * 0.1), b: CGPoint(x: W * 0.95, y: H * 0.4), color: .black))
                m.commit(Mark(tool: .counter, a: .zero, b: CGPoint(x: W * 0.08, y: H * 0.85), color: .systemBlue, number: m.nextNumber))
                m.commit(Mark(tool: .counter, a: .zero, b: CGPoint(x: W * 0.2, y: H * 0.85), color: .systemBlue, number: m.nextNumber))
                m.commit(Mark(tool: .text, a: CGPoint(x: W * 0.12, y: H * 0.47), b: .zero, color: .systemRed, text: "Glint self-test"))
                m.commit(Mark(tool: .ellipse, a: CGPoint(x: W * 0.62, y: H * 0.5), b: CGPoint(x: W * 0.95, y: H * 0.75), color: .systemGreen))
                m.commit(Mark(tool: .line, a: CGPoint(x: W * 0.05, y: H * 0.95), b: CGPoint(x: W * 0.5, y: H * 0.95), color: .systemOrange))
                m.commit(Mark(tool: .filledRect, a: CGPoint(x: W * 0.35, y: H * 0.78), b: CGPoint(x: W * 0.45, y: H * 0.88), color: .systemPurple))
                m.commit(Mark(tool: .pen, a: .zero, b: .zero, color: .systemBlue,
                              points: (0..<40).map { i in CGPoint(x: W * 0.55 + CGFloat(i) * 5, y: H * 0.85 + sin(CGFloat(i) / 3) * 15) }))
                m.commit(Mark(tool: .textBlock, a: CGPoint(x: W * 0.6, y: H * 0.05), b: .zero, color: .black, text: "Text block works across two lines"))
                let annotated = m.render()!
                _ = Store.savePNG(annotated, to: out.appendingPathComponent("3-annotated.png"))
                m.commit(Mark(tool: .crop, a: CGPoint(x: 0, y: 0), b: CGPoint(x: W / 2, y: H / 2), color: .clear))
                let cropped = m.render()!
                note("annotated=\(annotated.width)x\(annotated.height) cropped=\(cropped.width)x\(cropped.height)")
                m.undo()
                note("undoRestoresFullSize=\(m.render()!.width == annotated.width)")

                let text = await OCR.recognize(annotated)
                note("ocrFoundSelfTestText=\(text.contains("self-test")) ocrLines=\(text.split(separator: "\n").count)")

                // Stitcher: slice a synthetic tall page into overlapping frames, including a repeat and a jump.
                let page = syntheticPage(width: 500, height: 2600)
                let st = Stitcher()
                for y in [0, 180, 180, 470, 900, 1330, 1800] {
                    st.add(page.cropping(to: CGRect(x: 0, y: y, width: 500, height: 800))!)
                }
                let stitched = st.compose()!
                _ = Store.savePNG(stitched, to: out.appendingPathComponent("5-stitched.png"))
                let expected = page.cropping(to: CGRect(x: 0, y: 0, width: 500, height: 2600))!
                note("stitchedHeight=\(stitched.height) expected=2600 strips=\(st.strips.count) skipped=\(st.skipped) pixelMatch=\(Self.same(stitched, expected))")

                // Full page: frames with a fixed toolbar, a fixed sidebar and a fixed footer around the scrolling band.
                let chromeArt = syntheticPage(width: 500, height: 800)
                func windowFrame(_ y: Int) -> CGImage {
                    let ctx = CGContext(data: nil, width: 500, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(chromeArt, in: CGRect(x: 0, y: 0, width: 500, height: 800)) // toolbar 70, footer 30, sidebar 100
                    ctx.draw(page.cropping(to: CGRect(x: 0, y: y, width: 400, height: 700))!,
                             in: CGRect(x: 100, y: 30, width: 400, height: 700))
                    return ctx.makeImage()!
                }
                if let pr = PageProbe.analyze(windowFrame(0), windowFrame(300)) {
                    let pst = Stitcher(); pst.activeCols = pr.cols
                    var last = 0
                    for y in stride(from: 0, through: 1800, by: 300) {
                        last = y
                        pst.add(windowFrame(y).cropping(to: CGRect(x: 0, y: pr.top, width: 500, height: pr.bottom - pr.top))!)
                    }
                    let f0 = windowFrame(0), fN = windowFrame(last)
                    let full = PageProbe.stack([f0.cropping(to: CGRect(x: 0, y: 0, width: 500, height: pr.top))!, pst.compose()!,
                                                fN.cropping(to: CGRect(x: 0, y: pr.bottom, width: 500, height: 800 - pr.bottom))!])!
                    _ = Store.savePNG(full, to: out.appendingPathComponent("7-fullpage.png"))
                    note("pageProbe top=\(pr.top) bottom=\(pr.bottom) expected=70/770 movingCols=\(pr.cols.count)/64 fullPageHeight=\(full.height) expected=\(70 + 2500 + 30) skipped=\(pst.skipped)")
                } else { note("pageProbe=FAILED (no moving band found)") }

                // Live: a real window scrolls itself while we capture the screen region and stitch.
                let live = syntheticPage(width: 500, height: 2000)
                let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
                let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
                iv.image = NSImage(cgImage: live, size: NSSize(width: 500, height: 2000))
                let flip = FlippedView(frame: iv.frame); flip.addSubview(iv)
                sv.documentView = flip
                let lw = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 500), styleMask: .borderless,
                                  backing: .buffered, defer: false)
                lw.contentView = sv; lw.level = .floating; lw.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 300_000_000)
                let lsrc = CGRect(x: 200, y: scr.frame.height - 700, width: 500, height: 500)
                let lst = Stitcher()
                var yOff: CGFloat = 0
                while yOff <= 1500 {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: yOff)); sv.reflectScrolledClipView(sv.contentView)
                    try await Task.sleep(nanoseconds: 120_000_000)
                    let lf = SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])
                    let lc = SCStreamConfiguration(); lc.sourceRect = lsrc
                    lc.width = Int(500 * scr.backingScaleFactor); lc.height = Int(500 * scr.backingScaleFactor); lc.showsCursor = false
                    lst.add(try await SCScreenshotManager.captureImage(contentFilter: lf, configuration: lc))
                    yOff += 137
                }
                lw.orderOut(nil)
                if let ls = lst.compose() { _ = Store.savePNG(ls, to: out.appendingPathComponent("6-live-stitched.png")) }
                note("liveStitchedHeight=\(lst.totalHeight) expected≈\(Int(1959 * scr.backingScaleFactor)) strips=\(lst.strips.count) skipped=\(lst.skipped)")

                let rec = Recorder(url: out.appendingPathComponent("4-recording.mp4"))
                try await rec.start(display: d, source: CGRect(x: 0, y: 0, width: 640, height: 400),
                                    scale: scr.backingScaleFactor, exclude: Capture.ownApps(c))
                // Something must change on screen or ScreenCaptureKit sends only idle frames.
                let w = NSWindow(contentRect: NSRect(x: 40, y: scr.frame.height - 300, width: 200, height: 120),
                                 styleMask: .borderless, backing: .buffered, defer: false)
                w.level = .floating
                w.orderFrontRegardless()
                for i in 0..<30 {
                    w.backgroundColor = i % 2 == 0 ? .systemPink : .systemTeal
                    w.setFrameOrigin(NSPoint(x: 40 + CGFloat(i * 10), y: scr.frame.height - 300))
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                w.orderOut(nil)
                if let url = await rec.stop() {
                    let dur = try await AVURLAsset(url: url).load(.duration).seconds
                    note(String(format: "recording=ok duration=%.1fs", dur))
                    let gif = try await GIF.make(from: url)
                    // Click highlight: overlay ripple must show up inside the recorded video.
                    let gRect = CGRect(x: 0, y: scr.frame.height - 400, width: 640, height: 400)
                    let overlay = ClickOverlay(globalRect: gRect)
                    overlay.window.orderFrontRegardless()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let c2 = try await Capture.content()
                    let crec = Recorder(url: out.appendingPathComponent("8-clicks.mp4"))
                    try await crec.start(display: d, source: CGRect(x: 0, y: 0, width: 640, height: 400),
                                         scale: scr.backingScaleFactor, exclude: Capture.ownApps(c2),
                                         include: overlay.scWindow(in: c2).map { [$0] } ?? [])
                    note("clickOverlayFound=\(overlay.scWindow(in: c2) != nil)")
                    overlay.showPill("⌘⇧4")
                    for i in 0..<6 {
                        overlay.ripple(atScreenPoint: NSPoint(x: 320, y: scr.frame.height - 200), right: i % 2 == 1)
                        try await Task.sleep(nanoseconds: 450_000_000)
                    }
                    overlay.window.orderOut(nil)
                    if let cu = await crec.stop() {
                        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: cu))
                        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                        var hits = 0
                        for t in stride(from: 0.1, to: 2.4, by: 0.15) {
                            guard let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
                            // Look for strong yellow or blue around the ripple centre.
                            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
                            let cx = img.width / 2, cy = img.height / 2, rad = Int(30 * scr.backingScaleFactor)
                            var found = false
                            for yy in stride(from: cy - rad, through: cy + rad, by: 2) {
                                for xx in stride(from: cx - rad, through: cx + rad, by: 2) {
                                    let o = yy * ctx.bytesPerRow + xx * 4
                                    let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                                    if (r > 200 && g > 160 && b < 90) || (b > 200 && r < 90) { found = true }
                                }
                            }
                            if found { hits += 1 }
                        }
                        note("clickRippleFramesWithColor=\(hits)")
                    }
                    // Audio: record with system audio (+ mic if already allowed) while a sound plays.
                    let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    let arec = Recorder(url: out.appendingPathComponent("7-audio.mp4"))
                    try await arec.start(display: d, source: CGRect(x: 0, y: 0, width: 640, height: 400),
                                         scale: scr.backingScaleFactor, exclude: [],
                                         audio: AudioOptions(system: true, microphone: micOK))
                    let w2 = NSWindow(contentRect: NSRect(x: 40, y: scr.frame.height - 300, width: 200, height: 120),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                    w2.level = .floating; w2.orderFrontRegardless()
                    let player = Process()
                    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                    player.arguments = ["/System/Library/Sounds/Glass.aiff"]
                    try? player.run()
                    for i in 0..<25 {
                        w2.backgroundColor = i % 2 == 0 ? .systemOrange : .systemBlue
                        w2.setFrameOrigin(NSPoint(x: 40 + CGFloat(i * 10), y: scr.frame.height - 300))
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    w2.orderOut(nil)
                    if let au = await arec.stop() {
                        let asset = AVURLAsset(url: au)
                        let tracks = try await asset.loadTracks(withMediaType: .audio)
                        var peak: Float = 0
                        if let t = tracks.first {
                            let reader = try AVAssetReader(asset: asset)
                            let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                            reader.add(o); reader.startReading()
                            while let b = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(b) {
                                var len = 0; var ptr: UnsafeMutablePointer<CChar>?
                                CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                                if let ptr { ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { p in
                                    for k in 0..<(len / 2) { peak = max(peak, abs(Float(p[k])) / 32768) } } }
                            }
                        }
                        note(String(format: "audioRecording=ok micIncluded=%@ audioTracks=%d peak=%.3f", micOK ? "yes" : "no", tracks.count, peak))
                    } else { note("audioRecording=FAILED") }
                    note("gif=\(FileManager.default.fileExists(atPath: gif.path))")
                } else { note("recording=FAILED") }
            } catch {
                note("ERROR \(error)")
            }
            try? log.joined(separator: "\n").write(to: out.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
