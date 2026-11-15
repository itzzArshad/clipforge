import AVFoundation

extension AudioAnalyzer {
    /// 16 kHz mono float samples for just one time range of a (possibly huge) file.
    static func samples(asset: AVAsset, range: ClosedRange<Double>) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var all: [Float] = []
        while let sb = output.copyNextSampleBuffer() { all.append(contentsOf: floats(from: sb)) }
        return all
    }
}
