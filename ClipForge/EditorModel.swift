import SwiftUI
import AVFoundation
import Observation
import UIKit

enum MomentSource: String, CaseIterable, Identifiable {
    case best = "Best", speech = "Speech", loud = "Loud"
    var id: String { rawValue }
}

enum EditorTab: String, CaseIterable, Identifiable {
    case moments, layout, captions, brand, fx
    var id: String { rawValue }
    var title: String {
        switch self {
        case .moments: return "Moments"
        case .layout: return "Layout"
        case .captions: return "Captions"
        case .brand: return "Brand"
        case .fx: return "FX"
        }
    }
    var icon: String {
        switch self {
        case .moments: return "flame"
        case .layout: return "rectangle.split.1x2"
        case .captions: return "textformat"
        case .brand: return "signature"
        case .fx: return "bolt"
        }
    }
}

struct Lang: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

let languages: [Lang] = [
    Lang(code: "hi", name: "Hindi / Hinglish"), Lang(code: "en", name: "English"),
    Lang(code: "te", name: "Telugu"), Lang(code: "ta", name: "Tamil"),
    Lang(code: "kn", name: "Kannada"), Lang(code: "ml", name: "Malayalam"),
    Lang(code: "mr", name: "Marathi"), Lang(code: "bn", name: "Bengali"),
    Lang(code: "gu", name: "Gujarati"), Lang(code: "pa", name: "Punjabi"),
    Lang(code: "ur", name: "Urdu")
]

/// A running background job, shown inline in the section it belongs to.
struct Job: Equatable {
    var title: String
    var detail: String = ""
    var progress: Double? = nil
}

/// One editable caption phrase (for the caption editor sheet).
struct EditablePhrase: Identifiable, Equatable {
    let id = UUID()
    var range: Range<Int>        // indices into sourceWords
    var start: Double
    var end: Double
    var text: String
}

@MainActor @Observable
final class EditorModel {
    // source video
    var videoURL: URL?
    var duration = 0.0
    var wave: [Float] = []
    var hasVideo: Bool { videoURL != nil }

    // moments
    var moments: [Moment] = []
    var source: MomentSource = .best
    var selectedID: UUID?
    var picked: Set<UUID> = []
    var selecting = false

    // trim
    var start = 0.0
    var end = 30.0
    var detail: ClosedRange<Double> = 0...60
    var removeSilence = true

    // style + captions
    var style = ReelStyle()
    var language = "hi"
    var accurateModel = true
    var sourceWords: [RawWord] = []
    var covered: [ClosedRange<Double>] = []
    var logo: UIImage?

    // background jobs (never block the UI)
    var importJob: Job?
    var analysisJob: Job?
    var captionJob: Job?
    var exportJob: Job?
    var facecamJob: Job?
    var anyJob: Bool { importJob != nil || analysisJob != nil || captionJob != nil || exportJob != nil || facecamJob != nil }

    // facecam editor
    var facecamFrame: UIImage?

    // playback
    var toast: String?
    var playhead = 0.0
    var clipDuration = 0.0
    var isPlaying = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored var state = ReelState(orientation: .up)
    @ObservationIgnored var orientation: CGImagePropertyOrientation = .up
    @ObservationIgnored var bins: [Float] = []
    @ObservationIgnored let transcriber = Transcriber()
    @ObservationIgnored var rebuildTask: Task<Void, Never>?
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var loopObserver: NSObjectProtocol?

