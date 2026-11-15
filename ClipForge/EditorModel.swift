import SwiftUI
import AVFoundation
import Observation
import UIKit

enum MomentSource: String, CaseIterable, Identifiable {
    case loud = "Loud", speech = "Speech", best = "Best"
    var id: String { rawValue }
}

enum EditorTab: String, CaseIterable, Identifiable {
    case moments, layout, captions, effects
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .moments: return "sparkles.rectangle.stack"
        case .layout: return "rectangle.portrait.on.rectangle.portrait"
        case .captions: return "captions.bubble"
        case .effects: return "wand.and.stars"
        }
    }
}

struct Lang: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

let languages: [Lang] = [
    Lang(code: "hi", name: "Hindi"), Lang(code: "en", name: "English"),
    Lang(code: "te", name: "Telugu"), Lang(code: "ta", name: "Tamil"),
    Lang(code: "kn", name: "Kannada"), Lang(code: "ml", name: "Malayalam"),
    Lang(code: "mr", name: "Marathi"), Lang(code: "bn", name: "Bengali"),
    Lang(code: "gu", name: "Gujarati"), Lang(code: "pa", name: "Punjabi"),
    Lang(code: "ur", name: "Urdu")
]

@MainActor @Observable
final class EditorModel {
    // source video
    var videoURL: URL?
    var duration = 0.0
    var wave: [Float] = []
    var hasVideo: Bool { videoURL != nil }

    // moments
    var moments: [Moment] = []
    var source: MomentSource = .loud
    var selectedID: UUID?

    // trim
    var start = 0.0
    var end = 30.0
    var detail: ClosedRange<Double> = 0...60
    var removeSilence = true

    // style + captions
    var style = ReelStyle()
    var language = "hi"
    var accurateModel = false
    var sourceWords: [RawWord] = []
    var covered: [ClosedRange<Double>] = []

    // status
    var busyText: String?
    var progress: Double?
    var analyzing = false
    var toast: String?
    var playhead = 0.0
    var clipDuration = 0.0
    var isPlaying = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored var state = ReelState(orientation: .up)
    @ObservationIgnored var bins: [Float] = []
    @ObservationIgnored var built: BuiltClip?
    @ObservationIgnored let transcriber = Transcriber()
    @ObservationIgnored var rebuildTask: Task<Void, Never>?
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var loopObserver: NSObjectProtocol?

