import SwiftUI

/// Stream links. Twitch and Kick are downloaded on the phone itself (StreamSources). YouTube can't be: it needs
/// yt-dlp, so it goes through the optional ClipForge helper on a computer (see helper/README.md).
enum LinkImporter {
    static func isYouTube(_ link: String) -> Bool {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return ["youtube.com", "youtu.be"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Picks the route for the link and returns the downloaded file.
    static func fetch(_ link: String, options: StreamSources.Options,
                      onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> Result {
        if StreamSources.supported(link) {
            await onStatus("Opening the stream", nil)
            var src = try await StreamSources.resolve(link)
            var o = options
            if src.live && o.mode != .whole {
                if let login = src.login {
                    // Twitch: the stream's VOD is already there and growing; take any part of it from that
                    await onStatus("Finding the stream's VOD", nil)
                    guard let id = await StreamSources.Twitch.recordingVOD(login) else {
                        throw err("This streamer has VODs turned off, so only recording from now works. Pick \"Whole\" to record the next minutes.")
                    }
                    src = try await StreamSources.Twitch.vod(id)
                } else if o.mode == .best {
                    o.mode = .whole        // Kick: no rewind on a live stream; record from now, find moments after
                } else {
                    throw err("Kick doesn't let apps rewind a stream that is still live. Pick \"Whole\" to record from now, or wait until it ends and use the link under Videos.")
                }
            }
            if o.mode == .best && !src.live {
                guard let id = src.vodID else {
                    throw err("\"Best parts\" needs chat to find the moments, and Kick has no chat replay. Use From–To for Kick videos.")
                }
                return try await bestParts(src, vod: id, options: o, onStatus: onStatus)
            }
            // chat: replay for VODs (fetched while the video downloads), live chat while recording
            let live = LiveChatRecorder()
            if src.live {
                if let login = src.login { live.startTwitch(login) }
                if let room = src.kickChatroom { live.startKick(chatroom: room) }
            }
            var replay: Task<[ChatMessage], Never>?
            var from = o.mode == .range ? (o.from ?? 0) : 0
            if o.mode == .last, src.vodID != nil {
                from = max(0, (try await StreamSources.length(src)) - Double(o.liveMinutes) * 60)
            }
            if let id = src.vodID {
                let f = from, to: Double? = o.mode == .range ? o.to : nil
                replay = Task { await ChatSignal.twitchVOD(id: id, from: f, to: to, onProgress: { _ in }) }
            }
            let dl: StreamSources.Downloaded
            do {
                dl = try await StreamSources.download(src, options: o, onStatus: onStatus)
            } catch {
                live.stop(); replay?.cancel()
                throw error
            }
            live.stop()
            var chat = live.messages
            if let replay {
                await onStatus("Reading the chat replay", nil)
                // replay times start at `from`; the file starts at the first segment, a few seconds earlier
                let shift = from - dl.offset
                chat = await replay.value.map { ChatMessage(t: $0.t + shift, text: $0.text) }
            }
            return Result(file: dl.file, title: src.title, channel: src.channel, chat: chat)
        }
        if isYouTube(link) {
            guard configured else {
                throw err("YouTube can't be downloaded inside the app. Twitch and Kick links work directly; for YouTube, run the optional ClipForge helper on a computer, or download the video another way and import it from Files.")
            }
            return try await fetchViaHelper(link, options: options, onStatus: onStatus)
        }
        throw err("Paste a Twitch or Kick video or channel link (or a YouTube link with the helper set up).")
    }

    /// Twitch "best parts": read the whole chat first (text only, fast), find where it exploded, then download
    /// only ~90 s around each of those spots. A 10-hour VOD becomes a few minutes of video.
    private static func bestParts(_ src: StreamSources.Source, vod id: String, options: StreamSources.Options,
                                  onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> Result {
        await onStatus("Measuring the VOD", nil)
        let length = try await StreamSources.length(src)
        guard length > 60 else { throw err("That video is too short for \"Best parts\". Pick \"Whole\".") }
        await onStatus("Reading the whole chat to find the best parts", 0)
        let chat = await ChatSignal.twitchVODAll(id: id, length: length) { p in onStatus("Reading the whole chat to find the best parts", p * 0.3) }
        let curve = ChatSignal.curve(chat, duration: length)
        let peaks = ChatSignal.peaks(curve, floor: 0.2, gap: 100, count: options.count)
        guard chat.count >= 40, !peaks.isEmpty else {
            throw err("This VOD has too little chat to find moments from. Use From–To for the part you want.")
        }
        var o = options
        o.wants = peaks.map { p in
            let t = Double(p.0)
            return StreamSources.Want(start: max(0, t - 55), end: min(length, t + 35), peak: t)
        }
        let dl = try await StreamSources.download(src, options: o) { t, p in
            onStatus(t == "Downloading on your phone" ? "Downloading the \(o.wants.count) best parts" : t, p.map { 0.3 + 0.7 * $0 })
        }
        // chat into file time, part by part
        var mapped: [ChatMessage] = []
        var sections = dl.sections
        for i in sections.indices {
            let s = sections[i]
            let inside = chat.filter { $0.t >= s.srcStart && $0.t < s.srcStart + s.length }
            mapped += inside.map { ChatMessage(t: s.at + $0.t - s.srcStart, text: $0.text) }
            sections[i].chat = ChatSignal.sample(chat, around: s.srcStart + s.peak, limit: 12)
        }
        return Result(file: dl.file, title: src.title, channel: src.channel, chat: mapped, sections: sections)
    }

    struct Result {
        let file: URL
        let title: String
        let channel: String
        var chat: [ChatMessage] = []
        var heat: [Float] = []          // YouTube "most replayed", per second, 0...1
        var sections: [StreamSources.Section] = []   // "best parts": each part becomes a moment
    }

    static var address: String { (UserDefaults.standard.string(forKey: "helperURL") ?? "").trimmingCharacters(in: .whitespaces) }
    static var key: String { (UserDefaults.standard.string(forKey: "helperKey") ?? "").trimmingCharacters(in: .whitespaces) }
    static var configured: Bool { !address.isEmpty && !key.isEmpty }

    static func supported(_ link: String) -> Bool { StreamSources.supported(link) || isYouTube(link) }

    private static func base() throws -> URL {
        var a = address
        if !a.hasPrefix("http") { a = "http://" + a }
        guard let u = URL(string: a) else { throw err("The helper address looks wrong. Copy it from the helper window.") }
        return u
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: try base().appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue(key, forHTTPHeaderField: "X-Key")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func json(_ r: URLRequest) async throws -> [String: Any] {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: r)
        } catch {
            throw err("Can't reach the helper. Is it running on your computer, and is the phone on the same Wi-Fi?")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw err(obj["error"] as? String ?? "Helper error \(code)")
        }
        return obj
    }

    /// Asks the helper to download `link`, waits for it, then pulls the video. `onStatus` gets (title, progress 0...1).
    static func fetchViaHelper(_ link: String, options o: StreamSources.Options,
                      onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> Result {
        var body: [String: Any] = ["url": link.trimmingCharacters(in: .whitespaces), "live_minutes": o.liveMinutes,
                                   "mode": o.mode.rawValue, "count": o.count, "height": o.maxHeight]
        if o.mode == .range, let f = o.from, let t = o.to { body["from"] = f; body["to"] = t }
        let start = try await json(try request("jobs", method: "POST", body: body))
        guard let id = start["id"] as? String else { throw err("The helper did not start the download.") }

        var title = "", channel = ""
        var heat: [Float] = []
        var sections: [StreamSources.Section] = []
        while true {
            try Task.checkCancellation()
            let j = try await json(try request("jobs/\(id)"))
            title = j["title"] as? String ?? title
            channel = j["uploader"] as? String ?? channel
            if heat.isEmpty, let hm = j["heatmap"] as? [[String: Any]], !hm.isEmpty {
                // YouTube's "most replayed" graph: [{start_time, end_time, value}] -> per second
                let end = hm.compactMap { $0["end_time"] as? Double }.max() ?? 0
                var per = [Float](repeating: 0, count: max(1, Int(end.rounded(.up))))
                for h in hm {
                    let a = Int((h["start_time"] as? Double) ?? 0), b = Int(((h["end_time"] as? Double) ?? 0).rounded(.up))
                    let v = Float((h["value"] as? Double) ?? 0)
                    for i in max(0, a)..<min(per.count, max(a, b)) { per[i] = v }
                }
                heat = per
            }
            let p = (j["progress"] as? Double) ?? 0
            switch j["state"] as? String ?? "" {
            case "ready":
                for m in (j["markers"] as? [[String: Any]]) ?? [] {
                    func d(_ k: String) -> Double { (m[k] as? Double) ?? Double(m[k] as? Int ?? 0) }
                    sections.append(StreamSources.Section(at: d("at"), length: d("length"), peak: d("peak"),
                                                          srcStart: d("src_start"), chat: (m["chat"] as? [String]) ?? []))
                }
            case "error":
                throw err(j["error"] as? String ?? "The download failed.")
            case "converting":
                await onStatus("Computer is preparing the video", nil)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            default:
                let live = (j["live"] as? Bool) == true
                let note = j["note"] as? String
                await onStatus(note ?? (live ? "Computer is recording the live stream" : "Computer is downloading"), p * 0.6)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            break
        }

        await onStatus("Copying to your phone", 0.6)
        var r = try request("jobs/\(id)/file")
        r.timeoutInterval = 600
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(id).mp4")
        try await Downloader(onProgress: { p in Task { @MainActor in onStatus("Copying to your phone", 0.6 + 0.4 * p) } })
            .download(r, to: dest)
        _ = try? await json(try request("jobs/\(id)", method: "DELETE"))
        // with only the best parts downloaded, the replay graph is in original time and no longer lines up
        return Result(file: dest, title: title, channel: channel, heat: sections.isEmpty ? heat : [], sections: sections)
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "Link", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

/// A file download with progress (the async URLSession APIs don't report bytes as they arrive).
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var dest: URL?

    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func download(_ request: URLRequest, to dest: URL) async throws {
        self.dest = dest
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest else { return }
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            continuation?.resume(throwing: NSError(domain: "Link", code: code,
                                                   userInfo: [NSLocalizedDescriptionKey: "Copy failed (\(code))"]))
            continuation = nil
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

/// "Paste a link" sheet.
struct LinkSheet: View {
    let onStart: (String, StreamSources.Options) -> Void
    let onSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var minutes = 30
    @State private var quality = 720
    @State private var mode: StreamSources.Mode = .best
    @State private var count = 8
    @State private var from = "0:00"
    @State private var to = "30:00"

    private var isYT: Bool { LinkImporter.isYouTube(link) }
    private var isKick: Bool { link.lowercased().contains("kick.com") }
    private var canStart: Bool {
        guard LinkImporter.supported(link), !isYT || LinkImporter.configured else { return false }
        if mode == .range { return (seconds(from) ?? -1) >= 0 && (seconds(to) ?? -1) > (seconds(from) ?? 0) }
        if mode == .best && isKick { return false }
        return true
    }

    private var modeHelp: String {
        switch mode {
        case .best:
            if isKick { return "Kick has no chat replay to find moments from. Use From–To, or Last N min on a live stream (Twitch/YouTube)." }
            return "Fastest. Reads the chat (and YouTube's most-replayed graph) first, then downloads only ~90 s around each of the \(count) biggest moments. A 10-hour VOD becomes about \(count * 3 / 2) minutes of video. Works on Twitch streams that are still live, too."
        case .range:
            return "Times from the start of the stream, like 2:15:00. Works on Twitch and YouTube streams that are still live: you can grab 1:00:00–1:20:00 while they're streaming."
        case .last:
            return "The last \(minutes) minutes of a stream that is live right now (Twitch, or YouTube with ytarchive on the PC). On a finished VOD: its last \(minutes) minutes."
        case .whole:
            return "The whole VOD, or for a live stream: record the next \(minutes) minutes from now. Slowest for long streams."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "Twitch · Kick  (YouTube with the PC helper)")
                    TextField("twitch.tv/videos/… or kick.com/channel/videos/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .font(.system(size: 15, weight: .medium))
                        .padding(12)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    SectionLabel(text: "What to get")
                    Segments(items: StreamSources.Mode.allCases, label: { $0.label }, value: $mode)
                    Text(modeHelp).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)

                    switch mode {
                    case .best:
                        HStack {
                            Text("Moments").font(.system(size: 14))
                            Spacer()
                            Stepper("\(count)", value: $count, in: 4...15).fixedSize()
                        }
                    case .range:
                        HStack(spacing: 10) {
                            timeField("From", $from)
                            timeField("To", $to)
                        }
                    case .last, .whole:
                        HStack {
                            Text(mode == .last ? "Last" : "If it's live, record").font(.system(size: 14))
                            Spacer()
                            Stepper("\(minutes) min", value: $minutes, in: 5...120, step: 5).fixedSize()
                        }
                    }

                    SectionLabel(text: "Quality")
                    Segments(items: [480, 720, 1080].map(QualityItem.init), label: { "\($0.h)p" },
                             value: Binding(get: { QualityItem(h: quality) }, set: { quality = $0.h }))
                    Text("720p is plenty for Shorts and downloads about half as much as 1080p.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)

                    if isYT && !LinkImporter.configured {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YouTube needs the PC helper").font(.system(size: 14, weight: .bold))
                            Text("YouTube blocks downloads from apps. Twitch and Kick work right here on the phone. For YouTube, run helper/clipforge_helper.py on a computer and add its address in Settings.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                            Chip(title: "Open settings", icon: "gearshape", selected: true) { dismiss(); onSettings() }
                        }
                        .padding(12).panel(12)
                    }
                    Text("Keep ClipForge open while it downloads; iOS pauses apps in the background. Only clip streams you have the rights or the creator's permission to use.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Paste a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Get video") {
                        var o = StreamSources.Options()
                        o.maxHeight = quality
                        o.liveMinutes = minutes
                        o.mode = mode
                        o.count = count
                        if mode == .range { o.from = seconds(from); o.to = seconds(to) }
                        onStart(link, o)
                        dismiss()
                    }
                    .disabled(!canStart)
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string, LinkImporter.supported(s) { link = s }
            }
            .onChange(of: link) { _, _ in
                if isKick && mode == .best { mode = .range }
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private func timeField(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title)
            TextField("0:00", text: text)
                .keyboardType(.numbersAndPunctuation)
                .font(Theme.mono(15, .semibold))
                .padding(10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// "1:05:00" / "65:00" / "3900" -> seconds
    private func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

struct QualityItem: Hashable, Identifiable {
    let h: Int
    var id: Int { h }
}
