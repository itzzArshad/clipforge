import Foundation

/// Devanagari -> Hinglish (the way people actually type Hindi in Roman letters).
/// Rule based: consonant/vowel tables, nukta, inherent-"a" deletion, plus a dictionary of
/// very common words so they come out the way viewers expect ("nahi", "hai", "kya", "yaar").
enum Transliterator {

    static func isDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// Transliterates a whole caption word, keeping leading/trailing punctuation.
    static func hinglish(_ word: String) -> String {
        guard isDevanagari(word) else { return word }
        let scalars = Array(word.unicodeScalars)
        var lead = "", trail = ""
        var a = 0, b = scalars.count
        while a < b, !(0x0900...0x097F).contains(scalars[a].value), !CharacterSet.alphanumerics.contains(scalars[a]) {
            lead.unicodeScalars.append(scalars[a]); a += 1
        }
        while b > a, !(0x0900...0x097F).contains(scalars[b - 1].value), !CharacterSet.alphanumerics.contains(scalars[b - 1]) {
            trail = String(scalars[b - 1]) + trail; b -= 1
        }
        let core = String(String.UnicodeScalarView(scalars[a..<b]))
        let mapped = dictionary[core] ?? convert(core)
        let t = trail.replacingOccurrences(of: "।", with: ".").replacingOccurrences(of: "॥", with: ".")
        return lead + mapped + t
    }

    // MARK: common words

    static let dictionary: [String: String] = [
        "है": "hai", "हैं": "hain", "हे": "he", "नहीं": "nahi", "नही": "nahi", "ना": "na", "न": "na",
        "क्या": "kya", "क्यों": "kyun", "क्यूँ": "kyun", "क्यूं": "kyun", "कैसे": "kaise", "कहाँ": "kahan", "कहां": "kahan",
        "कब": "kab", "कौन": "kaun", "मैं": "main", "में": "mein", "मे": "me", "तो": "toh", "हाँ": "haan", "हां": "haan",
        "यार": "yaar", "भाई": "bhai", "भाइयों": "bhaiyon", "कुछ": "kuch", "बहुत": "bahut", "अच्छा": "accha", "ठीक": "theek",
        "चलो": "chalo", "चल": "chal", "और": "aur", "यह": "ye", "ये": "ye", "वह": "wo", "वो": "wo", "अभी": "abhi", "भी": "bhi",
        "हूँ": "hoon", "हूं": "hoon", "था": "tha", "थी": "thi", "थे": "the", "गया": "gaya", "गई": "gayi", "गए": "gaye",
        "एक": "ek", "के": "ke", "का": "ka", "की": "ki", "को": "ko", "से": "se", "पे": "pe", "पर": "par", "मत": "mat",
        "हो": "ho", "अरे": "arre", "ओए": "oye", "अबे": "abey", "मार": "maar", "भाग": "bhaag", "बच": "bach", "देख": "dekh",
        "देखो": "dekho", "लो": "lo", "दो": "do", "जा": "ja", "आ": "aa", "आजा": "aaja", "रुको": "ruko", "रुक": "ruk",
        "बोल": "bol", "बोलो": "bolo", "सब": "sab", "अपना": "apna", "अपने": "apne", "मेरा": "mera", "मेरी": "meri",
        "मेरे": "mere", "तेरा": "tera", "तेरी": "teri", "तुम": "tum", "तू": "tu", "आप": "aap", "हम": "hum", "पागल": "pagal",
        "वाह": "waah", "बस": "bas", "फिर": "phir", "लेकिन": "lekin", "मतलब": "matlab", "सच": "sach", "पता": "pata",
        "गेम": "game", "किल": "kill", "बंदा": "banda", "बंदे": "bande", "कर": "kar", "करो": "karo", "किया": "kiya",
        "करना": "karna", "रहा": "raha", "रही": "rahi", "रहे": "rahe", "सकता": "sakta", "जल्दी": "jaldi", "पैसे": "paise",
        "गाड़ी": "gaadi", "पुलिस": "police", "ओह": "oh", "हाहा": "haha", "हाहाहा": "hahaha"
    ]

    // MARK: tables

