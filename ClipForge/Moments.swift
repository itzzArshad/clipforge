import Foundation

enum MomentStage: Equatable {
    case loud            // found from loudness / chat / replays, not listened to yet
    case listening       // transcription running
    case shaped          // transcribed + cut to sentence boundaries
    case ai              // picked/cut by Claude
}

struct Moment: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var peak: Double                 // loudest instant (source time)
    var loud: Float                  // 0...1, from audio energy
    var chat: Float? = nil           // 0...1, how hard the live chat reacted (Twitch/Kick)
    var heat: Float? = nil           // 0...1, YouTube "most replayed"
    var chatSample: [String] = []    // what chat was spamming
    var text: Float? = nil           // 0...1, from the transcript
    var ai: Float? = nil             // 0...1, from Claude
    var transcript: String = ""      // Hinglish, for display
    var title: String = ""           // short label for the card
    var hook: String = ""            // on-screen hook for the first seconds
    var reason: String = ""
    var category: String = ""
    var postTitle: String = ""          // for the upload, not the video
    var postText: String = ""           // description + hashtags, ready to paste
    var highlights: [String] = []       // words that carry the punch: drawn in the strong colour
    var stage: MomentStage = .loud
    var exported = false

    var duration: Double { end - start }

    /// Every signal that exists for this moment, averaged. Chat and "most replayed" are what real viewers did,
    /// so they count more than loudness. An AI score, when there is one, leads.
    var combined: Float {
        var sum = loud, weight: Float = 1
        if let chat { sum += 1.5 * chat; weight += 1.5 }
        if let heat { sum += 1.5 * heat; weight += 1.5 }
        if let text { sum += text; weight += 1 }
        let base = sum / weight
        if let ai { return 0.6 * ai + 0.4 * base }
        return base
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
        let hits = Double(tokens.filter { lexicon.contains($0) || lexicon.contains(Transliterator.hinglish($0)) }.count)
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

/// A sentence-ish chunk of speech, used to cut shorts at natural boundaries.
struct SpeechLine {
    var start: Double
    var end: Double
    var text: String
}

/// Turns a rough loud window into a proper short: starts on a sentence, gives the moment
/// a few seconds of setup before the peak, and ends after the reaction / payoff.
enum ShortShaper {
    static let minLength = 18.0
    static let maxLength = 58.0
    static let setup = 9.0       // seconds of context before the peak
    static let payoff = 6.0      // seconds after the peak

    static func lines(_ words: [RawWord], gap: Double = 0.6) -> [SpeechLine] {
        var out: [SpeechLine] = []
        var cur: [RawWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(SpeechLine(start: f.start, end: l.end,
                                  text: cur.map { Transliterator.hinglish($0.text) }.joined(separator: " ")))
            cur = []
        }
        for w in words {
            if let l = cur.last {
                let endsSentence = l.text.hasSuffix("।") || l.text.hasSuffix("?") || l.text.hasSuffix("!") || l.text.hasSuffix(".")
                if w.start - l.end > gap || endsSentence || cur.count >= 14 { flush() }
            }
            cur.append(w)
        }
        flush()
        return out
    }

    /// The moments a sentence finishes: a word ending in . ? ! । ؟, or (when the transcript has little
    /// punctuation) a pause in the talking. Ported from PeakCut's brain.sentence_ends.
    static func sentenceEnds(_ words: [RawWord]) -> [Double] {
        func ends(_ t: String) -> Bool {
            guard let c = t.last else { return false }
            return ".?!।؟".contains(c)
        }
        let punctuated = words.filter { ends($0.text) }.count >= max(2, words.count / 80)
        var out: [Double] = []
        for (i, w) in words.enumerated() {
            let gap = i + 1 < words.count ? words[i + 1].start - w.end : 9
            if (punctuated && ends(w.text)) || gap >= (punctuated ? 1.0 : 0.5) { out.append(w.end) }
        }
        return out
    }

    /// Start at the beginning of a line and end where a sentence ends, inside the allowed length. A clip that
    /// stops mid-sentence feels cut off, so the sentence being said at the chosen end is finished; if that would
    /// take too long, it ends at the sentence before. Ported from PeakCut's brain._snap.
    static func snap(start s0: Double, end e0: Double, words: [RawWord],
                     minLen: Double = ShortShaper.minLength, maxLen: Double = ShortShaper.maxLength, duration: Double) -> (Double, Double)? {
        guard s0 >= 0, e0 > s0 else { return nil }
        var s = s0, e = e0
        let ls = lines(words, gap: 0.7)
        let starts = ls.map(\.start).filter { abs($0 - s) <= 4 }
        if let best = starts.min(by: { abs($0 - s) < abs($1 - s) }) { s = best }
        let lo = s + minLen, hi = min(s + maxLen, duration)
        let stops = sentenceEnds(words).filter { $0 >= lo && $0 <= hi }
        if !stops.isEmpty {
            let after = stops.filter { $0 >= e - 1.0 }
            if let a = after.first, a - e <= 12 { e = a } else { e = stops.min(by: { abs($0 - e) < abs($1 - e) })! }
        } else {
            let ends = words.map(\.end).filter { $0 >= lo && $0 <= hi && abs($0 - e) <= 4 }
            if let best = ends.min(by: { abs($0 - e) < abs($1 - e) }) { e = best }
        }
        e = max(e, s + minLen)
        e = min(e, s + maxLen, duration)
        // a short breath after the last word, but never into the next sentence
        let next = words.first { $0.start > e - 0.01 }?.start
        let tail = next == nil ? 0.35 : min(0.35, max(0.08, next! - e - 0.05))
        return (max(0, s - 0.15), min(duration, e + tail))
    }

    /// Returns (start, end) in source time.
    static func shape(peak: Double, words: [RawWord], window: ClosedRange<Double>, duration: Double) -> (Double, Double) {
        let ls = lines(words)
        guard !ls.isEmpty else {
            let s = max(window.lowerBound, peak - setup)
            return (s, min(duration, max(s + minLength, peak + payoff)))
        }
        // start: the beginning of the line that contains (peak - setup), or the nearest line start before it
        let wantStart = peak - setup
        var start = ls.last(where: { $0.start <= wantStart })?.start ?? ls.first!.start
        if peak - start > 25 { start = ls.first(where: { $0.start >= peak - 25 })?.start ?? start }
        start = max(window.lowerBound, start - 0.25)

        // end: the end of the first line that finishes after (peak + payoff)
        let wantEnd = peak + payoff
        var end = ls.first(where: { $0.end >= wantEnd })?.end ?? ls.last!.end
        end += 0.6
        if end - start < minLength {
            end = ls.first(where: { $0.end >= start + minLength })?.end ?? (start + minLength)
            end += 0.6
        }
        if end - start > maxLength {
            end = ls.last(where: { $0.end <= start + maxLength })?.end ?? (start + maxLength)
            end += 0.4
        }
        return (max(0, start), min(duration, end))
    }
}
