import Foundation

/// Optional: ask Claude to rank transcript snippets and write a hook title for each.
/// Uses the user's own API key (stored on this phone). Only transcript text is sent, never video or audio.
enum ClaudeRanker {
    static let model = "claude-haiku-5-5"   // cheap and fast; swap for "claude-sonnet-5-5" for smarter picks

    struct Item { let index: Int; let score: Float; let hook: String }

    static func rank(candidates: [(Int, String)], apiKey: String, language: String) async throws -> [Item] {
        var list = ""
        for (i, t) in candidates { list += "[\(i)] \(t.prefix(900))\n\n" }
        let prompt = """
        You are an editor picking the most viral 30-60 second reels from a gaming livestream. The streamer speaks \(language) (often mixed with English).
        For each candidate transcript below, rate 1-10 how funny, shocking, hype or quotable it would be as a standalone reel, and write a punchy hook title (max 8 words) in the same language and script as the transcript. At most one emoji.
        Return ONLY a JSON array, no prose, like: [{"id":0,"score":8,"hook":"..."}]

        Candidates:
        \(list)
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "messages": [["role": "user", "content": prompt]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "API error: \(msg)"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"),
              let arr = try JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [[String: Any]]
        else { throw NSError(domain: "Claude", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read the reply"]) }

        return arr.compactMap { d in
            guard let id = (d["id"] as? Int) ?? (d["id"] as? Double).map(Int.init) else { return nil }
            let s = (d["score"] as? Double) ?? Double((d["score"] as? Int) ?? 0)
            return Item(index: id, score: Float(min(max(s, 0), 10) / 10), hook: (d["hook"] as? String) ?? "")
        }
    }
}
