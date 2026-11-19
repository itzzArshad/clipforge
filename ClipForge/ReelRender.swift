import AVFoundation
import CoreImage
import ImageIO
import UIKit

enum ReelLayout: String, CaseIterable, Identifiable {
    case stream = "Stream", fit = "Fit", fill = "Fill"
    var id: String { rawValue }
}
enum ReelBackground: String, CaseIterable, Identifiable {
    case aura = "Aura", blur = "Blur", black = "Black"
    var id: String { rawValue }
}
enum CaptionScript: String, CaseIterable, Identifiable {
    case hinglish = "Hinglish", native = "Native"
    var id: String { rawValue }
}

struct ReelStyle: Equatable {
    var layout: ReelLayout = .fit
    var background: ReelBackground = .aura
    var panX: Double = 0.5
    var facecam: CGRect? = nil          // normalised, top-left origin, in the source frame
    var camShare: Double = 0.40         // stream layout: height share of the facecam panel

    var punch = true
    var hype = false
    var slam = true                     // "peak slam": flash + giant word on the loudest moment
    var progressBar = true              // retention bar along the top

    var captionsOn = true
    var captionStyle: CaptionStyleKind = .bounce
    var script: CaptionScript = .hinglish
    var accent = 0
    var hook = ""
    var hookStays = true                // keep the hook on screen for the whole clip (PeakCut style)

    var watermarkOn = false
    var watermarkText = "@yourhandle"
    var watermarkPos: WatermarkPosition = .topRight
    var watermarkLook: WatermarkLook = .tag
    var watermarkOpacity = 0.85
    var watermarkSize = 1.0
}

struct SlamCue: Equatable {
    var time: Double     // composition time
    var word: String
}

/// Shared, thread-safe render state. The preview player and the exporter read it every frame,
/// so changing a style value updates the live preview instantly. Each export gets its own copy.
final class ReelState {
    let orientation: CGImagePropertyOrientation
    private let lock = NSLock()
    private var _style = ReelStyle()
    private var _levels = Levels(norm: [], env: [])
    private var _pages: [CaptionPage] = []
    private var _slam: SlamCue?
    private var _duration = 0.0
    private var _logo: UIImage?
    private var cache: [String: CIImage] = [:]

    init(orientation: CGImagePropertyOrientation) { self.orientation = orientation }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    var style: ReelStyle {
        get { locked { _style } }
        set { locked { _style = newValue; cache.removeAll() } }
    }
    var levels: Levels {
        get { locked { _levels } }
        set { locked { _levels = newValue } }
    }
    var pages: [CaptionPage] {
        get { locked { _pages } }
        set { locked { _pages = newValue; cache.removeAll() } }
    }
    var slam: SlamCue? {
        get { locked { _slam } }
        set { locked { _slam = newValue; cache.removeValue(forKey: "slam") } }
    }
    var duration: Double {
        get { locked { _duration } }
        set { locked { _duration = newValue } }
    }
    var logo: UIImage? {
        get { locked { _logo } }
        set { locked { _logo = newValue; cache.removeValue(forKey: "wm") } }
    }

    func copy() -> ReelState {
        let s = ReelState(orientation: orientation)
        s.style = style; s.levels = levels; s.pages = pages; s.slam = slam; s.duration = duration; s.logo = logo
        return s
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
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        let img = make()
        lock.lock()
        if cache.count > 60 { cache.removeAll() }
        cache[key] = img
        lock.unlock()
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

    private func solid(_ rect: CGRect, _ color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: rect)
    }

