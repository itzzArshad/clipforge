import SwiftUI
import AVFoundation
import Vision

/// Finds a streamer's webcam overlay: a face that shows up in roughly the same small spot
/// across many frames of the stream. Returns a rect normalised to the frame, top-left origin.
enum FacecamDetector {
    static func detect(url: URL, duration: Double) async -> CGRect? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let samples = 10
        var boxes: [CGRect] = []          // face boxes, top-left origin
        for i in 0..<samples {
            let t = duration * (Double(i) + 0.5) / Double(samples)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            for f in req.results ?? [] {
                let b = f.boundingBox   // bottom-left origin
                // a webcam face is small relative to the frame; a full-screen face is not a facecam
                guard b.width < 0.22, b.height < 0.4 else { continue }
                boxes.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
        }
        guard boxes.count >= 3 else { return nil }

        // cluster by centre; keep the biggest cluster
        var best: [CGRect] = []
        for b in boxes {
            let c = CGPoint(x: b.midX, y: b.midY)
            let group = boxes.filter { hypot($0.midX - c.x, $0.midY - c.y) < 0.08 }
            if group.count > best.count { best = group }
        }
        guard best.count >= max(3, samples / 3) else { return nil }

        let cx = best.map(\.midX).reduce(0, +) / CGFloat(best.count)
        let cy = best.map(\.midY).reduce(0, +) / CGFloat(best.count)
        let fw = best.map(\.width).reduce(0, +) / CGFloat(best.count)
        let fh = best.map(\.height).reduce(0, +) / CGFloat(best.count)
        // grow the face box to roughly the webcam frame (head + shoulders)
        var r = CGRect(x: cx - fw * 1.6, y: cy - fh * 1.3, width: fw * 3.2, height: fh * 3.0)
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull || r.width < 0.05 ? nil : r
    }

    static func frame(url: URL, at t: Double) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Drag the box to move it, drag the corner to resize. Coordinates are normalised, top-left origin.
struct FacecamEditor: View {
    let image: UIImage
    @State var rect: CGRect
    let onSave: (CGRect?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart: CGRect?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Box the streamer's webcam. It goes on top of the reel, the gameplay below.")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    let fit = fitRect(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: fit.width, height: fit.height)
                            .offset(x: fit.minX, y: fit.minY)
                        let box = CGRect(x: fit.minX + rect.minX * fit.width, y: fit.minY + rect.minY * fit.height,
                                         width: rect.width * fit.width, height: rect.height * fit.height)
                        Rectangle()
                            .stroke(Theme.accent, lineWidth: 2.5)
                            .background(Theme.accent.opacity(0.12))
                            .frame(width: box.width, height: box.height)
                            .offset(x: box.minX, y: box.minY)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if dragStart == nil { dragStart = rect }
                                    guard let s = dragStart else { return }
                                    var r = s
                                    r.origin.x = min(max(0, s.minX + v.translation.width / fit.width), 1 - s.width)
                                    r.origin.y = min(max(0, s.minY + v.translation.height / fit.height), 1 - s.height)
                                    rect = r
                                }
                                .onEnded { _ in dragStart = nil })
                        Circle().fill(Theme.accent).frame(width: 26, height: 26)
                            .offset(x: box.maxX - 13, y: box.maxY - 13)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if dragStart == nil { dragStart = rect }
                                    guard let s = dragStart else { return }
                                    var r = s
                                    r.size.width = min(max(0.06, s.width + v.translation.width / fit.width), 1 - s.minX)
                                    r.size.height = min(max(0.06, s.height + v.translation.height / fit.height), 1 - s.minY)
                                    rect = r
                                }
                                .onEnded { _ in dragStart = nil })
                    }
                }
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)

                Button(role: .destructive) { onSave(nil); dismiss() } label: {
                    Text("No facecam in this video").font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Facecam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Use box") { onSave(rect); dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func fitRect(_ img: CGSize, in box: CGSize) -> CGRect {
        guard img.width > 0, img.height > 0 else { return .zero }
        let s = min(box.width / img.width, box.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}
