import Foundation

/// A chat message, timed in seconds of the downloaded video.
struct ChatMessage: Equatable {
    var t: Double
    var text: String
}

/// Chat is the best free highlight signal there is: viewers spam the chat a few seconds after something good
/// happens, in every language. This is how most stream clippers find moments without AI (chat velocity, as in
/// the LIGHTOR paper and twitch-highlight-finder). Nothing here runs a model; it is counting.
enum ChatSignal {

    // MARK: Twitch VOD chat replay

    /// Chat replay of a Twitch VOD between two VOD offsets, using the same API the Twitch web player uses.
    /// Twitch can change or restrict this at any time; on failure it returns what it has (possibly nothing).
    static func twitchVOD(id: String, from: Double, to: Double?,
                          onProgress: @escaping @MainActor (Int) -> Void) async -> [ChatMessage] {
        var out: [ChatMessage] = []
        var cursor: String?
        var failures = 0
        var pages = 0
        while pages < 2500 && failures < 3 && !Task.isCancelled {
            var vars: [String: Any] = ["videoID": id]
            if let cursor { vars["cursor"] = cursor } else { vars["contentOffsetSeconds"] = Int(max(0, from)) }
            let body: [[String: Any]] = [[
                "operationName": "VideoCommentsByOffsetOrCursor",
                "variables": vars,
                "extensions": ["persistedQuery": ["version": 1,
                    "sha256Hash": "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"]]
            ]]
            guard let res = try? await post(body) else { failures += 1; continue }
            let comments = ((((res.first?["data"] as? [String: Any])?["video"] as? [String: Any])?["comments"]) as? [String: Any])
            guard let edges = comments?["edges"] as? [[String: Any]], !edges.isEmpty else { break }
            failures = 0
            pages += 1
            var last = 0.0
            for e in edges {
                guard let node = e["node"] as? [String: Any] else { continue }
                let t = (node["contentOffsetSeconds"] as? Double) ?? Double(node["contentOffsetSeconds"] as? Int ?? 0)
                last = t
                let frags = ((node["message"] as? [String: Any])?["fragments"] as? [[String: Any]]) ?? []
                let text = frags.compactMap { $0["text"] as? String }.joined()
                if t >= from { out.append(ChatMessage(t: t - from, text: String(text.prefix(120)))) }
            }
            await onProgress(out.count)
            if let to, last > to { break }
            let hasNext = ((comments?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool) ?? false
            guard hasNext, let c = edges.last?["cursor"] as? String else { break }
            cursor = c
        }
        if let to { out = out.filter { $0.t <= to - from } }
        return out
    }

    /// The whole chat of a long VOD, read in parallel slices (a 10-hour stream in a minute or two instead of ten).
    static func twitchVODAll(id: String, length: Double,
                             onProgress: @escaping @MainActor (Double) -> Void) async -> [ChatMessage] {
        let n = max(1, min(10, Int(length / 900) + 1))
        let step = length / Double(n)
        return await withTaskGroup(of: [ChatMessage].self) { g in
            for i in 0..<n {
                let a = Double(i) * step, b = a + step
                g.addTask {
                    await twitchVOD(id: id, from: a, to: b, onProgress: { _ in })
                        .map { ChatMessage(t: $0.t + a, text: $0.text) }
                }
            }
            var all: [ChatMessage] = []
            var done = 0
            for await part in g {
                all += part
                done += 1
                await onProgress(Double(done) / Double(n))
            }
            return all.sorted { $0.t < $1.t }
        }
    }

    private static func post(_ body: Any) async throws -> [[String: Any]] {
        var r = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(StreamSources.Twitch.clientID, forHTTPHeaderField: "Client-ID")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw StreamSources.err("chat") }
        return (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
    }

    // MARK: scoring

    /// Words and emotes that mean "that was funny / insane / clip it", across Hindi, English and Twitch emotes.
    static let hype: [String] = [
        "kekw", "lul", "lmao", "lmfao", "lol", "omegalul", "😂", "🤣", "💀", "pog", "pogchamp", "poggers", "pogu",
        "clip", "clip it", "w", "ww", "www", "+1", "omg", "wtf", "bruh", "insane", "holy", "no way", "lets go",
        "letsgo", "gg", "monkas", "pepelaugh", "icant", "ayo", "😭", "🔥", "😱",
        "haha", "hahaha", "bhai", "pagal", "op", "gajab", "kya", "mast", "bawal", "arre", "😳"
    ]

    /// Per-second chat score (0...1) for a video `duration` seconds long, already moved back in time to where
    /// the action was: chat reacts after it sees something, so the raw peak comes late.
    static func curve(_ msgs: [ChatMessage], duration: Double, lag: Double = 12) -> [Float] {
        let n = max(1, Int(duration.rounded(.up)))
        guard msgs.count >= 20 else { return [] }
        var raw = [Float](repeating: 0, count: n)
        for m in msgs {
            let i = Int(m.t - lag)
            guard i >= 0, i < n else { continue }
            let l = m.text.lowercased()
            let excited = hype.contains { l == $0 || l.contains($0) } || l.count <= 6
            raw[i] += excited ? 1.6 : 1
        }
        // 10 s moving sum (chat velocity), then compare with the channel's normal pace
        var vel = [Float](repeating: 0, count: n)
        var sum: Float = 0
        for i in 0..<n {
            sum += raw[i]
            if i >= 10 { sum -= raw[i - 10] }
            vel[i] = sum
        }
        let sorted = vel.sorted()
        let median = max(1, sorted[sorted.count / 2])
        let high = max(median * 2, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))])
        return vel.map { min(1, max(0, ($0 - median) / (high - median))) }
    }

    /// Peaks of a per-second curve: at least `gap` seconds apart, above `floor`, best first.
    static func peaks(_ c: [Float], floor: Float = 0.35, gap: Int = 60, count: Int = 15) -> [(Int, Float)] {
        guard c.count > 2 else { return [] }
        var cands: [(Int, Float)] = []
        for i in 1..<(c.count - 1) where c[i] >= floor && c[i] >= c[i - 1] && c[i] >= c[i + 1] {
            cands.append((i, c[i]))
        }
        var out: [(Int, Float)] = []
        for p in cands.sorted(by: { $0.1 > $1.1 }) where out.count < count {
            if out.contains(where: { abs($0.0 - p.0) < gap }) { continue }
            out.append(p)
        }
        return out
    }

    /// A few of the most typical messages around a moment, for the card and for an AI prompt.
    static func sample(_ msgs: [ChatMessage], around t: Double, before: Double = 5, after: Double = 30, limit: Int = 20) -> [String] {
        let near = msgs.filter { $0.t >= t - before && $0.t <= t + after }
        var counts: [String: Int] = [:]
        for m in near {
            let k = m.text.trimmingCharacters(in: .whitespaces)
            if k.isEmpty || k.count > 80 { continue }
            counts[k, default: 0] += 1
        }
        return counts.sorted { $0.value == $1.value ? $0.key.count < $1.key.count : $0.value > $1.value }
            .prefix(limit).map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
    }
}

