import UIKit
import CoreImage

enum WatermarkPosition: String, CaseIterable, Identifiable, Codable {
    case topLeft = "↖", topRight = "↗", top = "↑", bottomLeft = "↙", bottomRight = "↘", center = "•"
    var id: String { rawValue }
}

enum WatermarkLook: String, CaseIterable, Identifiable, Codable {
    case tag = "Tag", plain = "Plain", stamp = "Stamp"
    var id: String { rawValue }
}

/// Bitmap overlays that are drawn once and cached by ReelState.
enum Overlay {

    /// "@handle" watermark. Tag = small rounded label with the accent dot, Plain = text only,
    /// Stamp = bold outlined text.
    static func watermark(text: String, logo: UIImage?, look: WatermarkLook, accent: Int, size: Double) -> CIImage {
        let k = CGFloat(size)
        let fs: CGFloat = (look == .stamp ? 44 : 34) * k
        let font = UIFont(name: "AvenirNext-Bold", size: fs) ?? UIFont.systemFont(ofSize: fs, weight: .bold)
        let accentColor = CaptionRenderer.palette[min(max(accent, 0), CaptionRenderer.palette.count - 1)]
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .kern: 0.5]
        if look == .stamp {
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -6
        }
        if look == .plain {
            let sh = NSShadow()
            sh.shadowColor = UIColor.black.withAlphaComponent(0.6)
            sh.shadowBlurRadius = 6
            attrs[.shadow] = sh
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let tb: CGRect = text.isEmpty ? CGRect.zero : str.boundingRect(with: CGSize(width: 900, height: 200),
                                                          options: .usesLineFragmentOrigin, context: nil)
        let logoH: CGFloat = logo == nil ? 0 : fs * 1.5
        let logoW: CGFloat = logo.map { logoH * $0.size.width / max($0.size.height, 1) } ?? 0
        let padX: CGFloat = look == .tag ? 22 * k : 4
        let padY: CGFloat = look == .tag ? 12 * k : 4
        let dot: CGFloat = look == .tag ? 12 * k : 0
        let gap: CGFloat = 12 * k
        var w = padX * 2 + tb.width
        if dot > 0 { w += dot + gap }
        if logoW > 0 { w += logoW + (text.isEmpty ? 0 : gap) }
        let h = max(tb.height, logoH) + padY * 2
        let size = CGSize(width: ceil(w) + 8, height: ceil(h) + 8)

        let ui = UIGraphicsImageRenderer(size: size, format: CaptionRenderer.format()).image { ctx in
            let body = CGRect(x: 4, y: 4, width: w, height: h)
            if look == .tag {
                UIColor.black.withAlphaComponent(0.5).setFill()
                UIBezierPath(roundedRect: body, cornerRadius: h / 2).fill()
            }
            var x = body.minX + padX
            if dot > 0 {
                accentColor.setFill()
                UIBezierPath(ovalIn: CGRect(x: x, y: body.midY - dot / 2, width: dot, height: dot)).fill()
                x += dot + gap
            }
            if let logo, logoW > 0 {
                logo.draw(in: CGRect(x: x, y: body.midY - logoH / 2, width: logoW, height: logoH))
                x += logoW + gap
            }
            if !text.isEmpty {
                str.draw(at: CGPoint(x: x, y: body.midY - tb.height / 2))
            }
            _ = ctx
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }

    /// The "peak slam" word: huge, accent coloured, black outline. Drawn at 1080 width.
    static func slam(_ word: String, accent: Int) -> CIImage {
        let accentColor = CaptionRenderer.palette[min(max(accent, 0), CaptionRenderer.palette.count - 1)]
        let text = Transliterator.isDevanagari(word) ? word : word.uppercased()
        var fs: CGFloat = 170
        var font = CaptionRenderer.font(for: text, size: fs, style: .pop)
        var str = NSAttributedString(string: text, attributes: [.font: font])
        while str.size().width > 960, fs > 70 {
            fs -= 10
            font = CaptionRenderer.font(for: text, size: fs, style: .pop)
            str = NSAttributedString(string: text, attributes: [.font: font])
        }
        let sh = NSShadow()
        sh.shadowColor = UIColor.black.withAlphaComponent(0.55)
        sh.shadowBlurRadius = 18
        sh.shadowOffset = CGSize(width: 0, height: 10)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: accentColor,
            .strokeColor: UIColor.black, .strokeWidth: -7, .shadow: sh
        ])
        let sz = attr.size()
        let canvas = CGSize(width: 1080, height: ceil(sz.height) + 80)
        let ui = UIGraphicsImageRenderer(size: canvas, format: CaptionRenderer.format()).image { _ in
            attr.draw(at: CGPoint(x: (canvas.width - sz.width) / 2, y: 40))
        }
        return CIImage(image: ui) ?? CIImage.empty()
    }
}