    init() {
        loadPrefs()
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                       queue: .main) { [weak self] t in
            Task { @MainActor in self?.playhead = t.seconds }
        }
    }

    // MARK: derived

    var modelName: String { accurateModel ? "large-v3-v20240930_626MB" : "small" }
    var languageName: String { languages.first { $0.code == language }?.name ?? "Hindi" }
    var captionsReady: Bool { isCovered(start...end) }
    var hasAPIKey: Bool { !(UserDefaults.standard.string(forKey: "anthropicKey") ?? "").isEmpty }
    var selectedMoment: Moment? { moments.first { $0.id == selectedID } }

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

    func displayText(_ w: RawWord) -> String {
        (style.script == .hinglish && !w.fixed) ? Transliterator.hinglish(w.text) : w.text
    }

    // MARK: prefs (brand + caption look survive app restarts)

    private func loadPrefs() {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "wm.text") { style.watermarkText = t }
        style.watermarkOn = d.bool(forKey: "wm.on")
        if let p = d.string(forKey: "wm.pos"), let v = WatermarkPosition(rawValue: p) { style.watermarkPos = v }
        if let l = d.string(forKey: "wm.look"), let v = WatermarkLook(rawValue: l) { style.watermarkLook = v }
        if d.object(forKey: "wm.opacity") != nil { style.watermarkOpacity = d.double(forKey: "wm.opacity") }
        if d.object(forKey: "wm.size") != nil { style.watermarkSize = d.double(forKey: "wm.size") }
        if d.object(forKey: "cap.accent") != nil { style.accent = d.integer(forKey: "cap.accent") }
        if let s = d.string(forKey: "cap.style"), let v = CaptionStyleKind(rawValue: s) { style.captionStyle = v }
        if let s = d.string(forKey: "cap.script"), let v = CaptionScript(rawValue: s) { style.script = v }
        if let lang = d.string(forKey: "lang") { language = lang }
        if d.object(forKey: "hq") != nil { accurateModel = d.bool(forKey: "hq") }
        if let data = try? Data(contentsOf: Self.logoURL) { logo = UIImage(data: data) }
    }

    private func savePrefs() {
        let d = UserDefaults.standard
        d.set(style.watermarkText, forKey: "wm.text")
        d.set(style.watermarkOn, forKey: "wm.on")
        d.set(style.watermarkPos.rawValue, forKey: "wm.pos")
        d.set(style.watermarkLook.rawValue, forKey: "wm.look")
        d.set(style.watermarkOpacity, forKey: "wm.opacity")
        d.set(style.watermarkSize, forKey: "wm.size")
        d.set(style.accent, forKey: "cap.accent")
        d.set(style.captionStyle.rawValue, forKey: "cap.style")
        d.set(style.script.rawValue, forKey: "cap.script")
        d.set(language, forKey: "lang")
        d.set(accurateModel, forKey: "hq")
    }

    static var logoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watermark-logo.png")
    }

    func setLogo(_ image: UIImage?) {
        logo = image
        if let image, let png = image.pngData() {
            try? png.write(to: Self.logoURL)
        } else {
            try? FileManager.default.removeItem(at: Self.logoURL)
        }
        state.logo = image
        refreshFrame()
    }

    // MARK: import

    func importVideo(_ url: URL) async {
        analysisTask?.cancel()
        importJob = Job(title: "Reading audio")
        defer { importJob = nil }
        do {
            let asset = AVURLAsset(url: url)
            duration = try await asset.load(.duration).seconds
            if let vt = try await asset.loadTracks(withMediaType: .video).first {
                let pt = try await vt.load(.preferredTransform)
                orientation = Exporter.orientation(for: pt)
            }
            videoURL = url
            bins = try await AudioAnalyzer.loudness(url: url)
            wave = AudioAnalyzer.levels(bins: bins).norm
            sourceWords = []
            covered = []
            picked = []
            style.facecam = nil
            if style.layout == .stream { style.layout = .fit }

            let hs = AudioAnalyzer.highlights(bins: bins, windowSeconds: 30, count: 14)
            let top = max(hs.map(\.score).max() ?? 1, 1)
            moments = hs.map { h in
                let peak = peakTime(in: h.start...h.end)
                return Moment(start: max(0, peak - 15), end: min(duration, peak + 15), peak: peak, loud: h.score / top)
            }
            source = .loud
            if let first = visibleMoments.first {
                select(first)
            } else {
                setTrim(0, min(45, duration), resetDetail: true)
            }
            await rebuildPreview()
            detectFacecam()
            analyzeSpeech()
        } catch {
            show("Import failed: \(error.localizedDescription)")
        }
    }

    private func peakTime(in r: ClosedRange<Double>) -> Double {
        let a = max(0, Int(r.lowerBound / AudioAnalyzer.binSeconds))
        let b = min(bins.count - 1, Int(r.upperBound / AudioAnalyzer.binSeconds))
        guard a <= b else { return (r.lowerBound + r.upperBound) / 2 }
        var best = a
        for i in a...b where bins[i] > bins[best] { best = i }
        return Double(best) * AudioAnalyzer.binSeconds
    }

    // MARK: selection + trim

    func select(_ m: Moment) {
        if selecting {
            if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
            return
        }
        selectedID = m.id
        style.hook = m.hook
        state.style = style
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

    // MARK: building a clip (preview and export share this)

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
            out.append(RawWord(text: displayText(w), start: s, end: max(en, s + 0.12), fixed: true))
        }
        return out
    }

    /// Builds the composition for [s, e] and a fresh render state (levels, caption pages, slam cue).
    func prepare(_ s: Double, _ e: Double, hook: String) async throws -> (BuiltClip, ReelState) {
        guard let url = videoURL else { throw ExportError.noVideo }
        let keep = removeSilence ? AudioAnalyzer.keepRanges(bins: bins, start: s, end: e) : [s...e]
        let b = try await Exporter.build(url: url, keep: keep)
        let samples = try await AudioAnalyzer.samples(asset: b.comp)
        let levels = AudioAnalyzer.levels(bins: AudioAnalyzer.bins(fromSamples: samples))

        let st = ReelState(orientation: orientation)
        var sty = style
        sty.hook = hook
        st.style = sty
        st.levels = levels
        st.duration = b.comp.duration.seconds
        st.logo = logo

        let mapped = mapWords(sourceWords.filter { $0.end > s && $0.start < e }, keep: keep)
        let cw = CaptionBuilder.words(from: mapped, norm: levels.norm)
        st.pages = CaptionBuilder.pages(from: cw)
        st.slam = slamCue(words: cw, env: levels.env)
        return (b, st)
    }

    /// The loudest spoken word, if it is clearly a peak (a shout), becomes the slam.
    private func slamCue(words: [CaptionWord], env: [Float]) -> SlamCue? {
        guard !words.isEmpty, !env.isEmpty else { return nil }
        var best: CaptionWord?
        for w in words where w.text.count >= 2 && w.start > 1.5 {
            if best == nil || w.level > best!.level { best = w }
        }
        guard let b = best, b.level > 0.75 else { return nil }
        return SlamCue(time: b.start, word: b.text.trimmingCharacters(in: .punctuationCharacters))
    }

    func rebuildPreview() async {
        guard videoURL != nil else { return }
        do {
            let (b, st) = try await prepare(start, end, hook: style.hook)
            if Task.isCancelled { return }
            state = st
            clipDuration = b.comp.duration.seconds
            let item = AVPlayerItem(asset: b.comp)
            item.videoComposition = Exporter.videoComposition(for: b, state: st, size: Exporter.previewSize)
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
        savePrefs()
        refreshFrame()
    }

    /// Caption text depends on the script (Hinglish / native), so that needs new pages, not just a redraw.
    func captionsChanged() {
        savePrefs()
        scheduleRebuild()
    }

    func refreshFrame() {
        if !isPlaying {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: transcripts

    private func isCovered(_ r: ClosedRange<Double>) -> Bool {
        covered.contains { $0.lowerBound <= r.lowerBound + 0.5 && $0.upperBound >= r.upperBound - 0.5 }
    }

    private func transcribe(_ r: ClosedRange<Double>) async throws -> [RawWord] {
        guard let url = videoURL else { return [] }
        let samples = try await AudioAnalyzer.samples(asset: AVURLAsset(url: url), range: r)
        let raw = try await transcriber.words(samples: samples, model: modelName, language: language, offset: r.lowerBound)
        // keep words the user already fixed by hand
        let fixed = sourceWords.filter { $0.fixed && $0.start >= r.lowerBound && $0.end <= r.upperBound }
        sourceWords.removeAll { $0.start >= r.lowerBound && $0.end <= r.upperBound }
        if fixed.isEmpty {
            sourceWords.append(contentsOf: raw)
        } else {
            sourceWords.append(contentsOf: fixed)
            sourceWords.append(contentsOf: raw.filter { w in !fixed.contains { $0.start < w.end && $0.end > w.start } })
        }
        sourceWords.sort { $0.start < $1.start }
        covered.append(r)
        return raw
    }

    func generateCaptions() {
        guard captionJob == nil else { return }
        let r = start...end
        captionJob = Job(title: "Transcribing this clip", detail: accurateModel ? "accurate model" : "fast model")
        Task {
            defer { captionJob = nil }
            do {
                _ = try await transcribe(r)
                scheduleRebuild()
                show("Captions ready")
            } catch {
                show("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    func setLanguage(_ code: String) {
        guard code != language else { return }
        language = code
        sourceWords = []
        covered = []
        savePrefs()
        scheduleRebuild()
    }

    /// Claude rewrites the clip's caption words as clean Hinglish (same word count, same timing).
    func aiFixCaptions() {
        let key = UserDefaults.standard.string(forKey: "anthropicKey") ?? ""
        guard !key.isEmpty else { show("Add your Claude API key in Settings"); return }
        guard captionJob == nil else { return }
        let idx = sourceWords.indices.filter { sourceWords[$0].end > start && sourceWords[$0].start < end }
        guard !idx.isEmpty else { show("Generate captions first"); return }
        captionJob = Job(title: "Polishing Hinglish with Claude")
        Task {
            defer { captionJob = nil }
            do {
                let originals = idx.map { sourceWords[$0].text }
                guard let fixed = try await ClaudeRanker.hinglishCaptions(originals, apiKey: key) else {
                    show("Claude changed the word count, kept the original"); return
                }
                for (n, i) in idx.enumerated() where i < sourceWords.count {
                    let t = fixed[n].trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { sourceWords[i].text = t; sourceWords[i].fixed = true }
                }
                scheduleRebuild()
                show("Captions polished")
            } catch {
                show("Claude failed: \(error.localizedDescription)")
            }
        }
    }

    func captionPhrases() -> [EditablePhrase] {
        let idx = sourceWords.indices.filter { sourceWords[$0].end > start && sourceWords[$0].start < end }
        var out: [EditablePhrase] = []
        var cur: [Int] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(EditablePhrase(range: f..<(l + 1), start: sourceWords[f].start, end: sourceWords[l].end,
                                      text: cur.map { displayText(sourceWords[$0]) }.joined(separator: " ")))
            cur = []
        }
        for i in idx {
            if let l = cur.last, cur.count >= 6 || sourceWords[i].start - sourceWords[l].end > 0.6 { flush() }
            cur.append(i)
        }
        flush()
        return out
    }

    /// Replaces each phrase's words with the typed text, spreading the phrase's time over the new words.
    func applyCaptionEdits(_ phrases: [EditablePhrase]) {
        for p in phrases.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard p.range.upperBound <= sourceWords.count else { continue }
            let old = sourceWords[p.range].map { displayText($0) }.joined(separator: " ")
            if old == p.text { continue }
            let tokens = p.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            let span = max(0.2, p.end - p.start)
            let step = tokens.isEmpty ? 0 : span / Double(tokens.count)
            let new = tokens.enumerated().map { (n, t) in
                RawWord(text: t, start: p.start + Double(n) * step, end: p.start + Double(n + 1) * step, fixed: true)
            }
            sourceWords.replaceSubrange(p.range, with: new)
        }
        scheduleRebuild()
    }

    // MARK: facecam

    func detectFacecam() {
        guard let url = videoURL, facecamJob == nil else { return }
        facecamJob = Job(title: "Looking for a facecam")
        let dur = duration
        Task {
            defer { facecamJob = nil }
            if let r = await FacecamDetector.detect(url: url, duration: dur) {
                style.facecam = r
                style.layout = .stream
                styleChanged()
                show("Facecam found → Stream layout")
            }
        }
    }

    func openFacecamEditor() {
        guard let url = videoURL else { return }
        let t = (start + end) / 2
        Task { facecamFrame = await FacecamDetector.frame(url: url, at: t) }
    }

    func setFacecam(_ r: CGRect?) {
        style.facecam = r
        if r == nil, style.layout == .stream { style.layout = .fit }
        if r != nil { style.layout = .stream }
        styleChanged()
    }

    // MARK: moment finding (background)

    func analyzeSpeech() {
        guard videoURL != nil, analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            await self?.runAnalysis()
            self?.analysisTask = nil
            self?.analysisJob = nil
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisJob = nil
    }

    private func runAnalysis() async {
        let targets = moments.sorted { $0.loud > $1.loud }.prefix(12).map(\.id)
        let total = Double(targets.count + (hasAPIKey ? 1 : 0))
        for (n, id) in targets.enumerated() {
            if Task.isCancelled { return }
            guard let idx = moments.firstIndex(where: { $0.id == id }) else { continue }
            analysisJob = Job(title: "Finding the story in each moment", detail: "\(n + 1) of \(targets.count)",
                              progress: Double(n) / total)
            moments[idx].stage = .listening
            let m = moments[idx]
            let win = max(0, m.peak - 38)...min(duration, m.peak + 26)
            do {
                let raw = isCovered(win) ? sourceWords.filter { $0.start >= win.lowerBound && $0.end <= win.upperBound }
                                         : try await transcribe(win)
                guard let i2 = moments.firstIndex(where: { $0.id == id }) else { continue }
                var u = moments[i2]
                let (s, e) = ShortShaper.shape(peak: m.peak, words: raw, window: win, duration: duration)
                let inClip = raw.filter { $0.start >= s && $0.end <= e }
                u.start = s; u.end = e
                u.text = TextScorer.score(words: inClip, duration: e - s)
                u.transcript = inClip.map { Transliterator.hinglish($0.text) }.joined(separator: " ")
                let peakLine = ShortShaper.lines(raw).first { $0.start <= m.peak + 1 && $0.end >= m.peak - 1 }
                if u.title.isEmpty, let pl = peakLine {
                    u.title = "“" + pl.text.split(separator: " ").prefix(5).joined(separator: " ") + "”"
                }
                u.stage = .shaped
                moments[i2] = u
                if selectedID == id { setTrim(u.start, u.end, resetDetail: true) }
            } catch {
                if let i2 = moments.firstIndex(where: { $0.id == id }) { moments[i2].stage = .loud }
                show("Transcription failed: \(error.localizedDescription)")
                return
            }
        }
        if source == .loud { source = .best }
        if hasAPIKey && !Task.isCancelled {
            analysisJob = Job(title: "Claude is cutting the shorts", detail: "context, hooks, scores",
                              progress: Double(targets.count) / total)
            await aiPick()
        }
    }

    /// Claude reads each moment's transcript and decides where the short should start and end.
    func aiPick() async {
        let key = UserDefaults.standard.string(forKey: "anthropicKey") ?? ""
        guard !key.isEmpty else { show("Add your Claude API key in Settings"); return }
        var cands: [ClaudeRanker.Candidate] = []
        var windows: [Int: (UUID, ClosedRange<Double>)] = [:]
        for (i, m) in moments.enumerated() where m.stage == .shaped || m.stage == .ai {
            let win = max(0, m.peak - 38)...min(duration, m.peak + 26)
            let words = sourceWords.filter { $0.start >= win.lowerBound && $0.end <= win.upperBound }
            let lines = ShortShaper.lines(words)
            guard !lines.isEmpty else { continue }
            cands.append(.init(id: i, peak: m.peak, lines: lines))
            windows[i] = (m.id, win)
        }
        guard !cands.isEmpty else { show("No speech found to analyse"); return }
        do {
            let picks = try await ClaudeRanker.pickShorts(cands, apiKey: key, language: languageName)
            for p in picks {
                guard let w = windows[p.id], let i = moments.firstIndex(where: { $0.id == w.0 }) else { continue }
                let win = w.1
                let s = min(max(p.start, win.lowerBound), win.upperBound - 8)
                let e = max(min(p.end, win.upperBound), s + 8)
                moments[i].start = s
                moments[i].end = e
                moments[i].ai = p.score
                if !p.title.isEmpty { moments[i].title = p.title }
                moments[i].hook = p.hook
                moments[i].reason = p.reason
                moments[i].stage = .ai
                let clipWords = sourceWords.filter { $0.start >= s && $0.end <= e }
                moments[i].transcript = clipWords.map { Transliterator.hinglish($0.text) }.joined(separator: " ")
            }
            source = .best
            if let top = visibleMoments.first { select(top) }
            show("Claude picked \(picks.count) shorts")
        } catch {
            show("Claude failed: \(error.localizedDescription)")
        }
    }

    // MARK: export (background, one or many)

    func exportCurrent() {
        guard exportJob == nil else { return }
        let s = start, e = end, hook = style.hook
        exportTask = Task {
            await exportOne(s, e, hook: hook, label: "Exporting reel", index: 0, count: 1)
            exportJob = nil
            exportTask = nil
        }
    }

    func exportPicked() {
        guard exportJob == nil else { return }
        let list = visibleMoments.filter { picked.contains($0.id) }
        guard !list.isEmpty else { show("Pick some moments first"); return }
        selecting = false
        exportTask = Task {
            var ok = 0
            for (n, m) in list.enumerated() {
                if Task.isCancelled { break }
                if await exportOne(m.start, m.end, hook: m.hook, label: "Exporting shorts", index: n, count: list.count) {
                    ok += 1
                    if let i = moments.firstIndex(where: { $0.id == m.id }) { moments[i].exported = true }
                }
            }
            picked = []
            exportJob = nil
            exportTask = nil
            show("\(ok) of \(list.count) shorts saved to Photos")
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportJob = nil
    }

    @discardableResult
    private func exportOne(_ s: Double, _ e: Double, hook: String, label: String, index: Int, count: Int) async -> Bool {
        let detail = count > 1 ? "\(index + 1) of \(count)" : ""
        exportJob = Job(title: label, detail: detail, progress: Double(index) / Double(count))
        do {
            if style.captionsOn, !isCovered(s...e) {
                exportJob?.title = "Transcribing"
                _ = try await transcribe(s...e)
            }
            exportJob?.title = label
            let (b, st) = try await prepare(s, e, hook: hook)
            let out = try await Exporter.export(b, state: st) { [weak self] p in
                self?.exportJob?.progress = (Double(index) + p) / Double(count)
            }
            try await Exporter.saveToPhotos(out)
            try? FileManager.default.removeItem(at: out)
            if count == 1 {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                show("Saved to Photos ✓")
            }
            return true
        } catch {
            show("Export failed: \(error.localizedDescription)")
            return false
        }
    }
}
