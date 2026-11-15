import AVFoundation
import Accelerate

struct Highlight: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let score: Float
}

struct Levels {
    let norm: [Float]   // 0...1 loudness per bin
    let env: [Float]    // same, with fast attack / slow decay (used for zoom + hype meter)
}

enum AudioAnalyzer {
    static let binSeconds = 0.1
    static let sampleRate = 16000

    static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func floats(from sb: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes {
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        return data
    }

    // MARK: Full-stream analysis (streams from disk, safe for multi-hour files)

    static func loudness(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let binSize = Int(Double(sampleRate) * binSeconds)
        var bins: [Float] = []
        var sumSq: Float = 0
        var count = 0

        while let sb = output.copyNextSampleBuffer() {
            let data = floats(from: sb)
            var i = 0
            while i < data.count {
                let n = min(binSize - count, data.count - i)
                var ss: Float = 0
                data.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &ss, vDSP_Length(n)) }
                sumSq += ss
                count += n
                i += n
                if count == binSize {
                    bins.append(20 * log10(max(sqrt(sumSq / Float(binSize)), 1e-6)))
                    sumSq = 0
                    count = 0
                }
            }
        }
        return bins
    }

    // MARK: Short-clip helpers (whole clip in memory; fine for 30-90 s)

    /// 16 kHz mono float samples of an asset (works on an AVComposition, so timing matches the edited clip).
    static func samples(asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var all: [Float] = []
        while let sb = output.copyNextSampleBuffer() { all.append(contentsOf: floats(from: sb)) }
        return all
    }

    static func bins(fromSamples s: [Float]) -> [Float] {
        let binSize = Int(Double(sampleRate) * binSeconds)
        guard s.count >= binSize else { return [] }
        var out: [Float] = []
        var i = 0
        while i + binSize <= s.count {
            var ss: Float = 0
            s.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &ss, vDSP_Length(binSize)) }
            out.append(20 * log10(max(sqrt(ss / Float(binSize)), 1e-6)))
            i += binSize
        }
        return out
    }

    static func levels(bins: [Float]) -> Levels {
        guard bins.count > 10 else {
            let z = [Float](repeating: 0, count: bins.count)
            return Levels(norm: z, env: z)
        }
        let sorted = bins.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.2)]
        let hi = sorted[min(Int(Double(sorted.count) * 0.97), sorted.count - 1)]
        let range = max(hi - lo, 6)
        let norm = bins.map { min(max(($0 - lo) / range, 0), 1) }
        var env = norm
        var prev: Float = 0
        for i in 0..<env.count {
            prev = max(norm[i], prev * 0.9)
            env[i] = prev
        }
        return Levels(norm: norm, env: env)
    }

    // MARK: Highlights + silence

    static func highlights(bins: [Float], windowSeconds: Double = 45, count: Int = 12) -> [Highlight] {
        guard !bins.isEmpty else { return [] }
        let w = Int(windowSeconds / binSeconds)
        if bins.count <= w {
            return [Highlight(start: 0, end: Double(bins.count) * binSeconds, score: 0)]
        }
        let mean = bins.reduce(0, +) / Float(bins.count)
        var prefix = [Float](repeating: 0, count: bins.count + 1)
        for i in 0..<bins.count { prefix[i + 1] = prefix[i] + max(bins[i] - mean, 0) }

        let step = Int(1.0 / binSeconds)
        var cands: [(Int, Float)] = []
        var s = 0
        while s + w <= bins.count {
            cands.append((s, prefix[s + w] - prefix[s]))
            s += step
        }
        cands.sort { $0.1 > $1.1 }

        var picked: [Highlight] = []
        for (start, score) in cands {
            if picked.count >= count { break }
            let st = Double(start) * binSeconds
            let en = st + windowSeconds
            if picked.contains(where: { st < $0.end && en > $0.start }) { continue }
            picked.append(Highlight(start: st, end: en, score: score))
        }
        return picked.sorted { $0.start < $1.start }
    }

    static func keepRanges(bins: [Float], start: Double, end: Double,
                           thresholdDB: Float = -40, minSilence: Double = 1.0,
                           pad: Double = 0.15) -> [ClosedRange<Double>] {
        let a = max(Int(start / binSeconds), 0)
        let b = min(Int(end / binSeconds), bins.count)
        guard a < b else { return [start...end] }
        let minBins = Int(minSilence / binSeconds)

        var silent: [ClosedRange<Double>] = []
        var i = a
        while i < b {
            if bins[i] < thresholdDB {
                var j = i
                while j < b && bins[j] < thresholdDB { j += 1 }
                if j - i >= minBins {
                    silent.append((Double(i) * binSeconds + pad)...(Double(j) * binSeconds - pad))
                }
                i = j
            } else {
                i += 1
            }
        }

        var keep: [ClosedRange<Double>] = []
        var cur = start
        for s in silent {
            if s.lowerBound > cur { keep.append(cur...s.lowerBound) }
            cur = max(cur, s.upperBound)
        }
        if end > cur { keep.append(cur...end) }
        return keep.isEmpty ? [start...end] : keep
    }
}
