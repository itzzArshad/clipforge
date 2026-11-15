import Foundation

/// Hindi (Devanagari) and Urdu script -> Roman letters the way people type Hinglish in chats:
/// चूना जो उसको -> "chuna jo usko", یار کیا ہے -> "yaar kya hai". Not a translation: the same words.
///
/// Ported from PeakCut's roman.py (MIT, https://github.com/haziqahmedqasmi/PeakCut), which is tested against
/// these spellings. Whisper often writes Hindi speech in Urdu script, so both scripts are handled.
enum Transliterator {

    static func isDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { isDev($0.value) }
    }

    /// True if the text is in a script captions should show in Roman letters instead.
    static func needsRoman(_ s: String) -> Bool {
        s.unicodeScalars.contains { isDev($0.value) || isUrdu($0.value) }
    }

    /// Kept for existing callers.
    static func hinglish(_ word: String) -> String { roman(word) }

    /// Every Hindi and Urdu run in the text spelled in Roman letters. Anything else is left exactly as it is.
    static func roman(_ text: String) -> String {
        guard needsRoman(text) else { return text }
        var out = ""
        var run = String.UnicodeScalarView()
        var runKind = 0          // 1 = Devanagari, 2 = Urdu
        func flush() {
            guard !run.isEmpty else { return }
            let s = String(run)
            out += runKind == 1 ? devWord(s) : urduWord(s)
            run.removeAll()
        }
        for sc in text.unicodeScalars {
            let v = sc.value
            let kind = isDev(v) ? 1 : (isUrdu(v) ? 2 : 0)
            if kind == 0 {
                flush()
                switch v {
                case 0x060C: out += ","          // Urdu comma
                case 0x061F: out += "?"          // Urdu question mark
                case 0x06D4: out += "."          // Urdu full stop
                default: out.unicodeScalars.append(sc)
                }
                runKind = 0
                continue
            }
            if kind != runKind { flush(); runKind = kind }
            run.append(sc)
        }
        flush()
        return out
    }

    private static func isDev(_ v: UInt32) -> Bool { (0x0900...0x097F).contains(v) }
    private static func isUrdu(_ v: UInt32) -> Bool {
        (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v) || (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
    }

    // MARK: Hindi

    private static let vowels: [String: String] = [
        "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ऋ": "ri", "ए": "e", "ऐ": "ai",
        "ओ": "o", "औ": "au", "ऑ": "o", "ऍ": "e"
    ]
    private static let signs: [String: String] = [
        "ा": "aa", "ि": "i", "ी": "ee", "ु": "u", "ू": "oo", "ृ": "ri", "े": "e", "ै": "ai", "ो": "o",
        "ौ": "au", "ॉ": "o", "ॅ": "e"
    ]
    private static let cons: [String: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n", "च": "ch", "छ": "chh", "ज": "j", "झ": "jh",
        "ञ": "n", "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n", "त": "t", "थ": "th", "द": "d", "ध": "dh",
        "न": "n", "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r", "ल": "l", "व": "v",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h", "ळ": "l",
        "\u{0958}": "q", "\u{0959}": "kh", "\u{095A}": "gh", "\u{095B}": "z", "\u{095E}": "f",
        "\u{095C}": "r", "\u{095D}": "rh", "\u{095F}": "y"
    ]
    private static let nuktaCons: [String: String] = [
        "क": "q", "ख": "kh", "ग": "gh", "ज": "z", "फ": "f", "ड": "r", "ढ": "rh", "य": "y"
    ]
    private static let virama = "्", nuktaSign = "़"
    private static let nasal: Set<String> = ["ं", "ँ"]
    private static let other: [String: String] = {
        var d: [String: String] = ["ः": "h", "।": ".", "॥": ".", "ॐ": "om"]
        for i in 0..<10 { d[String(UnicodeScalar(0x0966 + UInt32(i))!)] = String(i) }
        return d
    }()

    /// Common words whose everyday spelling the rules would not guess (PeakCut's list + gaming words).
    static let words: [String: String] = [
        "में": "mein", "मैं": "main", "हैं": "hain", "है": "hai", "नहीं": "nahi", "नही": "nahi", "हूँ": "hoon",
        "हूं": "hoon", "क्या": "kya", "क्यों": "kyun", "क्यूँ": "kyun", "क्यूं": "kyun", "यह": "ye", "ये": "ye", "वह": "wo",
        "वो": "wo", "और": "aur", "भी": "bhi", "ही": "hi", "की": "ki", "जी": "ji", "तो": "toh", "हाँ": "haan", "हां": "haan",
        "यहाँ": "yahan", "यहां": "yahan", "वहाँ": "wahan", "वहां": "wahan", "कहाँ": "kahan", "कहां": "kahan", "थी": "thi",
        "रही": "rahi", "कभी": "kabhi", "अभी": "abhi", "सभी": "sabhi", "भाई": "bhai", "मुझे": "mujhe",
        "तुम": "tum", "हम": "hum", "आप": "aap", "बहुत": "bahut", "अच्छा": "accha", "ठीक": "theek", "लिए": "liye",
        "अरे": "arre", "ओए": "oye", "अबे": "abey", "यार": "yaar", "वाह": "waah", "गेम": "game", "किल": "kill",
        "पुलिस": "police", "गाड़ी": "gaadi", "गाडी": "gaadi", "कैसे": "kaise", "कौन": "kaun", "गया": "gaya", "गई": "gayi",
        "गए": "gaye", "हाहा": "haha", "हाहाहा": "hahaha", "ओके": "okay", "ब्रो": "bro"
    ]

    private struct U {
        var r: String          // roman consonant or vowel
        var v: String?         // its vowel; nil = consonant with no vowel
        var isCons: Bool
        var inherent: Bool
        var nasal = false
    }

    private static func devWord(_ w: String) -> String {
        if let d = words[w] { return d }
        let ch = w.unicodeScalars.map { String($0) }
        var units: [U] = []
        var i = 0
        while i < ch.count {
            let c = ch[i]
            var nxt = i + 1 < ch.count ? ch[i + 1] : ""
            if var r = cons[c] {
                if nxt == nuktaSign {
                    r = nuktaCons[c] ?? r
                    i += 1
                    nxt = i + 1 < ch.count ? ch[i + 1] : ""
                }
                if nxt == virama { units.append(U(r: r, v: nil, isCons: true, inherent: false)); i += 2; continue }
                if let s = signs[nxt] { units.append(U(r: r, v: s, isCons: true, inherent: false)); i += 2; continue }
                units.append(U(r: r, v: "a", isCons: true, inherent: true))
            } else if let v = vowels[c] {
                units.append(U(r: "", v: v, isCons: false, inherent: false))
            } else if nasal.contains(c) {
                if !units.isEmpty {
                    units[units.count - 1].v = (units[units.count - 1].v ?? "") + "n"
                    units[units.count - 1].inherent = false
                    units[units.count - 1].nasal = true
                } else {
                    units.append(U(r: "n", v: nil, isCons: true, inherent: false))
                }
            } else if let o = other[c] {
                units.append(U(r: o, v: nil, isCons: false, inherent: false))
            } else if c == nuktaSign || c == virama {
                // stray mark
            } else {
                units.append(U(r: c, v: nil, isCons: false, inherent: false))
            }
            i += 1
        }
        // letters = units that are consonants or carry a vowel
        let letters = units.indices.filter { units[$0].isCons || !(units[$0].v ?? "").isEmpty }
        func vowelSet(_ k: Int) -> Bool { !(units[k].v ?? "").isEmpty }
        // Hindi drops the carried "a" at the end of a word, and between a vowel and another vowel-carrying letter
        // (कहना -> kahna, not kahana). Looked at right to left, as speakers do.
        if letters.count > 1, let last = letters.last, units[last].inherent { units[last].v = nil }
        if letters.count > 2 {
            for k in stride(from: letters.count - 2, through: 1, by: -1) {
                let u = letters[k], before = letters[k - 1], after = letters[k + 1]
                if units[u].inherent && vowelSet(before) && units[after].isCons && vowelSet(after) && !units[before].nasal {
                    units[u].v = nil
                }
            }
        }
        // Long vowels the way people type them: doubled only before a consonant that ends a syllable
        // (baat, kaam, aaj), single elsewhere (hamara, pata, ki, tu).
        let short = ["aa": "a", "ee": "i", "oo": "u"]
        for (k, u) in letters.enumerated() {
            if let v = units[u].v, let s = short[v] {
                let after = k + 1 < letters.count ? letters[k + 1] : nil
                if after == nil || vowelSet(after!) { units[u].v = s }
            }
        }
        return units.map { $0.r + ($0.v ?? "") }.joined()
    }

    // MARK: Urdu

    private static let urWords: [String: String] = [
        "ہے": "hai", "ہیں": "hain", "ہوں": "hoon", "ہو": "ho", "ہی": "hi", "یہ": "ye", "وہ": "wo", "کیا": "kya",
        "کیوں": "kyun", "نہیں": "nahi", "نہ": "na", "میں": "main", "میرا": "mera", "میری": "meri", "میرے": "mere",
        "تو": "to", "کہ": "ke", "کی": "ki", "کا": "ka", "کے": "ke", "کو": "ko", "سے": "se", "پر": "par",
        "اور": "aur", "بھی": "bhi", "تھا": "tha", "تھی": "thi", "تھے": "the", "گیا": "gaya", "گئی": "gayi",
        "رہا": "raha", "رہی": "rahi", "رہے": "rahe", "بہت": "bahut", "اچھا": "achha", "یار": "yaar", "بھائی": "bhai",
        "آپ": "aap", "ہم": "hum", "تم": "tum", "مجھے": "mujhe", "تمہیں": "tumhein", "اب": "ab", "کر": "kar",
        "کرو": "karo", "کرنا": "karna", "دیکھو": "dekho", "چلو": "chalo", "ابھی": "abhi", "کبھی": "kabhi",
        "جی": "ji", "ہاں": "haan", "نا": "na", "اللہ": "Allah", "ٹھیک": "theek", "پتا": "pata", "پتہ": "pata",
        "لیکن": "lekin", "پھر": "phir", "سب": "sab", "کچھ": "kuch", "کون": "kaun", "کہاں": "kahan", "یہاں": "yahan",
        "وہاں": "wahan", "ایک": "ek", "دو": "do", "اپنا": "apna", "اپنی": "apni", "لوگ": "log", "بات": "baat",
        "کام": "kaam", "دن": "din", "آج": "aaj", "کل": "kal", "بس": "bas", "شکریہ": "shukriya", "واہ": "wah",
        "گھر": "ghar", "ہوا": "hua", "ہوئی": "hui", "ہوئے": "hue", "اس": "us", "ان": "un", "جو": "jo", "جب": "jab",
        "تب": "tab", "مگر": "magar", "زندگی": "zindagi", "پیسے": "paise", "روپے": "rupay", "ارے": "arre",
        "مار": "maar", "بھاگ": "bhaag", "گاڑی": "gaadi", "پولیس": "police"
    ]
    private static let urCons: [Character: String] = [
        "ب": "b", "پ": "p", "ت": "t", "ٹ": "t", "ث": "s", "ج": "j", "چ": "ch", "ح": "h", "خ": "kh", "د": "d",
        "ڈ": "d", "ذ": "z", "ر": "r", "ڑ": "r", "ز": "z", "ژ": "zh", "س": "s", "ش": "sh", "ص": "s", "ض": "z",
        "ط": "t", "ظ": "z", "غ": "gh", "ف": "f", "ق": "q", "ک": "k", "ك": "k", "گ": "g", "ل": "l", "م": "m",
        "ن": "n", "ہ": "h", "ه": "h", "ة": "a", "ھ": "h"
    ]
    private static let urMarks: [UInt32: String] = [
        0x064E: "a", 0x0650: "i", 0x064F: "u", 0x0651: "", 0x0652: "", 0x064B: "an", 0x0670: "a"
    ]

    private static func urduWord(_ w: String) -> String {
        if let d = urWords[w] { return d }
        let sc = Array(w.unicodeScalars)
        var out: [String] = []
        var prevCons = false
        for i in 0..<sc.count {
            let v = sc[i].value
            let ch = Character(sc[i])
            let first = i == 0, last = i == sc.count - 1
            if let m = urMarks[v] { out.append(m); prevCons = false; continue }
            if (0x06F0...0x06F9).contains(v) { out.append(String(v - 0x06F0)); prevCons = false; continue }
            if (0x0660...0x0669).contains(v) { out.append(String(v - 0x0660)); prevCons = false; continue }
            if ch == "ھ" { out.append("h"); continue }                          // the "h" of bh, ph, kh, chh
            if ch == "ا" || ch == "آ" { out.append(ch == "آ" ? "aa" : "a"); prevCons = false; continue }
            if ch == "و" || ch == "ؤ" {
                if first || !prevCons { out.append("w"); prevCons = true } else { out.append("o"); prevCons = false }
                continue
            }
            if "یيئى".contains(ch) {
                if first {
                    out.append("y"); prevCons = true
                } else {
                    let nxt: Character? = i + 1 < sc.count ? Character(sc[i + 1]) : nil
                    let s = last ? "i" : (prevCons && !(nxt.map { "اآوؤ".contains($0) } ?? false) ? "ee" : "y")
                    out.append(s); prevCons = s == "y"
                }
                continue
            }
            if ch == "ے" { out.append("e"); prevCons = false; continue }
            if ch == "ں" { out.append("n"); continue }
            if ch == "ع" || ch == "ء" { continue }
            guard let c = urCons[ch] else { out.append(String(ch)); prevCons = false; continue }
            if (ch == "ہ" || ch == "ه") && last && prevCons { out.append("a"); prevCons = false; continue }
            if (prevCons && i == 1) || (prevCons && i == 2 && Character(sc[1]) == "ھ") { out.append("a") }
            out.append(c)
            prevCons = true
        }
        var s = out.joined()
        // no vowel at all: give it the one Urdu leaves out
        if s.count >= 2, s.allSatisfy({ $0.isASCII && $0.isLowercase }), !s.contains(where: { "aeiou".contains($0) }) {
            s = String(s.dropLast()) + "a" + String(s.last!)
        }
        return s
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
