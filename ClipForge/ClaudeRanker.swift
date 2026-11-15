import Foundation

/// Optional Claude features. Uses the user's own API key (stored on this phone).
/// Only transcript text is sent (already romanised to Hinglish, which is also far fewer tokens
/// than Devanagari), never video or audio.
enum ClaudeRanker {
    static let model = "claude-haiku-5-5"   // cheap and fast; "claude-sonnet-5-5" is smarter but ~20x the price

    struct Pick {
        let id: Int
        let start: Double
        let end: Double
        let score: Float
        let title: String
        let hook: String
        let reason: String
    }

    struct Candidate {
        let id: Int
        let peak: Double
        let lines: [SpeechLine]
    }

    // MARK: picking shorts with context

    static func pickShorts(_ candidates: [Candidate], apiKey: String, language: String) async throws -> [Pick] {
        var body = ""
        for c in candidates {
            body += "### Candidate \(c.id) (loudest moment at \(fmt(c.peak))s)\n"
            for l in c.lines { body += "[\(fmt(l.start))-\(fmt(l.end))] \(l.text)\n" }
            body += "\n"
        }
        let prompt = """
        You are the editor of a big Indian gaming Shorts/Reels page. Below are transcripts (romanised \(language), often Hinglish) of candidate moments from a long livestream, with timestamps in seconds of the source video.

        For EACH candidate, decide how to cut it into one standalone vertical short that works for a viewer who has not seen the stream:
        - start where the situation is set up (a line that gives context or starts the action), never mid-sentence
        - end right after the payoff / reaction lands, never mid-sentence; no dead air at the end
        - 15 to 60 seconds long; shorter is better if the story is complete
        - start and end must be inside the given timestamps
        Then rate it 1-10 for how likely it is to hold attention to the end and get shared (funny, shocking, clutch, rage, wholesome).
        Write a "title" (2-5 words, for the editor) and a "hook": the on-screen text for the first 2 seconds that makes people stay, in natural Hinglish (Roman script), max 7 words, at most one emoji. Never reveal the payoff in the hook.
        "reason": one short sentence on what happens.

        Return ONLY a JSON array, no prose:
        [{"id":0,"start":12.3,"end":48.0,"score":8,"title":"...","hook":"...","reason":"..."}]

        \(body)
        """
        let text = try await send(prompt: prompt, apiKey: apiKey, maxTokens: 3000)
        guard let arr = jsonArray(text) as? [[String: Any]] else { throw err("Could not read Claude's reply") }
        return arr.compactMap { d in
            guard let id = int(d["id"]), let s = double(d["start"]), let e = double(d["end"]), e > s else { return nil }
            let score = Float(min(max(double(d["score"]) ?? 0, 0), 10) / 10)
            return Pick(id: id, start: s, end: e, score: score,
                        title: d["title"] as? String ?? "", hook: d["hook"] as? String ?? "",
                        reason: d["reason"] as? String ?? "")
        }
    }

    // MARK: Hinglish caption cleanup

    /// Returns one Hinglish word per input word (same count), or nil if Claude did not keep the count.
    static func hinglishCaptions(_ words: [String], apiKey: String) async throws -> [String]? {
        guard !words.isEmpty else { return [] }
        let numbered = words.enumerated().map { "\($0.offset)\t\($0.element)" }.joined(separator: "\n")
        let prompt = """
        These are speech-recognition words (in order) from a Hindi/Hinglish gaming stream, one per line with an index. Some are in Devanagari, some may be misheard.
        Rewrite EACH word as natural Hinglish in Roman script, the way Indian creators type captions (e.g. "kya", "nahi", "bhai", "yaar", "gaadi", "maar"). Keep English words in English. Fix obvious mishearings only when you are confident from context. Keep the same number of words: exactly one output word per input index.
        Return ONLY a JSON array of \(words.count) strings.

        \(numbered)
        """
        let text = try await send(prompt: prompt, apiKey: apiKey, maxTokens: max(500, words.count * 8))
        guard let arr = jsonArray(text) as? [Any] else { return nil }
        let out = arr.map { ($0 as? String) ?? "" }
        return out.count == words.count ? out : nil
    }

    // MARK: plumbing

    private static func send(prompt: String, apiKey: String, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw err("API error: \(msg)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw err("Empty reply") }
        return text
    }

    private static func jsonArray(_ text: String) -> Any? {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8))
    }

    private static func fmt(_ t: Double) -> String { String(format: "%.1f", t) }
    private static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map { Int($0) } }
    private static func double(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
    private static func err(_ m: String) -> NSError {
        NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
