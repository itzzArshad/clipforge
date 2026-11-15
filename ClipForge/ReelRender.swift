import AVFoundation
import CoreImage
import ImageIO
import UIKit

enum ReelLayout: String, CaseIterable, Identifiable {
    case fit = "Fit", fill = "Fill"
    var id: String { rawValue }
}
enum ReelBackground: String, CaseIterable, Identifiable {
    case aura = "Aura", blur = "Blur", black = "Black"
    var id: String { rawValue }
}
enum CaptionStyleKind: String, CaseIterable, Identifiable {
    case pill = "Pill", pop = "Pop", clean = "Clean"
    var id: String { rawValue }
}

struct ReelStyle: Equatable {
    var layout: ReelLayout = .fit
    var background: ReelBackground = .aura
    var panX: Double = 0.5
    var punch = true
    var hype = true
    var captionsOn = true
    var captionStyle: CaptionStyleKind = .pill
    var accent = 0
    var hook = ""
}

/// Shared, thread-safe render state. The preview player and the exporter both read it every frame,
/// so changing a style value updates the live preview instantly.
final class ReelState {
    let orientation: CGImagePropertyOrientation
    private let lock = NSLock()
    private var _style = ReelStyle()
    private var _levels = Levels(norm: [], env: [])
    private var _pages: [CaptionPage] = []
    private var cache: [String: CIImage] = [:]

    init(orientation: CGImagePropertyOrientation) { self.orientation = orientation }

    var style: ReelStyle {
        get { lock.lock(); defer { lock.unlock() }; return _style }
        set { lock.lock(); _style = newValue; cache.removeAll(); lock.unlock() }
    }
    var levels: Levels {
        get { lock.lock(); defer { lock.unlock() }; return _levels }
        set { lock.lock(); _levels = newValue; lock.unlock() }
    }
    var pages: [CaptionPage] {
        get { lock.lock(); defer { lock.unlock() }; return _pages }
        set { lock.lock(); _pages = newValue; cache.removeAll(); lock.unlock() }
    }

    // MARK: helpers

    private func sample(_ arr: [Float], _ t: Double) -> Float {
        guard !arr.isEmpty else { return 0 }
        let x = max(0, t / AudioAnalyzer.binSeconds)
        let i = min(Int(x), arr.count - 1)
        let j = min(i + 1, arr.count - 1)
        let f = Float(x - Double(i))
        return arr[i] * (1 - f) + arr[j] * f
    }