    private static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091A: "ch", 0x091B: "chh", 0x091C: "j", 0x091D: "jh", 0x091E: "n",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0932: "l", 0x0935: "v",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        0x0958: "q", 0x0959: "kh", 0x095A: "gh", 0x095B: "z", 0x095C: "d", 0x095D: "dh", 0x095E: "f", 0x095F: "y"
    ]
    private static let nukta: [UInt32: String] = [
        0x0915: "q", 0x0916: "kh", 0x0917: "gh", 0x091C: "z", 0x0921: "d", 0x0922: "dh", 0x092B: "f"
    ]
    private static let independent: [UInt32: String] = [
        0x0905: "a", 0x0906: "aa", 0x0907: "i", 0x0908: "ee", 0x0909: "u", 0x090A: "oo", 0x090B: "ri",
        0x090F: "e", 0x0910: "ai", 0x0911: "o", 0x0913: "o", 0x0914: "au"
    ]
    private static let matras: [UInt32: String] = [
        0x093E: "aa", 0x093F: "i", 0x0940: "ee", 0x0941: "u", 0x0942: "oo", 0x0943: "ri",
        0x0947: "e", 0x0948: "ai", 0x0949: "o", 0x094B: "o", 0x094C: "au"
    ]
    private static let virama: UInt32 = 0x094D
    private static let nuktaMark: UInt32 = 0x093C
    private static let anusvara: UInt32 = 0x0902
    private static let chandrabindu: UInt32 = 0x0901
    private static let visarga: UInt32 = 0x0903

    private struct Unit {
        var cons: String          // consonant cluster ("" for a bare vowel)
        var vowel: String         // "a" when inherent
        var inherent: Bool
        var nasal = false
        var dropped = false
    }

    private static func convert(_ word: String) -> String {
        var units: [Unit] = []
        var pendingCluster = ""
        var lastConsCode: UInt32?

        for s in word.unicodeScalars {
            let v = s.value
            if let c = consonants[v] {
                pendingCluster += c
                lastConsCode = v
                units.append(Unit(cons: pendingCluster, vowel: "a", inherent: true))
                pendingCluster = ""
            } else if v == nuktaMark, let lc = lastConsCode, let n = nukta[lc], !units.isEmpty {
                let base = consonants[lc] ?? ""
                var u = units.removeLast()
                if u.cons.hasSuffix(base) { u.cons = String(u.cons.dropLast(base.count)) + n }
                units.append(u)
            } else if v == virama, !units.isEmpty {
                // consonant joins the next one as a cluster
                let u = units.removeLast()
                pendingCluster = u.cons
            } else if let m = matras[v], !units.isEmpty {
                units[units.count - 1].vowel = m
                units[units.count - 1].inherent = false
            } else if let iv = independent[v] {
                if !pendingCluster.isEmpty { units.append(Unit(cons: pendingCluster, vowel: "", inherent: false)); pendingCluster = "" }
                units.append(Unit(cons: "", vowel: iv, inherent: false))
                lastConsCode = nil
            } else if v == anusvara || v == chandrabindu, !units.isEmpty {
                units[units.count - 1].nasal = true
                if units[units.count - 1].inherent { units[units.count - 1].inherent = false }
            } else if v == visarga {
                if !units.isEmpty { units[units.count - 1].vowel += "h" }
            } else if (0x0966...0x096F).contains(v) {
                units.append(Unit(cons: String(v - 0x0966), vowel: "", inherent: false))
            }
        }
        if !pendingCluster.isEmpty { units.append(Unit(cons: pendingCluster, vowel: "", inherent: false)) }
        guard !units.isEmpty else { return word }

        // inherent "a" deletion: drop at word end, and medially (right to left) when the next syllable keeps its vowel
        let last = units.count - 1
        if units[last].inherent && units.count > 1 { units[last].dropped = true }
        if units.count > 2 {
            var i = last - 1
            while i >= 1 {
                let next = units[i + 1]
                let nextKeeps = !next.dropped && !next.vowel.isEmpty
                if units[i].inherent && nextKeeps {
                    units[i].dropped = true
                    i -= 2   // never drop two in a row
                    continue
                }
                i -= 1
            }
        }

        var out = ""
        for (i, u) in units.enumerated() {
            var cons = u.cons
            var vowel = u.dropped ? "" : u.vowel
            let isLast = i == last
            // v -> w before back vowels ("wo", "wala", "waah")
            if cons == "v", ["aa", "o", "au", "e"].contains(vowel) || (vowel == "a" && i == 0) { cons = "w" }
            if isLast {
                if vowel == "aa" { vowel = "a" }
                if vowel == "ee" { vowel = "i" }
                if vowel == "oo" { vowel = u.nasal ? "oon" : "u" }
            } else if vowel == "aa", let n = units[safe: i + 1], n.cons.isEmpty, !n.vowel.isEmpty {
                vowel = "a"   // "bhaai" -> "bhai"
            }
            // a bare "e" after another vowel is written with a y: "gae" -> "gaye"
            if cons.isEmpty, i > 0, !(units[i - 1].dropped), !units[i - 1].vowel.isEmpty, vowel == "e" {
                cons = "y"
            }
            out += cons + vowel
            if u.nasal {
                let finalEe = isLast && u.vowel == "ee"
                let alreadyN = vowel.hasSuffix("n")
                if !finalEe && !alreadyN {
                    let nextCons = units[safe: i + 1]?.cons ?? ""
                    out += (nextCons.hasPrefix("p") || nextCons.hasPrefix("b") || nextCons.hasPrefix("m")) ? "m" : "n"
                }
            }
        }
        return out
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
