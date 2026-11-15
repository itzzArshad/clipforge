import Foundation
import WhisperKit

struct RawWord {
    let text: String
    let start: Double
    let end: Double
}

/// On-device Whisper via WhisperKit (Core ML). First use downloads the model from Hugging Face.
final class Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    func words(samples: [Float], model: String, language: String) async throws -> [RawWord] {
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
                    out.append(RawWord(text: t, start: Double(w.start), end: Double(w.end)))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
