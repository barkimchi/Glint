import AVFoundation
import ScreenCaptureKit
import Vision

struct AudioOptions {
    var system = false
    var microphone = false
}

/// Screen recording: SCStream delivers video frames plus optional system-audio and microphone
/// buffers; AVAssetWriter encodes them (H.264 + AAC) into an MP4. When both audio sources are on,
/// they are written as two tracks and then mixed into one, so every player hears both.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var systemAudio: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "glint.recorder")
    private var started = false
    private var startPTS = CMTime.zero
    private var lastPTS = CMTime.zero
    private var writeURL: URL

    init(url: URL) {
        self.url = url
        self.writeURL = url
    }

    private static func aacInput(channels: Int) -> AVAssetWriterInput {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        i.expectsMediaDataInRealTime = true
        return i
    }

    /// `source` is in display-local points with a top-left origin.
    func start(display: SCDisplay, source: CGRect, scale: CGFloat, exclude: [SCRunningApplication],
               include: [SCWindow] = [], audio: AudioOptions = AudioOptions()) async throws {
        // `include` re-adds specific windows of excluded apps (the click-highlight overlay).
        let filter = SCContentFilter(display: display, excludingApplications: exclude, exceptingWindows: include)
        let w = Int(source.width * scale) & ~1 // H.264 wants even dimensions
        let h = Int(source.height * scale) & ~1
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = source
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6
        if audio.system {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
        }
        if audio.microphone { cfg.captureMicrophone = true }

        if audio.system && audio.microphone {
            writeURL = url.deletingPathExtension().appendingPathExtension("tracks.mp4")
        }
        let writer = try AVAssetWriter(outputURL: writeURL, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 4)],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if audio.system { let a = Self.aacInput(channels: 2); writer.add(a); systemAudio = a }
        if audio.microphone { let a = Self.aacInput(channels: 1); writer.add(a); mic = a }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        self.writer = writer
        self.video = video

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio.system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if audio.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer, let video else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit also sends "idle" frames when nothing changed; only complete frames carry pixels.
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            let pts = sb.presentationTimeStamp
            if !started { writer.startSession(atSourceTime: pts); startPTS = pts; started = true }
            if video.isReadyForMoreMediaData { video.append(sb) }
            lastPTS = pts
        case .audio:
            append(sb, to: systemAudio)
        case .microphone:
            append(sb, to: mic)
        @unknown default:
            break
        }
    }

    /// Audio is only written once the video timeline has started, so the tracks line up.
    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard started, let input, sb.presentationTimeStamp >= startPTS, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Glint recording stopped: \(error.localizedDescription)")
    }

    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        let written: URL? = await withCheckedContinuation { cont in
            queue.async {
                guard self.started, let writer = self.writer, let video = self.video else {
                    self.writer?.cancelWriting(); cont.resume(returning: nil); return
                }
                video.markAsFinished()
                self.systemAudio?.markAsFinished()
                self.mic?.markAsFinished()
                writer.endSession(atSourceTime: self.lastPTS)
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed ? self.writeURL : nil)
                }
            }
        }
        guard let written else { return nil }
        guard written != url else { return url }
        // Two audio tracks: many players only play the first, so mix them into one.
        if await Self.mixDown(written, to: url) {
            try? FileManager.default.removeItem(at: written)
            return url
        }
        try? FileManager.default.moveItem(at: written, to: url) // fall back to the two-track file
        return url
    }

    /// Copies the video untouched and mixes every audio track into one AAC track.
    static func mixDown(_ src: URL, to dst: URL) async -> Bool {
        do {
            let asset = AVURLAsset(url: src)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { return false }
            let aTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !aTracks.isEmpty else { return false }
            let vFormat = try await vTrack.load(.formatDescriptions).first

            let reader = try AVAssetReader(asset: asset)
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil) // passthrough
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(vOut); reader.add(aOut)

            let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
            let aIn = aacInput(channels: 2)
            aIn.expectsMediaDataInRealTime = false
            writer.add(vIn); writer.add(aIn)
            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            // Inputs must be fed in parallel: AVAssetWriter interleaves and stalls one input until the other catches up.
            await withTaskGroup(of: Void.self) { g in
                for (input, output, label) in [(vIn, vOut as AVAssetReaderOutput, "v"), (aIn, aOut as AVAssetReaderOutput, "a")] {
                    g.addTask {
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            let q = DispatchQueue(label: "glint.mix.\(label)")
                            input.requestMediaDataWhenReady(on: q) {
                                while input.isReadyForMoreMediaData {
                                    guard let sb = output.copyNextSampleBuffer() else {
                                        input.markAsFinished(); c.resume(); return
                                    }
                                    input.append(sb)
                                }
                            }
                        }
                    }
                }
            }
            await writer.finishWriting()
            return writer.status == .completed
        } catch {
            NSLog("Glint audio mix failed: \(error.localizedDescription)")
            return false
        }
    }
}

enum OCR {
    /// On-device text recognition (Vision). QR/barcode payloads come first if present.
    static func recognize(_ img: CGImage) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let text = VNRecognizeTextRequest()
                text.recognitionLevel = .accurate
                text.usesLanguageCorrection = true
                text.automaticallyDetectsLanguage = true
                let codes = VNDetectBarcodesRequest()
                try? VNImageRequestHandler(cgImage: img).perform([text, codes])
                let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
                cont.resume(returning: (payloads + lines).joined(separator: "\n"))
            }
        }
    }
}
