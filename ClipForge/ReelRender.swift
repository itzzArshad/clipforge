import AVFoundation
import CoreImage
import ImageIO
import UIKit

enum ReelLayout: String, CaseIterable, Identifiable {
    case fit = "Fit + blur"
    case fill = "Fill (crop)"
    var id: String { rawValue }
}

/// Everything the per-frame renderer needs. Shared by all frame requests, so it is thread-safe.
final class ReelConfig {
    let layout: ReelLayout
    let panX: Double
    let punch: Bool
    let hype: Bool
    let hookText: String
    let showCaptions: Bool
    let orientation: CGImagePropertyOrientation
    let levels: Levels
    let pages: [CaptionPage]

    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private var hookImage: CIImage?

    init(layout: ReelLayout, panX: Double, punch: Bool, hype: Bool, hookText: String,
         showCaptions: Bool, orientation: CGImagePropertyOrientation, levels: Levels, pages: [CaptionPage]) {
        self.layout = layout; self.panX = panX; self.punch = punch; self.hype = hype
        self.hookText = hookText; self.showCaptions = showCaptions
        self.orientation = orientation; self.levels = levels; self.pages = pages
    }

    private func sample(_ arr: [Float], _ t: Double) -> Float {
        guard !arr.isEmpty else { return 0 }
        let x = max(0, t / AudioAnalyzer.binSeconds)
        let i = min(Int(x), arr.count - 1)
        let j = min(i + 1, arr.count - 1)
        let f = Float(x - Double(i))
        return arr[i] * (1 - f) + arr[j] * f
    }

    private func cached(_ key: Int, _ make: () -> CIImage) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        if cache.count > 40 { cache.removeAll() }
        let img = make()
        cache[key] = img
        return img
    }

    private func activeCaption(at t: Double) -> (Int, Int)? {
        for (pi, p) in pages.enumerated() where t >= p.start - 0.05 && t < p.showUntil {
            var ai = 0
            for (wi, w) in p.words.enumerated() where w.start <= t { ai = wi }
            return (pi, ai)
        }
        return nil
    }

    func frame(from src: CIImage, at t: Double) -> CIImage {
        let W = Exporter.target.width, H = Exporter.target.height
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let env = sample(levels.env, t)
        let maxPunch: CGFloat = layout == .fit ? 0.05 : 0.10
        let zoom: CGFloat = 1 + (punch ? maxPunch * CGFloat(env * env) : 0)
        let ext = src.extent
        var out: CIImage

        switch layout {
        case .fill:
            let s = max(W / ext.width, H / ext.height) * zoom
            let tx = -(ext.width * s - W) * CGFloat(panX)
            let ty = -(ext.height * s - H) / 2
            out = src.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty)))
        case .fit:
            // blurred, darkened fill behind + full frame (nothing cropped) in front
            let f: CGFloat = 1.0 / 6.0
            let sb = max(W / ext.width, H / ext.height)
            let sw = ext.width * sb * f, sh = ext.height * sb * f
            var bg = src.transformed(by: CGAffineTransform(scaleX: sb * f, y: sb * f)
                .concatenating(CGAffineTransform(translationX: -(sw - W * f) / 2, y: -(sh - H * f) / 2)))
            bg = bg.clampedToExtent().applyingGaussianBlur(sigma: 6)
                .cropped(to: CGRect(x: 0, y: 0, width: W * f, height: H * f))
            bg = bg.transformed(by: CGAffineTransform(scaleX: 1 / f, y: 1 / f))
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.25, kCIInputSaturationKey: 1.15])
            let sf = min(W / ext.width, H / ext.height) * zoom
            let fg = src.transformed(by: CGAffineTransform(scaleX: sf, y: sf)
                .concatenating(CGAffineTransform(translationX: (W - ext.width * sf) / 2, y: (H - ext.height * sf) / 2)))
            out = fg.composited(over: bg)
        }

        if hype {
            let level = CGFloat(env)
            let track = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.18))
                .cropped(to: CGRect(x: 90, y: H - 150, width: 900, height: 14))
            let fill = CIImage(color: CIColor(red: 1, green: 0.85 - 0.6 * level, blue: 0.1, alpha: 1))
                .cropped(to: CGRect(x: 90, y: H - 150, width: max(10, 900 * level), height: 14))
            out = fill.composited(over: track.composited(over: out))
        }

        if !hookText.isEmpty && t < 2.5 {
            let img = cached(-1) { CaptionRenderer.hook(hookText) }
            out = img.transformed(by: CGAffineTransform(translationX: 0, y: H - 520)).composited(over: out)
        }

        if showCaptions, let (pi, ai) = activeCaption(at: t) {
            let page = pages[pi]
            let img = cached(pi * 100 + ai) { CaptionRenderer.image(page: page, active: ai) }
            let word = page.words[ai]
            let pop = 1 + 0.08 * CGFloat(max(0, 1 - (t - word.start) / 0.14))
            let capY: CGFloat = layout == .fit ? 330 : 420
            let tr = CGAffineTransform(translationX: -img.extent.midX, y: -img.extent.midY)
                .concatenating(CGAffineTransform(scaleX: pop, y: pop))
                .concatenating(CGAffineTransform(translationX: W / 2, y: capY + img.extent.height / 2))
            out = img.transformed(by: tr).composited(over: out)
        }
        return out.cropped(to: canvas)
    }
}

final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let config: ReelConfig

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, config: ReelConfig) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.config = config
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

final class ReelCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    private let ciContext = CIContext()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? ReelInstruction,
              let srcBuffer = request.sourceFrame(byTrackID: instr.trackID),
              let outBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "ClipForge", code: 1))
            return
        }
        var img = CIImage(cvPixelBuffer: srcBuffer).oriented(instr.config.orientation)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let result = instr.config.frame(from: img, at: request.compositionTime.seconds)
        ciContext.render(result, to: outBuffer,
                         bounds: CGRect(origin: .zero, size: Exporter.target),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: outBuffer)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
