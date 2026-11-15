import Foundation

struct Moment: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var loud: Float            // 0...1, from audio energy
    var text: Float? = nil     // 0...1, from the transcript (nil = not analysed yet)
    var transcript: String = ""
    var hook: String = ""
    var ai: Float? = nil       // 0...1, from Claude

    var combined: Float {
        if let ai { return 0.6 * ai + 0.2 * loud + 0.2 * (text ?? 0) }
        if let text { return 0.5 * loud + 0.5 * text }
        return loud
    }
}

/// Scores how "crazy" a stretch of speech is, using signals that work across Indian languages.
enum TextScorer {
    // Excitement words (Devanagari + Roman Hinglish + common gaming English). Edit freely.
    static let lexicon: Set<String> = [
        "अरे", "ओए", "अबे", "क्या", "गया", "गई", "मार", "मारो", "मर", "भाग", "भागो", "भाई", "यार",
        "पागल", "वाह", "कमाल", "जबरदस्त", "खतरनाक", "धमाका", "नहीं", "रुको", "रुक", "देख", "देखो",
        "चलो", "जल्दी", "बचो", "बच", "ओह", "बाप", "क्लच", "हेडशॉट", "किल", "जीत", "जीता", "हार", "हारा",
        "arre", "arey", "oye", "abe", "abey", "kya", "gaya", "gayi", "mar", "maar", "maro", "bhaag", "bhag",
        "bhai", "bhaiya", "yaar", "pagal", "wah", "waah", "wow", "omg", "kamaal", "zabardast", "khatarnak",
        "dhamaka", "bapre", "nahi", "nahin", "ruko", "dekho", "chalo", "jaldi", "bacho", "gg", "insane",
        "crazy", "clutch", "headshot", "kill", "dead", "bro", "dude", "bruh", "damn", "noooo"
    ]
    static let laughter: [String] = ["haha", "hehe", "हाहा", "हा हा", "😂", "🤣"]

    static func score(words: [RawWord], duration: Double) -> Float {
        guard words.count >= 3, duration > 1 else { return 0 }
        let tokens = words.map {
            $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        }
        let n = Double(tokens.count)
        let hits = Double(tokens.filter { lexicon.contains($0) }.count)
        var repeats = 0.0
        for i in 1..<tokens.count where tokens[i] == tokens[i - 1] && !tokens[i].isEmpty { repeats += 1 }
        let raw = words.map(\.text).joined(separator: " ")
        let punct = Double(raw.filter { $0 == "!" || $0 == "?" }.count)
        let laugh = laughter.contains { raw.lowercased().contains($0) } ? 0.15 : 0

        let lex = min(hits / n * 6, 1)
        let rate = min((n / duration) / 3.5, 1)
        let rep = min(repeats / n * 5, 1)
        let pun = min(punct / n * 4, 1)
        return Float(min(0.35 * lex + 0.25 * rate + 0.2 * rep + 0.2 * pun + laugh, 1))
    }
}
