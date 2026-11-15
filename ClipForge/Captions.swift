import UIKit
import CoreImage

struct CaptionWord {
    var text: String
    var start: Double
    var end: Double
    var level: Float
}

struct CaptionPage {
    var words: [CaptionWord]
    var start: Double
    var end: Double
    var showUntil: Double
}

enum CaptionBuilder {
    static func words(from raw: [RawWord], norm: [Float]) -> [CaptionWord] {
        var out: [CaptionWord] = []
        for (i, r) in raw.enumerated() {
            let s = r.start
            let nextStart = i + 1 < raw.count ? raw[i + 1].start : Double.greatestFiniteMagnitude
            let e = min(max(r.end, s + 0.15), max(nextStart, s + 0.15))
            var lv: Float = 0
            if !norm.isEmpty {
                let lower = min(max(Int(s / AudioAnalyzer.binSeconds), 0), norm.count - 1)
                let upper = min(max(Int(e / AudioAnalyzer.binSeconds), lower), norm.count - 1)
                for k in lower...upper { lv = max(lv, norm[k]) }
            }
            out.append(CaptionWord(text: r.text, start: s, end: e, level: lv))
        }
        return out
    }

    static func pages(from words: [CaptionWord], maxWords: Int = 3, maxGap: Double = 0.6) -> [CaptionPage] {
        var pages: [CaptionPage] = []
        var cur: [CaptionWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            pages.append(CaptionPage(words: cur, start: f.start, end: l.end, showUntil: l.end + 0.35))
            cur = []
        }
        for w in words {
            if let f = cur.first, let l = cur.last {
                if cur.count >= maxWords || w.start - l.end > maxGap || w.end - f.start > 2.4 { flush() }
            }
            cur.append(w)
        }
        flush()
        for i in 0..<pages.count where i + 1 < pages.count {
            pages[i].showUntil = min(pages[i].showUntil, pages[i + 1].start)
        }
        return pages
    }
}

enum CaptionRenderer {
    static let size = CGSize(width: 1080, height: 420)
    static let hookSize = CGSize(width: 1080, height: 300)

