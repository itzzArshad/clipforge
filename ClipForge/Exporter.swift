import AVFoundation
import Photos

enum ExportError: LocalizedError {
    case noVideo, failed, noPhotoAccess
    var errorDescription: String? {
        switch self {
        case .noVideo: return "No video track found"
        case .failed: return "Export failed"
        case .noPhotoAccess: return "Photos access denied"
        }
    }
}

enum Exporter {
    static let target = CGSize(width: 1080, height: 1920)

    /// Stitches the `keep` ranges together and renders 9:16. panX: 0 = left edge, 1 = right edge.
    static func export(url: URL, keep: [ClosedRange<Double>], panX: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed
        }
        let ca = aTrack != nil
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        for r in keep {
            let range = CMTimeRange(
                start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                duration: CMTime(seconds: r.upperBound - r.lowerBound, preferredTimescale: 600))
            try cv.insertTimeRange(range, of: vTrack, at: cursor)
            if let aTrack, let ca { try ca.insertTimeRange(range, of: aTrack, at: cursor) }
            cursor = cursor + range.duration
        }

        // Orientation + "fill" crop to 9:16
        let natural = try await vTrack.load(.naturalSize)
        let pt = try await vTrack.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(pt)
        let w = abs(rect.width), h = abs(rect.height)
        let scale = max(target.width / w, target.height / h)
        let ox = -(w * scale - target.width) * panX
        let oy = -(h * scale - target.height) / 2
        let transform = pt
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: ox, y: oy))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let vc = AVMutableVideoComposition()
        vc.renderSize = target
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instruction]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed
        }
        session.videoComposition = vc
        session.outputURL = out
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else { throw session.error ?? ExportError.failed }
        return out
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.noPhotoAccess }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
