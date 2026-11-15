import UIKit
import CoreImage

struct CaptionWord {
    var text: String
    var start: Double
    var end: Double
    var level: Float   // 0...1 loudness of this word
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

    static func pages(from words: [CaptionWord], maxWords: Int = 4, maxGap: Double = 0.6) -> [CaptionPage] {
        var pages: [CaptionPage] = []
        var cur: [CaptionWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            pages.append(CaptionPage(words: cur, start: f.start, end: l.end, showUntil: l.end + 0.35))
            cur = []
        }
        for w in words {
            if let f = cur.first, let l = cur.last {
                if cur.count >= maxWords || w.start - l.end > maxGap || w.end - f.start > 2.8 { flush() }
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
    static let size = CGSize(width: 1080, height: 400)

    private static func format() -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return f
    }

    private static func attributes(size: CGFloat, color: UIColor, para: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: 3)
        return [
            .font: UIFont.systemFont(ofSize: size, weight: .heavy),   // system font falls back to Devanagari etc.
            .foregroundColor: color,
            .strokeColor: UIColor.black,
            .strokeWidth: -7,
            .paragraphStyle: para,
            .shadow: shadow
        ]
    }

    private static func draw(_ attr: NSAttributedString, in canvas: CGSize) -> CIImage {
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format())
        let ui = renderer.image { _ in
            let area = CGSize(width: canvas.width - 120, height: canvas.height)
            let bound = attr.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                                          options: .usesLineFragmentOrigin, context: nil)
            let y = max(0, (area.height - bound.height) / 2)
            attr.draw(with: CGRect(x: 60, y: y, width: area.width, height: bound.height + 8),
                      options: .usesLineFragmentOrigin, context: nil)
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }

    /// Karaoke page: active word highlighted, loud words bigger and hot-coloured.
    static func image(page: CaptionPage, active: Int) -> CIImage {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 6
        let attr = NSMutableAttributedString()
        for (i, w) in page.words.enumerated() {
            var fs: CGFloat = 60 + 24 * CGFloat(w.level)
            var color = UIColor.white.withAlphaComponent(i > active ? 0.75 : 1)
            if i == active {
                color = UIColor(red: 1, green: 0.86, blue: 0.1, alpha: 1)
                fs += 10
            } else if w.level > 0.8 {
                color = UIColor(red: 1, green: 0.4, blue: 0.25, alpha: 1)
            }
            let text = w.text + (i == page.words.count - 1 ? "" : " ")
            attr.append(NSAttributedString(string: text, attributes: attributes(size: fs, color: color, para: para)))
        }
        return draw(attr, in: size)
    }

    static func hook(_ text: String) -> CIImage {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attr = NSAttributedString(string: text, attributes: attributes(size: 72, color: .white, para: para))
        return draw(attr, in: CGSize(width: 1080, height: 300))
    }
}