    /// Scales `img` to cover `rect` (crop the overflow), with a horizontal pan 0...1.
    private func cover(_ img: CIImage, into rect: CGRect, zoom: CGFloat = 1, panX: CGFloat = 0.5) -> CIImage {
        let e = img.extent
        let s = max(rect.width / e.width, rect.height / e.height) * zoom
        let tx = rect.minX - (e.width * s - rect.width) * panX - e.minX * s
        let ty = rect.minY - (e.height * s - rect.height) / 2 - e.minY * s
        return img.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty)))
            .cropped(to: rect)
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
            return solid(canvas, CIColor(red: 0.04, green: 0.04, blue: 0.045))
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

    private func withAlpha(_ img: CIImage, _ a: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    private func accentCI(_ accent: Int, alpha: CGFloat = 1) -> CIColor {
        let c = CaptionRenderer.palette[min(max(accent, 0), CaptionRenderer.palette.count - 1)]
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    // MARK: per-frame render

    func frame(from src: CIImage, at t: Double, size: CGSize) -> CIImage {
        lock.lock()
        let st = _style, lv = _levels, pg = _pages, slam = _slam, dur = _duration, logo = _logo
        lock.unlock()

        let W = size.width, H = size.height, k = W / 1080
        let canvas = CGRect(origin: .zero, size: size)
        let env = sample(lv.env, t)
        let ext = src.extent
        var out: CIImage
        // PeakCut's geometry (render.geometry), in Core Image's bottom-up coordinates
        var captionCenterY: CGFloat = H - 1380 * k
        var hookTop: CGFloat = H - 300 * k
        let vertical = ext.height >= ext.width

        // slam timing
        var slamAge: Double? = nil
        if st.slam, let s = slam, t >= s.time, t < s.time + 0.95 { slamAge = t - s.time }
        let slamPunch: CGFloat = slamAge.map { CGFloat(max(0, 1 - $0 / 0.35)) } ?? 0

        switch (vertical && st.layout == .fit) ? .fill : st.layout {
        case .stream:
            let topH = (H * CGFloat(st.camShare)).rounded()
            let gameRect = CGRect(x: 0, y: 0, width: W, height: H - topH)
            let camRect = CGRect(x: 0, y: H - topH, width: W, height: topH)
            let zoom: CGFloat = 1 + (st.punch ? 0.10 * CGFloat(env * env) : 0) + 0.06 * slamPunch
            out = solid(canvas, CIColor(red: 0.04, green: 0.04, blue: 0.045))
            out = cover(src, into: gameRect, zoom: zoom, panX: CGFloat(st.panX)).composited(over: out)
            if let f = st.facecam {
                let cr = CGRect(x: ext.minX + f.minX * ext.width, y: ext.minY + (1 - f.maxY) * ext.height,
                                width: f.width * ext.width, height: f.height * ext.height)
                let cam = src.cropped(to: cr)
                let camZoom: CGFloat = 1 + 0.04 * CGFloat(env)
                out = cover(cam, into: camRect, zoom: camZoom).composited(over: out)
            } else {
                out = background(src, kind: .aura, W: W, H: H, k: k).cropped(to: camRect).composited(over: out)
            }
            // seam: accent bar that thickens and brightens with the streamer's voice
            let seamH = (6 + 10 * CGFloat(env)) * k
            let seam = CGRect(x: 0, y: camRect.minY - seamH / 2, width: W, height: seamH)
            out = solid(seam, accentCI(st.accent, alpha: 0.55 + 0.45 * CGFloat(env))).composited(over: out)
            captionCenterY = gameRect.maxY - 260 * k
            hookTop = gameRect.maxY - 110 * k

        case .fill:
            let zoom: CGFloat = 1 + (st.punch ? 0.10 * CGFloat(env * env) : 0) + 0.06 * slamPunch
            out = cover(src, into: canvas, zoom: zoom, panX: CGFloat(st.panX))

        case .fit:
            let zoom: CGFloat = 1 + (st.punch ? 0.05 * CGFloat(env * env) : 0) + 0.04 * slamPunch
            let bg = background(src, kind: st.background, W: W, H: H, k: k)
            let sf = min(W / ext.width, H / ext.height) * zoom
            let fw = ext.width * sf, fh = ext.height * sf
            let rect = CGRect(x: (W - fw) / 2, y: (H - fh) / 2, width: fw, height: fh)
            let fg = src.transformed(by: CGAffineTransform(scaleX: sf, y: sf)
                .concatenating(CGAffineTransform(translationX: rect.minX - ext.minX * sf, y: rect.minY - ext.minY * sf)))
            if fw < W - 1 || fh < H - 1,
               let mask = roundedRect(rect, radius: 38 * k, color: .white) {
                let blended = fg.cropped(to: rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask])
                out = blended.composited(over: bg)
            } else {
                out = fg.composited(over: bg)
            }
            // hook above the video, captions below it
            hookTop = min(H - 230 * k, rect.maxY + 190 * k)
            captionCenterY = max(280 * k, rect.minY - 180 * k)
        }

        // hype meter (optional, sits above the bottom UI of Reels/Shorts)
        if st.hype {
            let level = CGFloat(env)
            let h = 12 * k
            let track = CGRect(x: 90 * k, y: 150 * k, width: W - 180 * k, height: h)
            let fillRect = CGRect(x: track.minX, y: track.minY, width: max(h, track.width * level), height: h)
            if let t1 = roundedRect(track, radius: h / 2, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)),
               let t2 = roundedRect(fillRect, radius: h / 2, color: accentCI(st.accent)) {
                out = t2.composited(over: t1.composited(over: out))
            }
        }

        // retention bar along the very top
        if st.progressBar, dur > 0 {
            let h = 8 * k
            let p = CGFloat(min(max(t / dur, 0), 1))
            out = solid(CGRect(x: 0, y: H - h, width: W, height: h), CIColor(red: 1, green: 1, blue: 1, alpha: 0.15)).composited(over: out)
            out = solid(CGRect(x: 0, y: H - h, width: W * p, height: h), accentCI(st.accent)).composited(over: out)
        }

        // watermark
        if st.watermarkOn, !(st.watermarkText.isEmpty && logo == nil) {
            let img = cached("wm") {
                Overlay.watermark(text: st.watermarkText, logo: logo, look: st.watermarkLook, accent: st.accent, size: st.watermarkSize)
            }
            let iw = img.extent.width * k, ih = img.extent.height * k
            let m = 40 * k
            let top = H - 70 * k - ih
            var p = CGPoint(x: m, y: top)
            switch st.watermarkPos {
            case .topLeft: p = CGPoint(x: m, y: top)
            case .topRight: p = CGPoint(x: W - m - iw, y: top)
            case .top: p = CGPoint(x: (W - iw) / 2, y: top)
            case .bottomLeft: p = CGPoint(x: m, y: 240 * k)
            case .bottomRight: p = CGPoint(x: W - m - iw, y: 240 * k)
            case .center: p = CGPoint(x: (W - iw) / 2, y: (H - ih) / 2)
            }
            let placed = img.transformed(by: CGAffineTransform(scaleX: k, y: k)
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
            out = withAlpha(placed, CGFloat(st.watermarkOpacity)).composited(over: out)
        }

        // hook sticker for the first 2.5 s
        let hook = st.hook.trimmingCharacters(in: .whitespaces)
        if !hook.isEmpty && (st.hookStays || t < 2.5) {
            let img = cached("hook") { CaptionRenderer.hook(hook, accent: st.accent) }
            let intro = CGFloat(min(1, t / 0.18))
            let s = k * (0.85 + 0.15 * intro)
            let tr = CGAffineTransform(translationX: -img.extent.midX, y: -img.extent.midY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: W / 2, y: hookTop))
            out = withAlpha(img.transformed(by: tr), intro).composited(over: out)
        }

        // peak slam: white flash + giant word, replaces the caption for a moment
        if let age = slamAge, let s = slam {
            let flash = CGFloat(max(0, 1 - age / 0.22)) * 0.55
            if flash > 0 { out = solid(canvas, CIColor(red: 1, green: 1, blue: 1, alpha: flash)).composited(over: out) }
            let img = cached("slam") { Overlay.slam(s.word, accent: st.accent) }
            let pop = 1.35 - 0.35 * CGFloat(min(1, age / 0.16))
            let fade = CGFloat(age > 0.75 ? max(0, 1 - (age - 0.75) / 0.2) : 1)
            let tr = CGAffineTransform(translationX: -img.extent.midX, y: -img.extent.midY)
                .concatenating(CGAffineTransform(scaleX: pop * k, y: pop * k))
                .concatenating(CGAffineTransform(translationX: W / 2, y: captionCenterY + 40 * k))
            out = withAlpha(img.transformed(by: tr), fade).composited(over: out)
        } else if st.captionsOn, let (pi, ai) = activeCaption(pg, t) {
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
