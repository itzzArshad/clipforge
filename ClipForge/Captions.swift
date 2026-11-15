import UIKit
import CoreImage

struct CaptionWord {
    var text: String
    var start: Double
    var end: Double
    var level: Float
    var strong = false          // one of the clip's punch words
}

struct CaptionPage {
    var words: [CaptionWord]
    var start: Double
    var end: Double
    var showUntil: Double
}

/// Caption looks. Bounce / Hype / Clean follow PeakCut's render.py styles (MIT); Pill is ClipForge's own.
enum CaptionStyleKind: String, CaseIterable, Identifiable {
    case bounce = "Bounce", hype = "Hype", clean = "Clean", pill = "Pill"
    var id: String { rawValue }

    struct Spec {
        let font: String
        let size: CGFloat         // points at 1080 wide
        let upper: Bool
        let perPage: Int
        let outline: CGFloat      // px around each letter
        let pop: CGFloat          // % the spoken word grows to
        let strong: UIColor       // colour of the clip's punch words
    }

    var spec: Spec {
        switch self {
        case .bounce: return Spec(font: "Poppins-ExtraBold", size: 94, upper: true, perPage: 3, outline: 7, pop: 112, strong: .white)
        case .hype: return Spec(font: "Anton-Regular", size: 104, upper: true, perPage: 2, outline: 7, pop: 114,
                                strong: UIColor(red: 1, green: 0.84, blue: 0, alpha: 1))
        case .clean: return Spec(font: "Poppins-ExtraBold", size: 72, upper: false, perPage: 4, outline: 5, pop: 106, strong: .white)
        case .pill: return Spec(font: "Poppins-ExtraBold", size: 74, upper: false, perPage: 3, outline: 0, pop: 104,
                                strong: UIColor(red: 1, green: 0.84, blue: 0, alpha: 1))
        }
    }
}

enum CaptionBuilder {
    static func words(from raw: [RawWord], norm: [Float], highlights: [String] = []) -> [CaptionWord] {
        let strong = Set(highlights.map(key).filter { !$0.isEmpty })
        var out: [CaptionWord] = []
        for (i, r) in raw.enumerated() {
            let s = r.start
            let nextStart = i + 1 < raw.count ? raw[i + 1].start : Double.greatestFiniteMagnitude
            let e = max(s, min(max(r.end, s + 0.15), max(nextStart, s + 0.15)))
            var lv: Float = 0
            if !norm.isEmpty {
                let lower = min(max(Int(s / AudioAnalyzer.binSeconds), 0), norm.count - 1)
                let upper = min(max(Int(e / AudioAnalyzer.binSeconds), lower), norm.count - 1)
                for k in lower...upper { lv = max(lv, norm[k]) }
            }
            out.append(CaptionWord(text: r.text, start: s, end: e, level: lv, strong: strong.contains(key(r.text))))
        }
        return out
    }

    static func key(_ w: String) -> String {
        w.lowercased().filter { ($0.isLetter || $0.isNumber || $0 == "'") }
    }

    /// Short pages that read fast: at most `per` words and 16 letters, broken at pauses and sentence ends.
    static func pages(from words: [CaptionWord], per: Int = 3) -> [CaptionPage] {
        var groups: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        for w in words where !w.text.isEmpty {
            if let l = cur.last {
                let letters = cur.reduce(0) { $0 + $1.text.count } + w.text.count
                let sentenceEnd = l.text.last.map { ".?!।".contains($0) } ?? false
                if cur.count >= per || letters > 16 || w.start - l.end > 0.45 || sentenceEnd {
                    groups.append(cur); cur = []
                }
            }
            cur.append(w)
        }
        if !cur.isEmpty { groups.append(cur) }
        var pages: [CaptionPage] = []
        for (gi, g) in groups.enumerated() {
            let next = gi + 1 < groups.count ? groups[gi + 1][0].start : Double.greatestFiniteMagnitude
            let until = min(g[g.count - 1].end + 0.25, next)
            pages.append(CaptionPage(words: g, start: g[0].start, end: g[g.count - 1].end, showUntil: until))
        }
        return pages
    }
}

enum CaptionRenderer {
    static let size = CGSize(width: 1080, height: 420)
    static let maxWidth: CGFloat = 960

