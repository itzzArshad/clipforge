# ClipForge helper (Kick, Twitch, YouTube links)

The iPhone app cannot download stream links by itself, so this small program does it on your computer and the app
pulls the finished video over your Wi-Fi.

1. Install Python 3.10+, then: `pip install -U yt-dlp`
2. Install ffmpeg. Windows: `winget install Gyan.FFmpeg`
3. Run: `python clipforge_helper.py`
4. It prints an **Address** and a **Key**. In ClipForge open Settings → Stream links and paste both.
5. In ClipForge tap **Paste a link**. Phone and computer must be on the same Wi-Fi; allow "Local Network" when iOS asks.

- VODs and normal videos download fully (up to 1080p, H.264). Live streams are recorded from now for the minutes you choose.
- If YouTube says "confirm you're not a bot", set `CLIPFORGE_COOKIES_FROM_BROWSER=chrome` (or edge / firefox) and restart.
- Files are kept in your temp folder for 12 hours.
- Only clip streams you have the rights or the creator's permission to use.
