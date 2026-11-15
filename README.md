# ClipForge v0.3

Editor-style short-form maker for iPhone.

- Live 9:16 preview: layout, background, captions and effects update instantly
- Layouts: Fit (full frame in a rounded card) with Aura / Blur / Black backgrounds, or Fill (crop with pan)
- Moment finding, two ways + a mix:
  - Loud: loudest windows (language independent, runs on the whole file)
  - Speech: transcribes the top loud windows with Whisper and scores the text (excitement words, speech rate, repeats, "!" "?", laughter)
  - Best: blend of both; optional Claude "AI rank" with a hook title per moment
- Captions: Pill / Pop / Clean styles, per-script fonts (Devanagari, Telugu, Tamil, ...), word-by-word highlight, shouted words turn hot red
- Hype mode: punch-in zoom on shouts, live hype meter, hook sticker for the first 2.5 s
- Liquid Glass UI (iOS 26, built with Xcode 26 on the macos-26 runner)

## Build
Push to GitHub -> Actions -> "Build unsigned IPA" -> download artifact -> sign with Feather.

## Notes
- Captions / speech analysis download a Whisper model on first use (internet needed).
- AI rank needs your own Anthropic API key (Settings). Only transcript text is sent.
- Silence threshold: -40 dBFS in AudioAnalyzer.keepRanges. Excitement words: TextScorer.lexicon in Moments.swift.
