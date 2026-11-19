import Foundation
import AVFoundation
import WebKit

/// Downloads Twitch and Kick VODs and live streams on the phone itself: find the stream's HLS playlist,
/// pick an H.264 rendition, fetch the segments (only the part asked for) and remux them into an MP4.
enum StreamSources {
    struct Source {
        let master: URL
        let title: String
        let channel: String
        let live: Bool
        let isTwitch: Bool
        var vodID: String? = nil          // Twitch VOD: for the chat replay
        var login: String? = nil          // Twitch live: for live chat
        var kickChatroom: Int? = nil      // Kick live: for live chat
    }

    /// The downloaded file, and where it starts in the original video (for lining up chat).
    struct Downloaded {
        let file: URL
        let offset: Double
    }

    struct Options {
        var maxHeight = 720
        var from: Double? = nil
        var to: Double? = nil
        var liveMinutes = 30
    }

    enum Site { case twitchVOD(String), twitchLive(String), kickVOD(String), kickLive(String) }

    static func site(_ link: String) -> Site? {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased() else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        if host == "twitch.tv" || host.hasSuffix(".twitch.tv") {
            if parts.count >= 2, parts[0] == "videos", parts[1].allSatisfy(\.isNumber) { return .twitchVOD(parts[1]) }
            if parts.count >= 3, parts[1] == "video", parts[2].allSatisfy(\.isNumber) { return .twitchVOD(parts[2]) }
            if parts.count == 1, !["directory", "videos", "settings", "search"].contains(parts[0]) { return .twitchLive(parts[0].lowercased()) }
            return nil
        }
        if host == "kick.com" || host.hasSuffix(".kick.com") {
            if parts.count >= 3, parts[1] == "videos" { return .kickVOD(parts[2]) }
            if parts.count >= 2, parts[0] == "video" { return .kickVOD(parts[1]) }
            if parts.count == 1 { return .kickLive(parts[0].lowercased()) }
            return nil
        }
        return nil
    }

    static func supported(_ link: String) -> Bool { site(link) != nil }