    /// Accent palette. Index is stored in ReelStyle.accent.
    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.85, blue: 0.10, alpha: 1),   // yellow
        UIColor(red: 1.00, green: 0.30, blue: 0.60, alpha: 1),   // pink
        UIColor(red: 0.20, green: 0.90, blue: 1.00, alpha: 1),   // cyan
        UIColor(red: 0.40, green: 1.00, blue: 0.50, alpha: 1),   // green
        UIColor(red: 1.00, green: 0.55, blue: 0.15, alpha: 1)    // orange
    ]
    static let hot = UIColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1)

    private static func format() -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return f
    }

    /// Picks a proper bold font per script. Falls back to the system heavy font (which cascades to Indic fonts).
    static func font(for text: String, size: CGFloat, style: CaptionStyleKind) -> UIFont {
        let v = text.unicodeScalars.first(where: { $0.value > 0x7F && CharacterSet.letters.contains($0) })?.value ?? 0
        var names: [String]
        var scale: CGFloat = 1
        switch v {
        case 0x900...0x97F: names = ["KohinoorDevanagari-Semibold", "DevanagariSangamMN-Bold"]; scale = 1.05
        case 0xC00...0xC7F: names = ["KohinoorTelugu-Medium", "TeluguSangamMN-Bold"]
        case 0xB80...0xBFF: names = ["TamilSangamMN-Bold"]
        case 0xC80...0xCFF: names = ["KannadaSangamMN-Bold"]
        case 0xD00...0xD7F: names = ["MalayalamSangamMN-Bold"]
        case 0x980...0x9FF: names = ["KohinoorBangla-Semibold", "BanglaSangamMN-Bold"]
        case 0xA80...0xAFF: names = ["GujaratiSangamMN-Bold"]
        case 0xA00...0xA7F: names = ["GurmukhiSangamMN-Bold"]
        case 0x600...0x6FF: names = ["GeezaPro-Bold"]
        default:
            names = style == .pop ? ["HelveticaNeue-CondensedBlack", "AvenirNext-Heavy"] : ["AvenirNext-Heavy"]
            if style == .pop { scale = 1.15 }
        }
        for n in names { if let f = UIFont(name: n, size: size * scale) { return f } }
        return UIFont.systemFont(ofSize: size, weight: .heavy)
    }

    private static func isLatin(_ s: String) -> Bool {
        !s.unicodeScalars.contains { $0.value > 0x7F && CharacterSet.letters.contains($0) }
    }

    /// One caption page, with the active word highlighted. Three looks:
    ///  - pill: white text, the spoken word sits on a coloured rounded pill (turns red when shouted)
    ///  - pop: condensed caps, thin outline, spoken word in the accent colour
    ///  - clean: soft dark rounded box, white text, spoken word full white and the rest dimmed
    static func image(page: CaptionPage, active: Int, style: CaptionStyleKind, accent: Int) -> CIImage {
        let accentColor = palette[min(max(accent, 0), palette.count - 1)]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = style == .pill ? 18 : 8

        let attr = NSMutableAttributedString()
        var ranges: [NSRange] = []
        let baseSize: CGFloat = style == .pill ? 62 : (style == .pop ? 66 : 56)

        for (i, w) in page.words.enumerated() {
            let isActive = i == active
            let shout = w.level > 0.8
            var text = w.text
            if style == .pop && isLatin(text) { text = text.uppercased() }
            let fs = baseSize + 16 * CGFloat(w.level) + (isActive ? 6 : 0)

            var color = UIColor.white
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para]
            switch style {
            case .pill:
                color = isActive ? (shout ? .white : .black) : .white
                let sh = NSShadow()
                sh.shadowColor = UIColor.black.withAlphaComponent(0.45)
                sh.shadowBlurRadius = 8
                sh.shadowOffset = CGSize(width: 0, height: 4)
                if !isActive { attrs[.shadow] = sh }
            case .pop:
                color = isActive ? (shout ? hot : accentColor) : .white
                attrs[.strokeColor] = UIColor.black
                attrs[.strokeWidth] = -8
                let sh = NSShadow()
                sh.shadowColor = UIColor.black.withAlphaComponent(0.5)
                sh.shadowBlurRadius = 6
                sh.shadowOffset = CGSize(width: 0, height: 4)
                attrs[.shadow] = sh
            case .clean:
                color = UIColor.white.withAlphaComponent(isActive ? 1 : 0.65)
            }
            attrs[.font] = font(for: text, size: fs, style: style)
            attrs[.foregroundColor] = color

            let loc = attr.length
            attr.append(NSAttributedString(string: text, attributes: attrs))
            ranges.append(NSRange(location: loc, length: (text as NSString).length))
            if i < page.words.count - 1 { attr.append(NSAttributedString(string: " ", attributes: attrs)) }
        }

        let area = CGRect(x: 80, y: 0, width: size.width - 160, height: size.height)
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: area.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let origin = CGPoint(x: area.minX, y: max(0, (size.height - used.height) / 2))

        let renderer = UIGraphicsImageRenderer(size: size, format: format())
        let ui = renderer.image { ctx in
            if style == .clean {
                let box = used.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -38, dy: -24)
                UIColor.black.withAlphaComponent(0.55).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 40).fill()
            }
            if style == .pill, active < ranges.count {
                let gr = layout.glyphRange(forCharacterRange: ranges[active], actualCharacterRange: nil)
                var r = layout.boundingRect(forGlyphRange: gr, in: container)
                r = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -18, dy: -4)
                let w = page.words[active]
                (w.level > 0.8 ? hot : accentColor).setFill()
                ctx.cgContext.saveGState()
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 6), blur: 14,
                                        color: UIColor.black.withAlphaComponent(0.35).cgColor)
                UIBezierPath(roundedRect: r, cornerRadius: 24).fill()
                ctx.cgContext.restoreGState()
            }
            layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }

    /// Sticker-style hook title: accent-coloured rounded label with bold black text.
    static func hook(_ text: String, accent: Int) -> CIImage {
        let accentColor = palette[min(max(accent, 0), palette.count - 1)]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attr = NSAttributedString(string: text, attributes: [
            .font: font(for: text, size: 56, style: .pill),
            .foregroundColor: UIColor.black,
            .paragraphStyle: para
        ])
        let bound = attr.boundingRect(with: CGSize(width: 820, height: CGFloat.greatestFiniteMagnitude),
                                      options: .usesLineFragmentOrigin, context: nil)
        let pill = CGRect(x: (hookSize.width - (bound.width + 80)) / 2,
                          y: (hookSize.height - (bound.height + 50)) / 2,
                          width: bound.width + 80, height: bound.height + 50)
        let renderer = UIGraphicsImageRenderer(size: hookSize, format: format())
        let ui = renderer.image { ctx in
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 8), blur: 18,
                                    color: UIColor.black.withAlphaComponent(0.4).cgColor)
            accentColor.setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 30).fill()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            attr.draw(with: CGRect(x: pill.minX + 40, y: pill.minY + 25, width: bound.width + 2, height: bound.height + 4),
                      options: .usesLineFragmentOrigin, context: nil)
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }
}