// MARK: live chat while recording

/// Listens to a live chat while a stream is recorded. Twitch: anonymous read-only IRC. Kick: its public
/// Pusher feed (best effort; Kick can change it). Times are seconds since `start()`.
final class LiveChatRecorder: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var started = Date()
    private let lock = NSLock()
    private var msgs: [ChatMessage] = []
    private var running = false

    var messages: [ChatMessage] { lock.lock(); defer { lock.unlock() }; return msgs }

    func startTwitch(_ login: String) {
        let t = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        begin(t)
        for line in ["PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10000...99999))", "JOIN #\(login.lowercased())"] {
            t.send(.string(line)) { _ in }
        }
        receive { [weak self] text in
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("PING") { self?.task?.send(.string("PONG :tmi.twitch.tv")) { _ in }; continue }
                if let r = line.range(of: " PRIVMSG #"), let colon = line[r.upperBound...].firstIndex(of: ":") {
                    self?.add(String(line[line.index(after: colon)...]))
                }
            }
        }
    }

    func startKick(chatroom: Int) {
        let url = URL(string: "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false")!
        let t = URLSession.shared.webSocketTask(with: url)
        begin(t)
        let sub = #"{"event":"pusher:subscribe","data":{"auth":"","channel":"chatrooms.\#(chatroom).v2"}}"#
        t.send(.string(sub)) { _ in }
        receive { [weak self] text in
            guard let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let event = j["event"] as? String ?? ""
            if event == "pusher:ping" { self?.task?.send(.string(#"{"event":"pusher:pong","data":{}}"#)) { _ in }; return }
            guard event.hasSuffix("ChatMessageEvent"), let inner = j["data"] as? String,
                  let id = inner.data(using: .utf8), let m = try? JSONSerialization.jsonObject(with: id) as? [String: Any],
                  let content = m["content"] as? String else { return }
            // Kick sends emotes as [emote:123:Name]; keep the name
            let clean = content.replacingOccurrences(of: #"\[emote:\d+:([^\]]+)\]"#, with: "$1", options: .regularExpression)
            self?.add(clean)
        }
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func begin(_ t: URLSessionWebSocketTask) {
        task = t
        started = Date()
        lock.lock(); running = true; msgs = []; lock.unlock()
        t.resume()
    }

    private func add(_ text: String) {
        let m = ChatMessage(t: Date().timeIntervalSince(started), text: String(text.prefix(120)))
        lock.lock(); msgs.append(m); lock.unlock()
    }

    private func receive(_ handle: @escaping (String) -> Void) {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock(); let on = self.running; self.lock.unlock()
            guard on else { return }
            if case .success(let msg) = result {
                switch msg {
                case .string(let s): handle(s)
                case .data(let d): handle(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                self.receive(handle)
            }
        }
    }
}
