import SwiftUI

/// Kick / Twitch / YouTube links. The phone can't run yt-dlp, so the ClipForge helper on the user's computer
/// downloads the stream and this pulls the finished MP4 over Wi-Fi (see helper/README.md).
enum LinkImporter {
    struct Result {
        let file: URL
        let title: String
        let channel: String
    }

    static var address: String { (UserDefaults.standard.string(forKey: "helperURL") ?? "").trimmingCharacters(in: .whitespaces) }
    static var key: String { (UserDefaults.standard.string(forKey: "helperKey") ?? "").trimmingCharacters(in: .whitespaces) }
    static var configured: Bool { !address.isEmpty && !key.isEmpty }

    static func supported(_ link: String) -> Bool {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return ["youtube.com", "youtu.be", "twitch.tv", "kick.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

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
    static func fetch(_ link: String, liveMinutes: Int,
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
    let onStart: (String, Int) -> Void
    let onSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Kick · Twitch · YouTube")
                TextField("https://kick.com/… or twitch.tv/videos/…", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(.system(size: 15, weight: .medium))
                    .padding(12)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Text("If it's live, record").font(.system(size: 14))
                    Spacer()
                    Stepper("\(minutes) min", value: $minutes, in: 5...180, step: 5).fixedSize()
                }
                if !LinkImporter.configured {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set up the helper first").font(.system(size: 14, weight: .bold))
                        Text("Links are downloaded by the free ClipForge helper on your computer (it uses yt-dlp). Run helper/clipforge_helper.py from the repo, then paste its address and key in Settings.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        Chip(title: "Open settings", icon: "gearshape", selected: true) { dismiss(); onSettings() }
                    }
                    .padding(12).panel(12)
                }
                Text("Only clip streams you have the rights or the creator's permission to use.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(16)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Paste a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Get video") { onStart(link, minutes); dismiss() }
                        .disabled(!LinkImporter.supported(link) || !LinkImporter.configured)
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string, LinkImporter.supported(s) { link = s }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
