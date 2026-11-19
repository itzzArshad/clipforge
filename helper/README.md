# ClipForge helper (optional, for YouTube links)

Twitch and Kick links download inside the app; you do not need this for them. YouTube blocks downloads from apps,
so for YouTube this small program downloads on your computer and the app pulls the finished video over your Wi-Fi.

1. Install Python 3.10+, then: `pip install -U yt-dlp`
2. Install ffmpeg and Deno (yt-dlp needs Deno for YouTube now). Windows:
   `winget install Gyan.FFmpeg` and `winget install DenoLand.Deno`
3. For parts of a YouTube stream that is **still live**: `winget install Kethsar.ytarchive` (v0.5.0 or newer)
4. Run: `python clipforge_helper.py`
5. It prints an **Address** and a **Key**. In ClipForge open Settings → Stream links and paste both.
6. In ClipForge tap **Paste a link**. Phone and computer must be on the same Wi-Fi; allow "Local Network" when iOS asks.

What to get (chosen in the app):
- **Best parts** (fastest): downloads only the audio and the chat replay, finds the 8 or so biggest moments
  (chat spikes, most-replayed graph, loud audio) and then downloads just ~90 s around each. A 10-hour stream
  becomes ~12 minutes of video. On a stream that is still live it grabs the last N minutes instead.
- **From–To**: only that part. On a finished video yt-dlp fetches just those bytes. On a stream that is still
  live, ytarchive fetches it (times from the start of the stream).
- **Last N min**: the last N minutes of a live stream (ytarchive).
- **Whole**: the full video, or for a live stream, record the next N minutes from now.
- If YouTube says "confirm you're not a bot", set `CLIPFORGE_COOKIES_FROM_BROWSER=chrome` (or edge / firefox) and restart.
- Files are kept in your temp folder for 12 hours.
- Only clip streams you have the rights or the creator's permission to use.