    static func err(_ m: String) -> NSError {
        NSError(domain: "Stream", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: resolving a link

    static func resolve(_ link: String) async throws -> Source {
        guard let s = site(link) else { throw err("That doesn't look like a Twitch or Kick video or channel link.") }
        switch s {
        case .twitchVOD(let id): return try await Twitch.vod(id)
        case .twitchLive(let login): return try await Twitch.live(login)
        case .kickVOD(let id): return try await Kick.vod(id)
        case .kickLive(let slug): return try await Kick.live(slug)
        }
    }

    enum Twitch {
        // the public web player's client id, the same one every Twitch downloader uses
        static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

        static func gql(_ body: [String: Any]) async throws -> [String: Any] {
            var r = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
            r.httpMethod = "POST"
            r.setValue(clientID, forHTTPHeaderField: "Client-ID")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: r)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        static func token(vod: String?, login: String?) async throws -> (String, String) {
            let query = """
            query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isLive) { value signature __typename } videoPlaybackAccessToken(id: $vodID, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isVod) { value signature __typename } }
            """
            let res = try await gql(["operationName": "PlaybackAccessToken_Template", "query": query,
                                     "variables": ["isLive": login != nil, "login": login ?? "", "isVod": vod != nil,
                                                   "vodID": vod ?? "", "playerType": "site"]])
            let data = res["data"] as? [String: Any]
            let t = (data?[vod != nil ? "videoPlaybackAccessToken" : "streamPlaybackAccessToken"]) as? [String: Any]
            guard let value = t?["value"] as? String, let sig = t?["signature"] as? String else {
                throw err(vod != nil ? "Twitch didn't give access to that video. It may be deleted, private or subscriber-only."
                                     : "Twitch didn't give access to that channel.")
            }
            return (value, sig)
        }

        static func meta(_ query: String) async -> [String: Any] {
            ((try? await gql(["query": query]))?["data"] as? [String: Any]) ?? [:]
        }

        static func vod(_ id: String) async throws -> Source {
            let (value, sig) = try await token(vod: id, login: nil)
            var c = URLComponents(string: "https://usher.ttvnw.net/vod/\(id).m3u8")!
            c.queryItems = [.init(name: "nauth", value: value), .init(name: "nauthsig", value: sig),
                            .init(name: "allow_source", value: "true"), .init(name: "player", value: "twitchweb"),
                            .init(name: "allow_audio_only", value: "true"), .init(name: "p", value: String(Int.random(in: 100000...999999)))]
            let m = await meta("query { video(id: \"\(id)\") { title owner { displayName } } }")
            let v = m["video"] as? [String: Any]
            return Source(master: c.url!, title: v?["title"] as? String ?? "",
                          channel: (v?["owner"] as? [String: Any])?["displayName"] as? String ?? "", live: false, isTwitch: true,
                          vodID: id)
        }

        static func live(_ login: String) async throws -> Source {
            let (value, sig) = try await token(vod: nil, login: login)
            var c = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8")!
            c.queryItems = [.init(name: "token", value: value), .init(name: "sig", value: sig),
                            .init(name: "allow_source", value: "true"), .init(name: "fast_bread", value: "true"),
                            .init(name: "p", value: String(Int.random(in: 100000...999999)))]
            let m = await meta("query { user(login: \"\(login)\") { displayName broadcastSettings { title } } }")
            let u = m["user"] as? [String: Any]
            return Source(master: c.url!, title: (u?["broadcastSettings"] as? [String: Any])?["title"] as? String ?? "",
                          channel: u?["displayName"] as? String ?? login, live: true, isTwitch: true, login: login)
        }
    }

    enum Kick {
        static func vod(_ id: String) async throws -> Source {
            let j = try await KickAPI.json("/api/v1/video/\(id)")
            guard let src = j["source"] as? String, let url = URL(string: src) else {
                throw err("Kick didn't return that video. It may be deleted or private.")
            }
            let ls = j["livestream"] as? [String: Any]
            let user = ((ls?["channel"] as? [String: Any])?["user"] as? [String: Any])?["username"] as? String
            return Source(master: url, title: ls?["session_title"] as? String ?? "", channel: user ?? "", live: false, isTwitch: false)
        }

        static func live(_ slug: String) async throws -> Source {
            let j = try await KickAPI.json("/api/v2/channels/\(slug)")
            guard j["livestream"] is [String: Any], let src = j["playback_url"] as? String, let url = URL(string: src) else {
                throw err("\(slug) isn't live on Kick right now. For an old stream, open it under Videos and copy that link.")
            }
            let ls = j["livestream"] as? [String: Any]
            let user = (j["user"] as? [String: Any])?["username"] as? String
            let room = (j["chatroom"] as? [String: Any])?["id"] as? Int
            return Source(master: url, title: ls?["session_title"] as? String ?? "", channel: user ?? slug, live: true, isTwitch: false,
                          kickChatroom: room)
        }
    }

    // MARK: HLS

    struct Variant { let url: URL; let bandwidth: Int; let height: Int; let codecs: String }
    struct Segment { let url: URL; let duration: Double; let start: Double; var discontinuity = false }
    struct Media { var segments: [Segment]; var ended: Bool; var map: URL?; var target: Double }

    static func get(_ url: URL, retries: Int = 3) async throws -> Data {
        var last: Error = err("Download failed")
        for attempt in 0..<retries {
            do {
                var r = URLRequest(url: url)
                r.timeoutInterval = 30
                r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
                let (d, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
                if code == 200 { return d }
                last = NSError(domain: "HTTP", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
                if code == 403 || code == 404 { throw last }
            } catch let e as NSError where e.domain == "HTTP" {
                throw e
            } catch {
                last = error
            }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
        }
        throw last
    }

    private static func attrs(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return out }
        let s = line[line.index(after: colon)...]
        var key = "", val = "", inKey = true, quoted = false
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                out[key.trimmingCharacters(in: .whitespaces)] = val; key = ""; val = ""; inKey = true
            } else {
                val.append(ch)
            }
        }
        if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces)] = val }
        return out
    }

    static func variants(_ text: String, base: URL) -> [Variant] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [Variant] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
            let a = attrs(l)
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            let h = Int(a["RESOLUTION"]?.split(separator: "x").last ?? "") ?? 0
            out.append(Variant(url: url, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0, height: h, codecs: a["CODECS"] ?? ""))
        }
        return out
    }

    /// Twitch marks inserted ads with a title other than "live"; those segments are skipped.
    static func media(_ text: String, base: URL, skipAds: Bool) -> Media {
        var m = Media(segments: [], ended: false, map: nil, target: 6)
        var dur = 0.0, title = "", t = 0.0, disc = false
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#EXTINF:") {
                let v = l.dropFirst(8)
                let comma = v.firstIndex(of: ",")
                dur = Double(comma.map { v[..<$0] } ?? v) ?? 0
                title = comma.map { String(v[v.index(after: $0)...]) } ?? ""
            } else if l.hasPrefix("#EXT-X-TARGETDURATION:") {
                m.target = Double(l.dropFirst(22)) ?? 6
            } else if l.hasPrefix("#EXT-X-DISCONTINUITY") && !l.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                disc = true
            } else if l.hasPrefix("#EXT-X-ENDLIST") {
                m.ended = true
            } else if l.hasPrefix("#EXT-X-MAP") {
                if let uri = attrs(l)["URI"] { m.map = URL(string: uri, relativeTo: base)?.absoluteURL }
            } else if !l.isEmpty && !l.hasPrefix("#") {
                let ad = skipAds && !title.isEmpty && title != "live"
                if !ad, let u = URL(string: l, relativeTo: base)?.absoluteURL {
                    m.segments.append(Segment(url: u, duration: dur, start: t, discontinuity: disc))
                    disc = false
                } else if ad {
                    disc = true          // the content after an ad break continues on a new timeline
                }
                t += dur
                dur = 0; title = ""
            }
        }
        return m
    }

    private static func pick(_ vs: [Variant], maxHeight: Int) -> Variant? {
        let h264 = vs.filter { $0.codecs.isEmpty || $0.codecs.contains("avc1") }
        let usable = h264.filter { $0.height > 0 }
        if let best = usable.filter({ $0.height <= maxHeight }).max(by: { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }) {
            return best
        }
        return usable.min(by: { $0.height < $1.height }) ?? h264.first
    }

    /// Twitch VODs sometimes mute parts for music; the segment then lives under a "-muted" name.
    private static func segment(_ s: Segment, twitch: Bool) async throws -> Data {
        do {
            return try await get(s.url)
        } catch let e as NSError where twitch && (e.code == 403 || e.code == 404) {
            let name = s.url.lastPathComponent
            let alt = name.contains("-unmuted") ? name.replacingOccurrences(of: "-unmuted", with: "-muted")
                                                : name.replacingOccurrences(of: ".ts", with: "-muted.ts")
            return try await get(s.url.deletingLastPathComponent().appendingPathComponent(alt))
        }
    }

    // MARK: downloading

    /// Downloads the stream (or the asked-for part of it) into an MP4 on the phone.
    static func download(_ src: Source, options o: Options,
                         onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> Downloaded {
        await onStatus("Finding the stream", nil)
        let masterText = String(decoding: try await get(src.master), as: UTF8.self)
        var mediaURL = src.master
        let vs = variants(masterText, base: src.master)
        if !vs.isEmpty {
            guard let v = pick(vs, maxHeight: o.maxHeight) else { throw err("This stream has no H.264 video the phone can use.") }
            mediaURL = v.url
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString.prefix(8)).mp4")

        if src.live {
            let f = try await recordLive(mediaURL, minutes: o.liveMinutes, twitch: src.isTwitch, out: out, onStatus: onStatus)
            return Downloaded(file: f, offset: 0)
        }

        let pl = media(String(decoding: try await get(mediaURL), as: UTF8.self), base: mediaURL, skipAds: src.isTwitch)
        var segs = pl.segments
        if let from = o.from { segs = segs.filter { $0.start + $0.duration > from } }
        if let to = o.to { segs = segs.filter { $0.start < to } }
        guard !segs.isEmpty else { throw err("Nothing to download in that time range.") }
        let offset = segs[0].start

        let label = "Downloading on your phone"
        if let map = pl.map {
            // fragmented MP4 segments: the init segment plus the segments, back to back, is a valid MP4
            FileManager.default.createFile(atPath: out.path, contents: try await get(map))
            let h = try FileHandle(forWritingTo: out)
            defer { try? h.close() }
            try await fetchInOrder(segs, twitch: src.isTwitch) { n, data in
                try h.seekToEnd(); try h.write(contentsOf: data)
                await onStatus(label, Double(n + 1) / Double(segs.count))
            }
            await onStatus("Finishing the video", nil)
            return Downloaded(file: try await checked(await TSRemuxer.normalize(out)), offset: offset)
        }

        let remux = TSRemuxer(output: out)
        do {
            try await fetchInOrder(segs, twitch: src.isTwitch) { n, data in
                if segs[n].discontinuity && n > 0 { remux.discontinuity() }
                try remux.append(data)
                await onStatus(label, Double(n + 1) / Double(segs.count))
            }
            await onStatus("Finishing the video", nil)
            let raw = try await remux.finish()
            return Downloaded(file: try await checked(await TSRemuxer.normalize(raw)), offset: offset)
        } catch {
            remux.cancel()
            throw error
        }
    }

    /// Keeps 8 segment downloads running at all times (a new one starts as soon as any finishes) and hands
    /// them over strictly in order. The old version waited for the slowest of every 4, which was slow on Kick.
    private static func fetchInOrder(_ segs: [Segment], twitch: Bool, parallel: Int = 8,
                                     handle: (Int, Data) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: (Int, Data).self) { g in
            var next = 0, emit = 0
            var ready: [Int: Data] = [:]
            while next < min(parallel, segs.count) {
                let k = next, seg = segs[k]
                g.addTask { (k, try await StreamSources.segment(seg, twitch: twitch)) }
                next += 1
            }
            while let done = try await g.next() {
                try Task.checkCancellation()
                ready[done.0] = done.1
                while let d = ready.removeValue(forKey: emit) {
                    try await handle(emit, d)
                    emit += 1
                }
                if next < segs.count {
                    let k = next, seg = segs[k]
                    g.addTask { (k, try await StreamSources.segment(seg, twitch: twitch)) }
                    next += 1
                }
            }
        }
    }

    /// The editor can only work with a file AVFoundation can open; say so clearly instead of importing junk.
    private static func checked(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration).seconds) ?? 0
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard d > 1, !video.isEmpty else {
            throw err("The downloaded video couldn't be read. Try a shorter part, or a lower quality.")
        }
        return url
    }

    private static func recordLive(_ mediaURL: URL, minutes: Int, twitch: Bool, out: URL,
                                   onStatus: @escaping @MainActor (String, Double?) -> Void) async throws -> URL {
        let remux = TSRemuxer(output: out)
        var seen = Set<String>()
        var recorded = 0.0
        let goal = Double(minutes) * 60
        var first = true
        do {
            while recorded < goal {
                try Task.checkCancellation()
                let pl = media(String(decoding: try await get(mediaURL), as: UTF8.self), base: mediaURL, skipAds: twitch)
                if pl.map != nil { throw err("This live stream uses a format the phone recorder can't read yet.") }
                // start from the newest few segments, not the whole live window
                var fresh = pl.segments.filter { !seen.contains($0.url.absoluteString) }
                if first { fresh = Array(fresh.suffix(3)); first = false }
                for s in fresh {
                    seen.insert(s.url.absoluteString)
                    guard let d = try? await get(s.url) else { continue }
                    if s.discontinuity { remux.discontinuity() }
                    try remux.append(d)
                    recorded += s.duration
                    let left = max(0, goal - recorded)
                    await onStatus("Recording live · \(Int(left / 60)):\(String(format: "%02d", Int(left) % 60)) left", min(1, recorded / goal))
                    if recorded >= goal { break }
                }
                if pl.ended { break }
                if recorded < goal { try await Task.sleep(nanoseconds: UInt64(max(1, pl.target / 2) * 1_000_000_000)) }
            }
        } catch is CancellationError {
            // stopped early: keep what was recorded
        } catch {
            if recorded < 10 { remux.cancel(); throw error }
        }
        await onStatus("Finishing the video", nil)
        let raw = try await remux.finish()
        return try await checked(await TSRemuxer.normalize(raw))
    }
}

