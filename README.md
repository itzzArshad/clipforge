# ClipForge

Native SwiftUI app: import a long video, find loud/exciting moments, trim, cut silences, export 9:16 (1080x1920) to Photos.
Steps 1-3 of the plan (import + player/trim, 9:16 export, audio peak + silence detection). Transcription (WhisperKit) comes next.

## Build the IPA with no Mac
1. Create a GitHub repo and push this folder (public repos get free macOS minutes; private ones burn them ~10x faster).
2. Actions tab -> "Build unsigned IPA" -> Run workflow (it also runs on every push to main).
3. When it finishes, download the `ClipForge-unsigned-ipa` artifact and unzip it to get `ClipForge-unsigned.ipa`.

## Sign it with your cert
Set the bundle ID in `project.yml` (PRODUCT_BUNDLE_IDENTIFIER) to match your provisioning profile's App ID, push again, then sign:

    zsign -k cert.p12 -p <password> -m profile.mobileprovision -o ClipForge.ipa ClipForge-unsigned.ipa

or use Sideloadly / an on-device signer with the unsigned IPA.

## Notes
- Silence threshold is -40 dBFS (AudioAnalyzer.keepRanges). Game audio is rarely truly silent; tune it per stream.
- Imported videos are copied to the temp folder, so keep free storage for multi-GB streams.
