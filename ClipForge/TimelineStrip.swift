import SwiftUI

struct TimelineSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(clock(model.start)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text("\(Int(model.end - model.start)) s clip")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.14), in: Capsule())
                Spacer()
                Text(clock(model.end)).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 6)

            HStack(spacing: 8) {
                TimelineStrip(model: model).frame(height: 62)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        tool("chevron.left") { model.shiftDetail(-0.5) }
                        tool("chevron.right") { model.shiftDetail(0.5) }
                    }
                    HStack(spacing: 6) {
                        tool("minus.magnifyingglass") { model.zoomDetail(2) }
                        tool("plus.magnifyingglass") { model.zoomDetail(0.5) }
                    }
                }
            }
        }
        .padding(10)
        .glass(26)
    }

    private func tool(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct TimelineStrip: View {
    @Bindable var model: EditorModel
    @State private var dragging: Int? = nil   // 0 = start handle, 1 = end handle

    var body: some View {
        let wave = model.wave
        let r = model.detail
        let span = max(r.upperBound - r.lowerBound, 1)
        let s = model.start, e = model.end

        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let xs = CGFloat((s - r.lowerBound) / span) * w
            let xe = CGFloat((e - r.lowerBound) / span) * w

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let barW: CGFloat = 3, gap: CGFloat = 1.5
                    let n = max(1, Int(size.width / (barW + gap)))
                    for i in 0..<n {
                        let t0 = r.lowerBound + span * Double(i) / Double(n)
                        let t1 = r.lowerBound + span * Double(i + 1) / Double(n)
                        let a = max(0, Int(t0 / AudioAnalyzer.binSeconds))
                        let b = max(a, Int(t1 / AudioAnalyzer.binSeconds))
                        var v: Float = 0
                        if a < wave.count {
                            for k in a...min(b, wave.count - 1) { v = max(v, wave[k]) }
                        }
                        let bh = max(3, CGFloat(v) * size.height * 0.92)
                        let x = CGFloat(i) * (barW + gap)
                        let mid = (t0 + t1) / 2
                        let inside = mid >= s && mid <= e
                        let rect = CGRect(x: x, y: (size.height - bh) / 2, width: barW, height: bh)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(inside ? Theme.accent : Color.white.opacity(0.28)))
                    }
                }

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.9), lineWidth: 2)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(width: max(xe - xs, 4), height: h)
                    .offset(x: xs)
                    .allowsHitTesting(false)

                Capsule().fill(.white).frame(width: 6, height: h - 14)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: xs - 3, y: 7).allowsHitTesting(false)
                Capsule().fill(.white).frame(width: 6, height: h - 14)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: xe - 3, y: 7).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = r.lowerBound + Double(v.location.x / w) * span
                        if dragging == nil {
                            dragging = abs(v.startLocation.x - xs) < abs(v.startLocation.x - xe) ? 0 : 1
                        }
                        if dragging == 0 {
                            model.setTrim(min(max(t, r.lowerBound), model.end - 1), model.end)
                        } else {
                            model.setTrim(model.start, min(max(t, model.start + 1), r.upperBound))
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }
}