    init() {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                       queue: .main) { [weak self] t in
            Task { @MainActor in self?.playhead = t.seconds }
        }
    }

    // MARK: derived

    var modelName: String { accurateModel ? "large-v3-v20240930_626MB" : "small" }
    var languageName: String { languages.first { $0.code == language }?.name ?? "Hindi" }
    var captionsReady: Bool { isCovered(start...end) }

    var visibleMoments: [Moment] {
        switch source {
        case .loud: return moments.sorted { $0.loud > $1.loud }
        case .speech: return moments.filter { $0.text != nil }.sorted { ($0.text ?? 0) > ($1.text ?? 0) }
        case .best: return moments.sorted { $0.combined > $1.combined }
        }
    }

    func bind<T>(_ kp: WritableKeyPath<ReelStyle, T>) -> Binding<T> {
        Binding(get: { self.style[keyPath: kp] },
                set: { self.style[keyPath: kp] = $0; self.styleChanged() })
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: import

    func importVideo(_ url: URL) async {
        busyText = "Reading audio…"
        progress = nil
        defer { busyText = nil }
        do {
            let asset = AVURLAsset(url: url)
            duration = try await asset.load(.duration).seconds
            if let vt = try await asset.loadTracks(withMediaType: .video).first {
                let pt = try await vt.load(.preferredTransform)
                state = ReelState(orientation: Exporter.orientation(for: pt))
            }
            videoURL = url
            bins = try await AudioAnalyzer.loudness(url: url)
            wave = AudioAnalyzer.levels(bins: bins).norm
            sourceWords = []
            covered = []
            let hs = AudioAnalyzer.highlights(bins: bins, windowSeconds: 45, count: 16)
            let top = max(hs.map(\.score).max() ?? 1, 1)
            moments = hs.map { Moment(start: $0.start, end: $0.end, loud: $0.score / top) }
            state.style = style
            source = .loud
            if let first = moments.first {
                select(first)
            } else {
                setTrim(0, min(45, duration), resetDetail: true)
            }
            await rebuildPreview()
        } catch {
            show("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: selection + trim

    func select(_ m: Moment) {
        selectedID = m.id
        if !m.hook.isEmpty { style.hook = m.hook; state.style = style }
        setTrim(m.start, m.end, resetDetail: true)
    }

    func setTrim(_ s: Double, _ e: Double, resetDetail: Bool = false) {
        start = max(0, s)
        end = min(duration, max(e, start + 1))
        if resetDetail {
            let pad = max(15, (end - start) * 0.5)
            detail = max(0, start - pad)...min(duration, end + pad)
        }
        scheduleRebuild()
    }

    func shiftDetail(_ frac: Double) {
        let span = detail.upperBound - detail.lowerBound
        var lo = detail.lowerBound + span * frac
        lo = min(max(0, lo), max(0, duration - span))
        detail = lo...(lo + span)
    }

    func zoomDetail(_ factor: Double) {
        let span = detail.upperBound - detail.lowerBound
        let mid = (detail.lowerBound + detail.upperBound) / 2
        let newSpan = min(max(span * factor, 10), max(duration, 10))
        var lo = max(0, mid - newSpan / 2)
        var hi = min(duration, lo + newSpan)
        lo = max(0, hi - newSpan)
        lo = min(lo, start - 1)
        hi = max(hi, end + 1)
        detail = max(0, lo)...min(duration, hi)
    }

    func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await self?.rebuildPreview()
        }
    }

    // MARK: preview

    func makeBuilt() async throws -> BuiltClip {
        guard let url = videoURL else { throw ExportError.noVideo }
        let keep = removeSilence ? AudioAnalyzer.keepRanges(bins: bins, start: start, end: end) : [start...end]
        let b = try await Exporter.build(url: url, keep: keep)
        let samples = try await AudioAnalyzer.samples(asset: b.comp)
        state.levels = AudioAnalyzer.levels(bins: AudioAnalyzer.bins(fromSamples: samples))
        refreshPages(for: b)
        return b
    }

    func rebuildPreview() async {
        guard videoURL != nil else { return }
        do {
            let b = try await makeBuilt()
            if Task.isCancelled { return }
            built = b
            clipDuration = b.comp.duration.seconds
            let item = AVPlayerItem(asset: b.comp)
            item.videoComposition = Exporter.videoComposition(for: b, state: state, size: Exporter.previewSize)
            if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.player.seek(to: .zero)
                    self?.player.play()
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
            isPlaying = true
        } catch {
            show("Preview failed: \(error.localizedDescription)")
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func styleChanged() {
        state.style = style
        refreshFrame()
    }

    func refreshFrame() {
        if !isPlaying {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: captions

    private func isCovered(_ r: ClosedRange<Double>) -> Bool {
        covered.contains { $0.lowerBound <= r.lowerBound + 0.5 && $0.upperBound >= r.upperBound - 0.5 }
    }

    private func mapWords(_ words: [RawWord], keep: [ClosedRange<Double>]) -> [RawWord] {
        var table: [(src: ClosedRange<Double>, base: Double)] = []
        var cum = 0.0
        for r in keep { table.append((r, cum)); cum += r.upperBound - r.lowerBound }
        var out: [RawWord] = []
        for w in words {
            let mid = (w.start + w.end) / 2
            guard let e = table.first(where: { $0.src.contains(mid) }) else { continue }
            let s = max(w.start, e.src.lowerBound) - e.src.lowerBound + e.base
            let en = min(w.end, e.src.upperBound) - e.src.lowerBound + e.base
            out.append(RawWord(text: w.text, start: s, end: max(en, s + 0.12)))
        }
        return out
    }

    func refreshPages(for b: BuiltClip) {
        let inRange = sourceWords.filter { $0.end > start && $0.start < end }
        let mapped = mapWords(inRange, keep: b.keep)
        let words = CaptionBuilder.words(from: mapped, norm: state.levels.norm)
        state.pages = CaptionBuilder.pages(from: words)
        refreshFrame()
    }

    func ensureTranscript(_ r: ClosedRange<Double>) async throws {
        guard let url = videoURL, !isCovered(r) else { return }
        let samples = try await AudioAnalyzer.samples(asset: AVURLAsset(url: url), range: r)
        let raw = try await transcriber.words(samples: samples, model: modelName,
                                              language: language, offset: r.lowerBound)
        sourceWords.removeAll { $0.start >= r.lowerBound && $0.end <= r.upperBound }
        sourceWords.append(contentsOf: raw)
        sourceWords.sort { $0.start < $1.start }
        covered.append(r)
    }

    func generateCaptions() async {
        busyText = "Transcribing… (first run downloads the model)"
        progress = nil
        defer { busyText = nil }
        do {
            try await ensureTranscript(start...end)
            if let b = built { refreshPages(for: b) }
            show("Captions ready")
        } catch {
            show("Transcription failed: \(error.localizedDescription)")
        }
    }

    func setLanguage(_ code: String) {
        guard code != language else { return }
        language = code
        sourceWords = []
        covered = []
        state.pages = []
        refreshFrame()
    }

    // MARK: moment finding

    func analyzeSpeech() {
        guard let url = videoURL, analysisTask == nil else { return }
        analyzing = true
        analysisTask = Task { [weak self] in await self?.runAnalysis(url) }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    private func runAnalysis(_ url: URL) async {
        defer { analysisTask = nil; analyzing = false; busyText = nil; progress = nil }
        let asset = AVURLAsset(url: url)
        let targets = moments.sorted { $0.loud > $1.loud }.prefix(12).map(\.id)
        for (n, id) in targets.enumerated() {
            if Task.isCancelled { break }
            guard let idx = moments.firstIndex(where: { $0.id == id }) else { continue }
            busyText = "Listening to moment \(n + 1) of \(targets.count)…"
            progress = Double(n) / Double(targets.count)
            let m = moments[idx]
            do {
                let r = m.start...m.end
                let samples = try await AudioAnalyzer.samples(asset: asset, range: r)
                let raw = try await transcriber.words(samples: samples, model: modelName,
                                                      language: language, offset: m.start)
                sourceWords.removeAll { $0.start >= r.lowerBound && $0.end <= r.upperBound }
                sourceWords.append(contentsOf: raw)
                covered.append(r)
                var u = moments[idx]
                u.transcript = raw.map(\.text).joined(separator: " ")
                u.text = TextScorer.score(words: raw, duration: m.end - m.start)
                if let f = raw.first, let l = raw.last {
                    let s = max(m.start, f.start - 0.4), e = min(m.end, l.end + 0.8)
                    if e - s >= 8 { u.start = s; u.end = e }
                }
                moments[idx] = u
                if selectedID == id { setTrim(u.start, u.end, resetDetail: true) }
            } catch {
                show("Transcription failed: \(error.localizedDescription)")
                break
            }
        }
        sourceWords.sort { $0.start < $1.start }
        if moments.contains(where: { $0.text != nil }) { source = .best }
    }

    func aiRank() async {
        let key = UserDefaults.standard.string(forKey: "anthropicKey") ?? ""
        guard !key.isEmpty else { show("Add your Anthropic API key in Settings"); return }
        let cands = moments.enumerated().filter { !$0.element.transcript.isEmpty }
            .map { ($0.offset, $0.element.transcript) }
        guard !cands.isEmpty else { show("Run “Analyze speech” first"); return }
        busyText = "Asking Claude to rank moments…"
        progress = nil
        defer { busyText = nil }
        do {
            let res = try await ClaudeRanker.rank(candidates: cands, apiKey: key, language: languageName)
            for r in res where moments.indices.contains(r.index) {
                moments[r.index].ai = r.score
                moments[r.index].hook = r.hook
            }
            source = .best
            if let top = visibleMoments.first { select(top) }
        } catch {
            show("AI rank failed: \(error.localizedDescription)")
        }
    }

    // MARK: export

    func export() async {
        guard videoURL != nil else { return }
        player.pause()
        isPlaying = false
        rebuildTask?.cancel()
        busyText = "Preparing…"
        progress = nil
        defer { busyText = nil; progress = nil }
        do {
            if style.captionsOn {
                busyText = "Transcribing… (first run downloads the model)"
                try await ensureTranscript(start...end)
            }
            busyText = "Rendering reel…"
            let b = try await makeBuilt()
            let out = try await Exporter.export(b, state: state) { [weak self] p in self?.progress = p }
            try await Exporter.saveToPhotos(out)
            try? FileManager.default.removeItem(at: out)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show("Saved to Photos ✓")
        } catch {
            show("Export failed: \(error.localizedDescription)")
        }
        await rebuildPreview()
    }
}
