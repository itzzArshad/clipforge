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

/// A prompt waiting for the user to run in any AI chat and paste the answer back.
struct AIRequest: Identifiable {
    enum Kind { case moments, captions }
    let id = UUID()
    let kind: Kind
    let prompt: String
    var windows: [Int: ClosedRange<Double>] = [:]   // moments: candidate number -> window it may cut in
    var momentIDs: [Int: UUID] = [:]
    var wordIndices: [Int] = []                     // captions: which sourceWords the answer replaces
    var originals: [String] = []
}

/// Asks iOS for a little extra time if the user leaves the app mid-download.
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid
    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "stream-download") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
    }
}

@MainActor @Observable
final class EditorModel {
    // source video
    var videoURL: URL?
    var videoTitle = ""          // from a stream link: helps Claude with names and context
    var channel = ""
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
    var accurateModel = false         // the big model is the main source of heat; it is opt-in now
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

    // free signals from the platform (no AI): chat, YouTube "most replayed"
    var chat: [ChatMessage] = []
    var chatCurve: [Float] = []
    var replays: [Float] = []
    var sections: [StreamSources.Section] = []      // "best parts" downloads: where each part sits in the file

    // copy-paste AI
    var aiRequest: AIRequest?
    var hot = false                    // the phone is too warm: heavy work waits

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
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
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