/// Kick's API sits behind Cloudflare, which often turns away plain app requests. If that happens, the request
/// is made from inside a hidden web view that has loaded kick.com, exactly as the site itself would.
@MainActor
enum KickAPI {
    private static var web: WKWebView?
    private static var ready = false

    static func json(_ path: String) async throws -> [String: Any] {
        if let j = try? await direct(path) { return j }
        return try await viaWeb(path)
    }

    private static func direct(_ path: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://kick.com" + path)!)
        r.setValue(StreamSources.browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 15
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw StreamSources.err("blocked") }
        return j
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done?.resume(); done = nil
        }
    }
    private static let loader = Loader()

    private static func viaWeb(_ path: String) async throws -> [String: Any] {
        if web == nil {
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            w.customUserAgent = StreamSources.browserUA
            w.navigationDelegate = loader
            web = w
        }
        guard let w = web else { throw StreamSources.err("Web view unavailable") }
        if !ready {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                loader.done = c
                w.load(URLRequest(url: URL(string: "https://kick.com/")!))
            }
            try await Task.sleep(nanoseconds: 2_500_000_000)   // let Cloudflare's check finish
            ready = true
        }
        for attempt in 0..<3 {
            let result = try? await w.callAsyncJavaScript(
                "const r = await fetch(p, {headers: {'Accept': 'application/json'}, credentials: 'include'}); return r.status + '\\n' + await r.text();",
                arguments: ["p": path], in: nil, contentWorld: .page)
            if let s = result as? String, let nl = s.firstIndex(of: "\n"), s[..<nl] == "200",
               let j = try? JSONSerialization.jsonObject(with: Data(s[s.index(after: nl)...].utf8)) as? [String: Any] {
                return j
            }
            if let s = result as? String, s.hasPrefix("404") {
                throw StreamSources.err("Kick says that video or channel doesn't exist.")
            }
            try await Task.sleep(nanoseconds: UInt64(attempt + 2) * 1_500_000_000)
        }
        throw StreamSources.err("Kick is blocking the request right now. Try again in a minute.")
    }
}
