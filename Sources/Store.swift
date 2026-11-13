import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Every capture lands in History (kept 30 days). "Save" copies it to the save folder (Desktop by default).
@MainActor
enum Store {
    nonisolated static let historyDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glint/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    nonisolated static let saveFolderKey = "saveFolder.v1"
    nonisolated static let defaultSaveDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    /// Where "Save" puts files. Set in Settings; defaults to the Desktop.
    nonisolated static var savedDir: URL {
        let u = UserDefaults.standard.string(forKey: saveFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultSaveDir
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func newURL(ext: String, in dir: URL = historyDir) -> URL {
        let base = "Glint \(fmt.string(from: Date()))"
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        return url
    }

    static func savePNG(_ img: CGImage, to url: URL? = nil) -> URL? {
        let url = url ?? newURL(ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    static func items() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { ["png", "mp4", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted { created($0) > created($1) }
    }

    static func created(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    static func prune(days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for u in items() where created(u) < cutoff { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
    }

    static func exportCopy(_ url: URL) -> URL? {
        let dest = newURL(ext: url.pathExtension, in: savedDir)
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
    }

    static func copyToPasteboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if url.pathExtension == "png", let img = NSImage(contentsOf: url) {
            pb.writeObjects([img])
        } else {
            pb.writeObjects([url as NSURL])
        }
    }

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

enum Thumbs {
    static func make(_ url: URL, size: CGFloat) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2,
                                               representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
    }
}

enum GIF {
    /// Converts an MP4 to a looping GIF at 12 fps, max 960 px on the long side.
    static func make(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let dur = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let fps = 12.0
        let count = max(1, Int(dur * fps))
        let out = video.deletingPathExtension().appendingPathExtension("gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (img, _) = try await gen.image(at: t)
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}