    private func cached(_ key: String, _ make: () -> CIImage) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        if cache.count > 40 { cache.removeAll() }
        let img = make()
        cache[key] = img
        return img
    }

    private func lanczos(_ img: CIImage, _ scale: CGFloat) -> CIImage {
        guard abs(scale - 1) > 0.01 else { return img }
        return img.applyingFilter("CILanczosScaleTransform",
                                  parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage? {
        guard let f = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        f.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(color, forKey: "inputColor")
        return f.outputImage?.cropped(to: rect)
    }

    /// Two-stage downscale -> blur -> smooth upscale. Much cleaner than a single big blur.
    private func smooth(_ src: CIImage, W: CGFloat, H: CGFloat, down d: CGFloat, zoom: CGFloat,
                        sigma1: CGFloat, sigma2: CGFloat) -> CIImage {
        let ext = src.extent
        let cover = max(W / ext.width, H / ext.height) * zoom
        let s = cover / d
        let sw = ext.width * s, sh = ext.height * s
        var img = lanczos(src, s).transformed(by: CGAffineTransform(translationX: -(sw - W / d) / 2,
                                                                    y: -(sh - H / d) / 2))
        img = img.clampedToExtent().applyingGaussianBlur(sigma: sigma1)
            .cropped(to: CGRect(x: 0, y: 0, width: W / d, height: H / d))
        img = lanczos(img, d / 4)
        img = img.clampedToExtent().applyingGaussianBlur(sigma: sigma2)
            .cropped(to: CGRect(x: 0, y: 0, width: W / 4, height: H / 4))
        return lanczos(img, 4)
    }

    private func background(_ src: CIImage, kind: ReelBackground, W: CGFloat, H: CGFloat, k: CGFloat) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        var bg: CIImage
        switch kind {
        case .black:
            return CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03)).cropped(to: canvas)
        case .blur:
            bg = smooth(src, W: W, H: H, down: 4, zoom: 1.4, sigma1: 12 * k, sigma2: 7 * k)
        case .aura:
            bg = smooth(src, W: W, H: H, down: 72, zoom: 1.0, sigma1: 0.8, sigma2: 10 * k)
        }
        bg = bg.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: kind == .aura ? 1.5 : 1.25,
            kCIInputBrightnessKey: -0.1,
            kCIInputContrastKey: 1.05
        ])
        if let g = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: H * 0.6),
            "inputPoint1": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ])?.outputImage?.cropped(to: canvas) {
            bg = g.composited(over: bg)
        }
        return bg.cropped(to: canvas)
    }

    private func activeCaption(_ pages: [CaptionPage], _ t: Double) -> (Int, Int)? {
        for (pi, p) in pages.enumerated() where t >= p.start - 0.05 && t < p.showUntil {
            var ai = 0
            for (wi, w) in p.words.enumerated() where w.start <= t { ai = wi }
            return (pi, ai)
        }
        return nil
    }

    // MARK: per-frame render

    func frame(from src: CIImage, at t: Double, size: CGSize) -> CIImage {
        lock.lock(); let st = _style; let lv = _levels; let pg = _pages; lock.unlock()

        let W = size.width, H = size.height, k = W / 1080
        let canvas = CGRect(origin: .zero, size: size)
        let env = sample(lv.env, t)
        let maxPunch: CGFloat = st.layout == .fit ? 0.05 : 0.10
        let zoom: CGFloat = 1 + (st.punch ? maxPunch * CGFloat(env * env) : 0)
        let ext = src.extent
        var out: CIImage
        var captionCenterY: CGFloat = 520 * k

        switch st.layout {
        case .fill:
            let s = max(W / ext.width, H / ext.height) * zoom
            let tx = -(ext.width * s - W) * CGFloat(st.panX)
            let ty = -(ext.height * s - H) / 2
            out = src.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
        case .fit:
            let bg = background(src, kind: st.background, W: W, H: H, k: k)
            let sf = min(W / ext.width, H / ext.height) * zoom
            let fw = ext.width * sf, fh = ext.height * sf
            let shift: CGFloat = fh < H * 0.8 ? 90 * k : 0
            let rect = CGRect(x: (W - fw) / 2, y: (H - fh) / 2 + shift, width: fw, height: fh)
            let fg = src.transformed(by: CGAffineTransform(scaleX: sf, y: sf)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            if fw < W - 1 || fh < H - 1,
               let mask = roundedRect(rect, radius: 38 * k, color: .white) {
                let blended = fg.cropped(to: rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask])
                out = blended.composited(over: bg)
            } else {
                out = fg.composited(over: bg)
            }
            captionCenterY = max(440 * k, rect.minY - 230 * k)
        }

        if st.hype {
            let level = CGFloat(env)
            let h = 12 * k
            let track = CGRect(x: 90 * k, y: H - 130 * k, width: W - 180 * k, height: h)
            let fillRect = CGRect(x: track.minX, y: track.minY, width: max(h, track.width * level), height: h)
            if let t1 = roundedRect(track, radius: h / 2, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)),
               let t2 = roundedRect(fillRect, radius: h / 2,
                                    color: CIColor(red: 1, green: 0.85 - 0.6 * level, blue: 0.15, alpha: 1)) {
                out = t2.composited(over: t1.composited(over: out))
            }
        }

        let hook = st.hook.trimmingCharacters(in: .whitespaces)
        if !hook.isEmpty && t < 2.5 {
            let img = cached("hook") { CaptionRenderer.hook(hook, accent: st.accent) }
            let tr = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: 0, y: H - 470 * k))
            out = img.transformed(by: tr).composited(over: out)
        }

        if st.captionsOn, let (pi, ai) = activeCaption(pg, t) {
            let page = pg[pi]
            let img = cached("c\(pi)-\(ai)") {
                CaptionRenderer.image(page: page, active: ai, style: st.captionStyle, accent: st.accent)
            }
            let word = page.words[ai]
            let pop = 1 + 0.07 * CGFloat(max(0, 1 - (t - word.start) / 0.14))
            let tr = CGAffineTransform(translationX: -img.extent.midX, y: -img.extent.midY)
                .concatenating(CGAffineTransform(scaleX: pop * k, y: pop * k))
                .concatenating(CGAffineTransform(translationX: W / 2, y: captionCenterY))
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
    let state: ReelState

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, state: ReelState) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.state = state
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
        let size = request.renderContext.size
        var img = CIImage(cvPixelBuffer: srcBuffer).oriented(instr.state.orientation)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let result = instr.state.frame(from: img, at: request.compositionTime.seconds, size: size)
        ciContext.render(result, to: outBuffer,
                         bounds: CGRect(origin: .zero, size: size),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: outBuffer)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