    /// Kick / Twitch / YouTube link through the helper on the user's computer.
    func importLink(_ link: String, options: StreamSources.Options) {
        guard importJob == nil else { return }
        importJob = Job(title: "Opening the stream")
        // a little extra time if the user switches apps; long downloads still need the app open
        let bg = BackgroundTime()
        UIApplication.shared.isIdleTimerDisabled = true      // keep the screen awake while it downloads
        Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                bg.end()
            }
            do {
                let r = try await LinkImporter.fetch(link, options: options) { [weak self] t, p in
                    self?.importJob = Job(title: t, progress: p)
                }
                await importVideo(r.file, title: r.title, channel: r.channel, chat: r.chat, replays: r.heat,
                                  sections: r.sections)
            } catch {
                importJob = nil
                show(error.localizedDescription)
            }
        }
    }

    func importVideo(_ url: URL, title: String = "", channel: String = "",
                     chat: [ChatMessage] = [], replays: [Float] = [], sections: [StreamSources.Section] = []) async {
        analysisTask?.cancel()
        analysisTask = nil
        analysisJob = nil
        videoTitle = title
        self.channel = channel
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
            self.chat = chat
            chatCurve = ChatSignal.curve(chat, duration: duration)
            self.replays = replays.count > 10 ? replays : []
            self.sections = sections

            moments = sections.isEmpty ? findMoments() : sectionMoments()
            source = .best
            if let first = visibleMoments.first {
                select(first)
            } else {
                setTrim(0, min(45, duration), resetDetail: true)
            }
            await rebuildPreview()
            detectFacecam()
            var found = "\(moments.count) moments"
            if !chatCurve.isEmpty { found += " · chat \(chat.count) msgs" }
            if !self.replays.isEmpty { found += " · most-replayed" }
            if !sections.isEmpty { found = "\(moments.count) best parts" + (chat.isEmpty ? "" : " · chat \(chat.count) msgs") }
            show(found)
        } catch {
            show("Import failed: \(error.localizedDescription)")
        }
    }

    /// Moments from free signals only (no AI, no transcription): loud audio, chat spikes, YouTube replays.
    /// Each is cut with a few seconds of setup before the peak and ends on a pause in the talking.
    private func findMoments() -> [Moment] {
        var cands: [(peak: Double, from: String)] = []
        let hs = AudioAnalyzer.highlights(bins: bins, windowSeconds: 30, count: 14)
        for h in hs { cands.append((peakTime(in: h.start...h.end), "loud")) }
        for p in ChatSignal.peaks(chatCurve, count: 15) { cands.append((Double(p.0), "chat")) }
        for p in ChatSignal.peaks(replays, floor: 0.5, gap: 45, count: 8) { cands.append((Double(p.0) + 3, "replay")) }

        var out: [Moment] = []
        for c in cands {
            // one moment per stretch of video: a chat spike next to a loud peak is the same moment
            if let i = out.firstIndex(where: { abs($0.peak - c.peak) < 20 }) {
                if c.from == "chat" { out[i].peak = (out[i].peak + c.peak) / 2 }
                continue
            }
            let peak = min(max(0, c.peak), duration)
            let s = AudioAnalyzer.nearestPause(bins: bins, t: max(0, peak - 18))
            let e = AudioAnalyzer.nearestPause(bins: bins, t: min(duration, peak + 10))
            var m = Moment(start: s, end: max(e, min(duration, s + 12)), peak: peak, loud: loudScore(s...e))
            if !chatCurve.isEmpty {
                m.chat = curveScore(chatCurve, around: peak)
                m.chatSample = ChatSignal.sample(chat, around: peak, limit: 12)
            }
            if !replays.isEmpty { m.heat = curveScore(replays, around: peak) }
            m.title = c.from == "chat" ? "Chat went off" : (c.from == "replay" ? "Most replayed" : "Loud moment")
            out.append(m)
        }
        return out
    }

    /// One moment per downloaded part: setup before the peak, payoff after, cut on pauses, never across parts.
    private func sectionMoments() -> [Moment] {
        var out: [Moment] = []
        for sec in sections {
            let lo = sec.at, hi = min(duration, sec.at + sec.length)
            guard hi - lo > 5 else { continue }
            let peak = min(max(lo, sec.at + sec.peak), hi)
            let s = min(max(lo, AudioAnalyzer.nearestPause(bins: bins, t: max(lo, peak - 18))), hi - 5)
            let e = max(min(hi, AudioAnalyzer.nearestPause(bins: bins, t: min(hi, peak + 10))), min(hi, s + 12))
            var m = Moment(start: s, end: e, peak: peak, loud: loudScore(s...e))
            if !chatCurve.isEmpty { m.chat = curveScore(chatCurve, around: peak) }
            m.chatSample = sec.chat.isEmpty ? ChatSignal.sample(chat, around: peak, limit: 12) : sec.chat
            let h = Int(sec.srcStart + sec.peak)
            m.title = "Part at \(h / 3600):\(String(format: "%02d", h % 3600 / 60)):\(String(format: "%02d", h % 60))"
            out.append(m)
        }
        return out
    }

    private func curveScore(_ c: [Float], around t: Double) -> Float {
        guard !c.isEmpty else { return 0 }
        let a = max(0, Int(t) - 8), b = min(c.count - 1, Int(t) + 8)
        guard a <= b else { return 0 }
        return c[a...b].max() ?? 0
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
    func prepare(_ s: Double, _ e: Double, hook: String, highlights: [String] = []) async throws -> (BuiltClip, ReelState) {
        guard let url = videoURL else { throw ExportError.noVideo }
        let keep = removeSilence ? AudioAnalyzer.keepRanges(bins: bins, start: s, end: e) : [s...e]
        let b = try await Exporter.build(url: url, keep: keep)
        // the clip's loudness comes from the bins already measured at import, not from decoding audio again
        let levels = AudioAnalyzer.levels(bins: AudioAnalyzer.clipBins(bins, keep: keep))

        let st = ReelState(orientation: orientation)
        var sty = style
        sty.hook = hook
        st.style = sty
        st.levels = levels
        st.duration = b.comp.duration.seconds
        st.logo = logo

        let mapped = mapWords(sourceWords.filter { $0.end > s && $0.start < e }, keep: keep)
        let cw = CaptionBuilder.words(from: mapped, norm: levels.norm, highlights: highlights)
        st.pages = CaptionBuilder.pages(from: cw, per: style.captionStyle.spec.perPage)
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
            let (b, st) = try await prepare(start, end, hook: style.hook, highlights: selectedMoment?.highlights ?? [])
            if Task.isCancelled { return }
            state = st
            clipDuration = b.comp.duration.seconds
            let item = AVPlayerItem(asset: b.comp)
            item.videoComposition = Exporter.videoComposition(for: b, state: st, size: Exporter.previewSize, fps: 24)
            // plays once, then stops (a preview looping forever kept the GPU busy and the phone warm)
            if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isPlaying = false
                    self?.player.seek(to: .zero)
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

    /// App went to the background: stop playback and free the speech model (hundreds of MB).
    func pauseForBackground() {
        player.pause()
        isPlaying = false
        if analysisJob == nil && captionJob == nil && exportJob == nil {
            Task { await transcriber.unload() }
        }
    }

    /// Waits while the phone is hot. Heavy steps call this first, so the phone gets a chance to cool down
    /// instead of throttling (which makes everything slower and hotter).
    func coolDown(_ update: (String) -> Void) async {
        while !Task.isCancelled {
            let t = ProcessInfo.processInfo.thermalState
            hot = t == .serious || t == .critical
            if !hot { return }
            update("Phone is hot · paused to cool down")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
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
        await coolDown { [weak self] msg in
            self?.analysisJob?.detail = msg
            self?.captionJob?.detail = msg
            self?.exportJob?.detail = msg
        }
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

    /// Caption spelling fix (Hinglish, digits, names) by any AI: makes the prompt; the answer comes back
    /// through `applyAI`. Same word count and timing; translations are refused (PeakCut's rules).
    func aiFixCaptions() {
        let idx = sourceWords.indices.filter { sourceWords[$0].end > start && sourceWords[$0].start < end }
        guard idx.count >= 3 else { show("Transcribe the clip first"); return }
        let originals = idx.map { sourceWords[$0].text }
        aiRequest = AIRequest(kind: .captions, prompt: AIBridge.captionsPrompt(originals, title: videoTitle),
                              wordIndices: idx, originals: originals)
    }

    private func applyCaptionAnswer(_ reply: String, _ req: AIRequest) -> String? {
        guard let fixed = AIBridge.parseCaptions(reply, original: req.originals) else {
            return "That answer doesn't have exactly \(req.originals.count) words in a JSON list. Copy the whole answer, or ask the AI again."
        }
        // apply back to front so removals do not shift the indices still to come
        for (n, i) in req.wordIndices.enumerated().reversed() where i < sourceWords.count {
            guard sourceWords[i].text == req.originals[n] else { continue }   // changed since: leave it
            let t = fixed[n].trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                if n > 0, req.wordIndices[n - 1] < sourceWords.count { sourceWords[req.wordIndices[n - 1]].end = sourceWords[i].end }
                sourceWords.remove(at: i)
            } else {
                sourceWords[i].text = t
                sourceWords[i].fixed = true
            }
        }
        scheduleRebuild()
        show("Captions fixed")
        return nil
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

    // MARK: moment finding (background, opt-in)

    /// Transcribes only the top few moments (about a minute each) so they can be cut at real sentence ends and
    /// judged by what was said. Uses the light model unless "Accurate" is on.
    func listenTop(_ n: Int = 5) {
        guard videoURL != nil, analysisTask == nil else { return }
        let ids = visibleMoments.filter { $0.stage == .loud }.prefix(n).map(\.id)
        guard !ids.isEmpty else { show("The top moments are already transcribed"); return }
        analysisTask = Task { [weak self] in
            await self?.runListen(ids)
            await self?.transcriber.unload()
            self?.analysisTask = nil
            self?.analysisJob = nil
        }
    }

    /// Deep scan: transcribes the whole video, then scores every stretch by what was said. Heavy: on a long
    /// stream this keeps the phone busy (and warm) for a long time. Pauses itself when the phone gets hot.
    func deepScan() {
        guard videoURL != nil, analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            await self?.runDeepScan()
            await self?.transcriber.unload()
            self?.analysisTask = nil
            self?.analysisJob = nil
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisJob = nil
        for i in moments.indices where moments[i].stage == .listening { moments[i].stage = .loud }
    }

    private func window(_ m: Moment) -> ClosedRange<Double> {
        max(0, m.peak - 38)...min(duration, m.peak + 26)
    }

    private func runListen(_ ids: [UUID]) async {
        for (n, id) in ids.enumerated() {
            if Task.isCancelled { return }
            guard let idx = moments.firstIndex(where: { $0.id == id }) else { continue }
            analysisJob = Job(title: "Listening to the top moments", detail: "\(n + 1) of \(ids.count)",
                              progress: Double(n) / Double(ids.count))
            moments[idx].stage = .listening
            let win = window(moments[idx])
            do {
                let raw = isCovered(win) ? sourceWords.filter { $0.start >= win.lowerBound && $0.end <= win.upperBound }
                                         : try await transcribe(win)
                guard let i2 = moments.firstIndex(where: { $0.id == id }) else { continue }
                shapeLoud(i2, words: raw, window: win)
            } catch {
                if let i2 = moments.firstIndex(where: { $0.id == id }) { moments[i2].stage = .loud }
                show("Transcription failed: \(error.localizedDescription)")
                return
            }
        }
        show("Done · tap Ask AI to have an AI pick and cut them")
    }

    private func runDeepScan() async {
        let chunk = 90.0
        var t = 0.0
        var spans: [ClosedRange<Double>] = []
        while t < duration { spans.append(t...min(duration, t + chunk)); t += chunk }
        let todo = spans.filter { !isCovered($0) }
        for (n, r) in todo.enumerated() {
            if Task.isCancelled { return }
            analysisJob = Job(title: "Deep scan: transcribing everything",
                              detail: "\(clock(r.lowerBound)) of \(clock(duration))",
                              progress: Double(n) / Double(max(todo.count, 1)))
            do { _ = try await transcribe(r) } catch {
                show("Transcription failed: \(error.localizedDescription)")
                return
            }
        }
        for i in moments.indices where moments[i].stage != .ai {
            let win = window(moments[i])
            shapeLoud(i, words: sourceWords.filter { $0.start >= win.lowerBound && $0.end <= win.upperBound }, window: win)
        }
        addSpeechMoments()
        show("Deep scan done")
    }

    /// Cuts a moment at sentence boundaries and scores what was said.
    private func shapeLoud(_ i: Int, words raw: [RawWord], window win: ClosedRange<Double>) {
        var u = moments[i]
        let (s, e) = ShortShaper.shape(peak: u.peak, words: raw, window: win, duration: duration)
        let inClip = raw.filter { $0.start >= s && $0.end <= e }
        u.start = s; u.end = e
        u.text = TextScorer.score(words: inClip, duration: e - s)
        u.transcript = inClip.map { Transliterator.roman($0.text) }.joined(separator: " ")
        let peakLine = ShortShaper.lines(raw).first { $0.start <= u.peak + 1 && $0.end >= u.peak - 1 }
        if let pl = peakLine, ["Loud moment", "Chat went off", "Most replayed", ""].contains(u.title) {
            u.title = "“" + pl.text.split(separator: " ").prefix(5).joined(separator: " ") + "”"
        }
        u.stage = .shaped
        moments[i] = u
        if selectedID == u.id { setTrim(u.start, u.end, resetDetail: true) }
    }

    /// After a deep scan: the most excited-sounding stretches of speech that are not already a moment.
    private func addSpeechMoments() {
        let words = sourceWords
        guard words.count > 20 else { return }
        var cands: [(Double, Double, Float)] = []
        var t = 0.0
        while t + 40 <= duration {
            let w = words.filter { $0.start >= t && $0.end <= t + 40 }
            cands.append((t, t + 40, TextScorer.score(words: w, duration: 40)))
            t += 10
        }
        var added = 0
        for c in cands.sorted(by: { $0.2 > $1.2 }) where added < 6 && c.2 > 0.35 {
            if moments.contains(where: { min(c.1, $0.end) - max(c.0, $0.start) > 10 }) { continue }
            guard let r = ShortShaper.snap(start: c.0, end: c.1, words: words, duration: duration) else { continue }
            let inClip = words.filter { $0.start >= r.0 && $0.end <= r.1 }
            var m = Moment(start: r.0, end: r.1, peak: peakTime(in: r.0...r.1), loud: loudScore(r.0...r.1))
            m.text = c.2
            m.transcript = inClip.map { Transliterator.roman($0.text) }.joined(separator: " ")
            m.title = "“" + inClip.prefix(5).map { Transliterator.roman($0.text) }.joined(separator: " ") + "”"
            m.stage = .shaped
            moments.append(m)
            added += 1
        }
    }

    /// 0...1: how loud this stretch is compared with the whole video.
    private func loudScore(_ r: ClosedRange<Double>) -> Float {
        guard !wave.isEmpty else { return 0 }
        let a = max(0, Int(r.lowerBound / AudioAnalyzer.binSeconds))
        let b = min(wave.count - 1, Int(r.upperBound / AudioAnalyzer.binSeconds))
        guard a <= b else { return 0 }
        return wave[a...b].reduce(0, +) / Float(b - a + 1)
    }

    // MARK: AI (copy-paste, or sent with a key)

    /// Builds one prompt about the top moments: what was said (if transcribed) and what chat spammed.
    func askAIForMoments() {
        let top = Array(visibleMoments.prefix(15))
        guard !top.isEmpty else { show("No moments yet"); return }
        var cands: [AIBridge.Candidate] = []
        var windows: [Int: ClosedRange<Double>] = [:]
        var ids: [Int: UUID] = [:]
        let z = wave
        for (n, m) in top.enumerated() {
            let win = window(m)
            let words = sourceWords.filter { $0.start >= win.lowerBound && $0.end <= win.upperBound }
            let lines = ShortShaper.lines(words, gap: 0.7).map { l -> (Double, String, Bool) in
                let a = max(0, Int(l.start / AudioAnalyzer.binSeconds)), b = min(z.count - 1, Int(l.end / AudioAnalyzer.binSeconds))
                return (l.start, l.text, a <= b && (z[a...b].max() ?? 0) > 0.85)
            }
            cands.append(.init(id: n, from: win.lowerBound, to: win.upperBound, peak: m.peak,
                               transcript: lines, chat: m.chatSample, loud: m.loud))
            windows[n] = win
            ids[n] = m.id
        }
        if cands.allSatisfy({ $0.transcript.isEmpty && $0.chat.isEmpty }) {
            show("Tip: tap Listen first, so the AI knows what was said")
        }
        aiRequest = AIRequest(kind: .moments, prompt: AIBridge.momentsPrompt(cands, title: videoTitle, channel: channel),
                              windows: windows, momentIDs: ids)
    }

    /// Applies a pasted (or sent) AI answer. Returns an error message to show, or nil when it worked.
    func applyAI(_ reply: String, for req: AIRequest) -> String? {
        switch req.kind {
        case .captions:
            return applyCaptionAnswer(reply, req)
        case .moments:
            guard let picks = AIBridge.parseMoments(reply, windows: req.windows) else {
                return "Couldn't find the JSON list in that answer. Copy the AI's whole reply and paste it here."
            }
            guard !picks.isEmpty else { return "The AI didn't keep any moment. Try another part of the stream." }
            for p in picks {
                guard let id = req.momentIDs[p.id], let i = moments.firstIndex(where: { $0.id == id }) else { continue }
                var s = p.start, e = p.end
                let words = sourceWords.filter { $0.start >= s - 5 && $0.end <= e + 12 }
                if words.count > 5, let r = ShortShaper.snap(start: s, end: e, words: words, minLen: 12, maxLen: 70, duration: duration) {
                    (s, e) = r
                } else {
                    s = AudioAnalyzer.nearestPause(bins: bins, t: s, within: 1.5)
                    e = AudioAnalyzer.nearestPause(bins: bins, t: e, within: 1.5)
                }
                var m = moments[i]
                m.start = s; m.end = max(e, s + 8)
                m.ai = p.score
                m.title = p.title.isEmpty ? m.title : p.title
                m.hook = p.hook
                m.reason = p.reason
                m.category = p.category
                m.postTitle = p.title
                m.postText = p.description + (p.hashtags.isEmpty ? "" : "\n\n" + p.hashtags.map { "#" + $0 }.joined(separator: " "))
                m.highlights = p.highlights
                m.stage = .ai
                moments[i] = m
            }
            // moments the AI skipped drop down the list
            let kept = Set(picks.compactMap { req.momentIDs[$0.id] })
            for (_, id) in req.momentIDs where !kept.contains(id) {
                if let i = moments.firstIndex(where: { $0.id == id }) { moments[i].ai = 0 }
            }
            source = .best
            if let top = visibleMoments.first { select(top) }
            show("AI picked \(picks.count) shorts")
            return nil
        }
    }

    /// Sends the prompt with the user's own Claude API key instead of copy-paste.
    func sendAI(_ req: AIRequest) async -> String? {
        let key = UserDefaults.standard.string(forKey: "anthropicKey") ?? ""
        guard !key.isEmpty else { return "Add a Claude API key in Settings, or copy the prompt instead." }
        do {
            let reply = try await AIBridge.send(prompt: req.prompt, apiKey: key)
            return applyAI(reply, for: req)
        } catch {
            return error.localizedDescription
        }
    }

    func copyPostText(_ m: Moment) {
        let text = [m.postTitle, m.postText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        UIPasteboard.general.string = text.isEmpty ? m.title : text
        show("Post text copied")
    }

    // MARK: export (background, one or many)

    func exportCurrent() {
        guard exportJob == nil else { return }
        let s = start, e = end, hook = style.hook, hl = selectedMoment?.highlights ?? []
        exportTask = Task {
            await exportOne(s, e, hook: hook, highlights: hl, label: "Exporting reel", index: 0, count: 1)
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
                if await exportOne(m.start, m.end, hook: m.hook, highlights: m.highlights, label: "Exporting shorts", index: n, count: list.count) {
                    ok += 1
                    if let i = moments.firstIndex(where: { $0.id == m.id }) { moments[i].exported = true }
                }
            }
            picked = []
            exportJob = nil
            exportTask = nil
            await transcriber.unload()
            show("\(ok) of \(list.count) shorts saved to Photos")
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportJob = nil
    }

    @discardableResult
    private func exportOne(_ s: Double, _ e: Double, hook: String, highlights: [String] = [], label: String, index: Int, count: Int) async -> Bool {
        let detail = count > 1 ? "\(index + 1) of \(count)" : ""
        exportJob = Job(title: label, detail: detail, progress: Double(index) / Double(count))
        do {
            await coolDown { [weak self] msg in self?.exportJob?.detail = msg }
            if style.captionsOn, !isCovered(s...e) {
                exportJob?.title = "Transcribing"
                _ = try await transcribe(s...e)
            }
            exportJob?.title = label
            let (b, st) = try await prepare(s, e, hook: hook, highlights: highlights)
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
