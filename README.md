# ClipForge v0.2

Long video -> vertical reel, on the phone.

- Finds loud/hype moments (language independent), trim, cut silences
- Layouts: **Fit + blur** (full frame, nothing cropped, blurred fill behind) or **Fill** (crop with pan)
- Captions: WhisperKit (on-device) with word timestamps, Hindi + other Indian languages
- Signature look ("Hype mode"): captions react to how loud each word is (loud words get bigger and hot-coloured, the active word pops),
  punch-in zoom on shouts, and a live hype meter bar driven by the streamer's audio, plus an optional hook line

## Build
Push to GitHub (public repo = free macOS minutes) -> Actions -> "Build unsigned IPA" -> download artifact -> sign with Feather.
Set PRODUCT_BUNDLE_IDENTIFIER in project.yml to match your profile if needed.

## Notes
- First caption run downloads the Whisper model from Hugging Face (needs internet). "small" is fast; the accurate model is much better on Hinglish but slower and warmer.
- First load of a model compiles it for the Neural Engine and can take a minute or more. Later runs are faster.
- Silence threshold is -40 dBFS in AudioAnalyzer.keepRanges.
