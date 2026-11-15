import AVFoundation
import ImageIO
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

struct BuiltClip {
    let comp: AVMutableComposition
    let trackID: CMPersistentTrackID
    let orientation: CGImagePropertyOrientation
}

enum Exporter {
    static let target = CGSize(width: 1080, height: 1920)

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    /// Stitches the kept ranges (silences removed) into one composition.
    static func build(url: URL, keep: [ClosedRange<Double>]) async throws -> BuiltClip {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let pt = try await vTrack.load(.preferredTransform)

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
        return BuiltClip(comp: comp, trackID: cv.trackID, orientation: orientation(for: pt))
    }

    static func render(_ built: BuiltClip, config: ReelConfig) async throws -> URL {
        let comp = built.comp
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ReelCompositor.self
        vc.renderSize = target
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [
            ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                            trackID: built.trackID, config: config)
        ]

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
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
