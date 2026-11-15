import Foundation
import WhisperKit

struct RawWord {
    var text: String
    var start: Double
    var end: Double
    var fixed = false      // typed or corrected by the user/AI: shown as-is, never transliterated
}

/// On-device Whisper via WhisperKit (Core ML). First use downloads the model from Hugging Face.
actor Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    func words(samples: [Float], model: String, language: String, offset: Double = 0) async throws -> [RawWord] {
        guard !samples.isEmpty else { return [] }
        if pipe == nil || loadedModel != model {
            pipe = try await WhisperKit(WhisperKitConfig(model: model))
            loadedModel = model
        }
        guard let pipe else { return [] }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var out: [RawWord] = []
        for r in results {
            for seg in r.segments {
                for w in seg.words ?? [] {
                    let t = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    out.append(RawWord(text: t, start: Double(w.start) + offset, end: Double(w.end) + offset))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
