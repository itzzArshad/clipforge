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
            let src = try await StreamSources.resolve(link)
            let file = try await StreamSources.download(src, options: options, onStatus: onStatus)
            return Result(file: file, title: src.title, channel: src.channel)
        }
        if isYouTube(link) {
            guard configured else {
                throw err("YouTube can't be downloaded inside the app. Twitch and Kick links work directly; for YouTube, run the optional ClipForge helper on a computer, or download the video another way and import it from Files.")
            }
            return try await fetchViaHelper(link, liveMinutes: options.liveMinutes, onStatus: onStatus)
        }
        throw err("Paste a Twitch or Kick video or channel link (or a YouTube link with the helper set up).")
    }

    struct Result {
        let file: URL
        let title: String
        let channel: String
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
    static func fetchViaHelper(_ link: String, liveMinutes: Int,
                      onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> Result {
        let start = try await json(try request("jobs", method: "POST",
                                               body: ["url": link.trimmingCharacters(in: .whitespaces), "live_minutes": liveMinutes]))
        guard let id = start["id"] as? String else { throw err("The helper did not start the download.") }

        var title = "", channel = ""
        while true {
            try Task.checkCancellation()
            let j = try await json(try request("jobs/\(id)"))
            title = j["title"] as? String ?? title
            channel = j["uploader"] as? String ?? channel
            let p = (j["progress"] as? Double) ?? 0
            switch j["state"] as? String ?? "" {
            case "ready":
                break
            case "error":
                throw err(j["error"] as? String ?? "The download failed.")
            case "converting":
                await onStatus("Computer is preparing the video", nil)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            default:
                let live = (j["live"] as? Bool) == true
                await onStatus(live ? "Computer is recording the live stream" : "Computer is downloading", p * 0.6)
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
        return Result(file: dest, title: title, channel: channel)
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
    @State private var partOnly = false
    @State private var from = "0:00"
    @State private var to = "30:00"

    private var isYT: Bool { LinkImporter.isYouTube(link) }
    private var canStart: Bool {
        LinkImporter.supported(link) && (!isYT || LinkImporter.configured) && (!partOnly || (seconds(from) != nil && seconds(to) != nil))
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

                    SectionLabel(text: "Quality")
                    Segments(items: [480, 720, 1080].map(QualityItem.init), label: { "\($0.h)p" },
                             value: Binding(get: { QualityItem(h: quality) }, set: { quality = $0.h }))
                    Text("720p is plenty for Shorts and downloads about half as much as 1080p.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)

                    Toggle("Only part of a long VOD", isOn: $partOnly).tint(Theme.accent)
                        .font(.system(size: 14, weight: .semibold))
                    if partOnly {
                        HStack(spacing: 10) {
                            timeField("From", $from)
                            timeField("To", $to)
                        }
                        Text("Times like 1:05:00. Grabbing the 30-60 minutes you care about is much faster than a whole 4-hour stream.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                    }

                    HStack {
                        Text("If it's live, record").font(.system(size: 14))
                        Spacer()
                        Stepper("\(minutes) min", value: $minutes, in: 5...120, step: 5).fixedSize()
                    }

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
                        if partOnly { o.from = seconds(from); o.to = seconds(to) }
                        onStart(link, o)
                        dismiss()
                    }
                    .disabled(!canStart)
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string, LinkImporter.supported(s) { link = s }
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