    /// Colour of the word being spoken. Index is stored in ReelStyle.accent.
    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.94, blue: 0.00, alpha: 1),   // yellow (PeakCut Bounce)
        UIColor(red: 1.00, green: 0.24, blue: 0.24, alpha: 1),   // red (PeakCut Hype)
        UIColor(red: 0.84, green: 1.00, blue: 0.25, alpha: 1),   // signal lime (ClipForge)
        UIColor(red: 0.00, green: 0.94, blue: 1.00, alpha: 1),   // cyan
        UIColor(red: 1.00, green: 0.30, blue: 0.60, alpha: 1)    // pink
    ]
    static let hot = UIColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1)

    static func format() -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return f
    }

    /// The style's font for Latin text (Hinglish and English). Other scripts fall back to a bold font for that
    /// script, since the caption fonts only draw Latin letters.
    static func font(for text: String, size: CGFloat, style: CaptionStyleKind) -> UIFont {
        let v = text.unicodeScalars.first(where: { $0.value > 0x24F && CharacterSet.letters.contains($0) })?.value ?? 0
        var names: [String]
        var scale: CGFloat = 1
        switch v {
        case 0:
            names = [style.spec.font, "AvenirNext-Heavy"]
        case 0x900...0x97F: names = ["KohinoorDevanagari-Semibold", "DevanagariSangamMN-Bold"]; scale = 0.9
        case 0xC00...0xC7F: names = ["KohinoorTelugu-Medium", "TeluguSangamMN-Bold"]; scale = 0.9
        case 0xB80...0xBFF: names = ["TamilSangamMN-Bold"]; scale = 0.85
        case 0xC80...0xCFF: names = ["KannadaSangamMN-Bold"]; scale = 0.9
        case 0xD00...0xD7F: names = ["MalayalamSangamMN-Bold"]; scale = 0.85
        case 0x980...0x9FF: names = ["KohinoorBangla-Semibold", "BanglaSangamMN-Bold"]; scale = 0.9
        case 0xA80...0xAFF: names = ["GujaratiSangamMN-Bold"]; scale = 0.9
        case 0xA00...0xA7F: names = ["GurmukhiSangamMN-Bold"]; scale = 0.9
        case 0x600...0x6FF: names = ["GeezaPro-Bold"]; scale = 0.9
        default: names = []
        }
        for n in names { if let f = UIFont(name: n, size: size * scale) { return f } }
        return UIFont.systemFont(ofSize: size * scale, weight: .heavy)
    }

    private static func display(_ t: String, _ style: CaptionStyleKind) -> String {
        var s = t.replacingOccurrences(of: #"[.,;:]+$"#, with: "", options: .regularExpression)
        if style.spec.upper && !Transliterator.needsRoman(s) { s = s.uppercased() }
        return s
    }

    /// One caption page with the spoken word highlighted and grown. Every word is measured and placed by hand
    /// (as PeakCut does), so the spoken word can grow without pushing its neighbours, and a long page shrinks
    /// to fit instead of running off the frame.
    static func image(page: CaptionPage, active: Int, style: CaptionStyleKind, accent: Int) -> CIImage {
        let spec = style.spec
        let activeColor = palette[min(max(accent, 0), palette.count - 1)]
        let texts = page.words.map { display($0.text, style) }
        func fontFor(_ t: String, _ s: CGFloat) -> UIFont { font(for: t, size: s, style: style) }
        func width(_ t: String, _ s: CGFloat) -> CGFloat {
            (t as NSString).size(withAttributes: [.font: fontFor(t, s)]).width
        }
        func gapAt(_ s: CGFloat) -> CGFloat {
            width("n n", s) - 2 * width("n", s) + (2 * spec.outline + 6) * s / spec.size + (style == .pill ? 22 : 0)
        }
        func totalAt(_ s: CGFloat) -> CGFloat {
            texts.reduce(0) { $0 + width($1, s) } + gapAt(s) * CGFloat(max(0, texts.count - 1))
        }
        var size = spec.size
        var total = totalAt(size)
        if total > maxWidth {
            size = max(36, size * maxWidth / total)
            total = totalAt(size)
        }
        let gap = gapAt(size)

        let ui = UIGraphicsImageRenderer(size: Self.size, format: format()).image { ctx in
            let cg = ctx.cgContext
            var x = (Self.size.width - total) / 2
            let cy = Self.size.height / 2
            if style == .clean {
                // soft box behind the whole line
                let h = fontFor(texts.first ?? "A", size).lineHeight
                let box = CGRect(x: x - 34, y: cy - h / 2 - 18, width: total + 68, height: h + 36)
                UIColor.black.withAlphaComponent(0.5).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 30).fill()
            }
            for i in 0..<texts.count {
                let w = page.words[i], t = texts[i]
                let f = fontFor(t, size)
                let wd = width(t, size)
                let center = CGPoint(x: x + wd / 2, y: cy)
                x += wd + gap
                let isActive = i == active
                // long words grow less, so they never touch their neighbours
                let p: CGFloat = isActive ? max(104, min(spec.pop, 100 + 2200 / max(wd, 1))) / 100 : 1
                var fill: UIColor = w.strong ? spec.strong : .white
                if isActive {
                    if style == .pill { fill = .black } else { fill = (w.level > 0.85 && style != .clean) ? hot : activeColor }
                } else if style == .clean && i > active {
                    fill = UIColor.white.withAlphaComponent(0.7)
                }

                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.scaleBy(x: p, y: p)
                let textSize = (t as NSString).size(withAttributes: [.font: f])
                let origin = CGPoint(x: -textSize.width / 2, y: -textSize.height / 2)

                if style == .pill && isActive {
                    let r = CGRect(origin: origin, size: textSize).insetBy(dx: -16, dy: -2)
                    cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                    (w.level > 0.85 ? hot : activeColor).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: 22).fill()
                    cg.setShadow(offset: .zero, blur: 0, color: nil)
                }
                if spec.outline > 0 {
                    // outline first (stroke only, twice the width so the outside half shows), then the fill on top
                    let strokePct = 2 * spec.outline * (size / spec.size) / f.pointSize * 100
                    (t as NSString).draw(at: origin, withAttributes: [
                        .font: f, .strokeColor: UIColor.black, .strokeWidth: strokePct
                    ])
                } else if style == .pill && !isActive {
                    cg.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: UIColor.black.withAlphaComponent(0.55).cgColor)
                }
                (t as NSString).draw(at: origin, withAttributes: [.font: f, .foregroundColor: fill])
                cg.restoreGState()
            }
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }

    /// The hook: dark text in a white rounded box that fits it, on one line or two balanced ones (PeakCut's look).
    static func hook(_ text: String, accent: Int) -> CIImage {
        let ink = UIColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        var size: CGFloat = 69
        let maxW: CGFloat = 900, padX: CGFloat = 36, padY: CGFloat = 22
        func f(_ s: CGFloat) -> UIFont { font(for: text, size: s, style: .bounce) }
        func w(_ t: String, _ s: CGFloat) -> CGFloat { (t as NSString).size(withAttributes: [.font: f(s)]).width }
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return CIImage.empty() }
        func join(_ a: ArraySlice<String>) -> String { a.joined(separator: " ") }
        var lines = [join(parts[...])]
        if w(lines[0], size) > maxW, parts.count > 1 {
            var best = 1
            var bestW = CGFloat.greatestFiniteMagnitude
            for cut in 1..<parts.count {
                let m = max(w(join(parts[..<cut]), size), w(join(parts[cut...]), size))
                if m < bestW { bestW = m; best = cut }
            }
            lines = [join(parts[..<best]), join(parts[best...])]
        }
        var widest = lines.map { w($0, size) }.max() ?? 0
        if widest > maxW { size = max(30, size * maxW / widest); widest = lines.map { w($0, size) }.max() ?? 0 }
        let lineH = f(size).lineHeight * 1.02
        let box = CGSize(width: widest + 2 * padX, height: lineH * CGFloat(lines.count) + 2 * padY)
        let canvas = CGSize(width: 1080, height: ceil(box.height) + 40)
        let ui = UIGraphicsImageRenderer(size: canvas, format: format()).image { _ in
            let r = CGRect(x: (canvas.width - box.width) / 2, y: 20, width: box.width, height: box.height)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: r, cornerRadius: min(26, box.height / 2)).fill()
            for (i, l) in lines.enumerated() {
                let lw = w(l, size)
                (l as NSString).draw(at: CGPoint(x: (canvas.width - lw) / 2, y: r.minY + padY + CGFloat(i) * lineH),
                                     withAttributes: [.font: f(size), .foregroundColor: ink])
            }
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }
}
