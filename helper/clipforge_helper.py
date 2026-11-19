"""ClipForge helper: downloads Kick, Twitch and YouTube links for the ClipForge iPhone app.

An iPhone app cannot run yt-dlp, so this small server does it on your own computer and the app pulls the finished
video over your Wi-Fi. The download approach (yt-dlp, H.264 up to 1080p, YouTube "not a bot" handling, a fixed list
of allowed sites) follows PeakCut's media.py (MIT, https://github.com/haziqahmedqasmi/PeakCut).

Run it:
    pip install -U yt-dlp
    (install ffmpeg: on Windows `winget install Gyan.FFmpeg`)
    python clipforge_helper.py

It prints an address and a key. Put both into ClipForge > Settings > Stream links.
Only download streams you have the rights or the creator's permission to clip.
"""
import json
import sys
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PORT = int(os.environ.get("CLIPFORGE_PORT", "8790"))
DATA = Path(os.environ.get("CLIPFORGE_DATA", Path(tempfile.gettempdir()) / "clipforge-helper"))
KEY_FILE = DATA / "key.txt"
ALLOWED = ("youtube.com", "youtu.be", "twitch.tv", "kick.com")
MAX_HEIGHT = int(os.environ.get("CLIPFORGE_MAX_HEIGHT", "1080"))
COOKIES_FROM = os.environ.get("CLIPFORGE_COOKIES_FROM_BROWSER", "")   # e.g. "chrome" if YouTube asks to sign in
KEEP_HOURS = 12

DATA.mkdir(parents=True, exist_ok=True)
KEY = KEY_FILE.read_text().strip() if KEY_FILE.exists() else secrets.token_urlsafe(9)
KEY_FILE.write_text(KEY)

jobs: dict = {}
lock = threading.Lock()


def site_allowed(url: str) -> bool:
    try:
        u = urlparse(url.strip())
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme in ("http", "https") and any(host == s or host.endswith("." + s) for s in ALLOWED)


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def update(jid, **kw):
    with lock:
        jobs[jid].update(kw)


class Stop(Exception):
    pass


def ydl_opts(extra):
    opts = {"noplaylist": True, "quiet": True, "no_warnings": True, "socket_timeout": 20,
            "concurrent_fragment_downloads": 4}
    if COOKIES_FROM:
        opts["cookiesfrombrowser"] = (COOKIES_FROM,)
    opts.update(extra)
    return opts


def explain(err) -> str:
    s = str(err)
    if "not a bot" in s.lower() or "sign in to confirm" in s.lower():
        return ("YouTube is refusing downloads from this computer right now. Try again in a few minutes, or set "
                "CLIPFORGE_COOKIES_FROM_BROWSER=chrome (or edge/firefox) and restart the helper.")
    if "ffmpeg" in s.lower():
        return "ffmpeg is missing. Install it (Windows: winget install Gyan.FFmpeg) and restart the helper."
    return s[-400:]


def hms(sec: float) -> str:
    sec = int(round(sec))
    sign = "-" if sec < 0 else ""
    sec = abs(sec)
    return f"{sign}{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def ytarchive_range(jid, url, work, start, length, height):
    """Part of a YouTube stream that is STILL LIVE, using ytarchive (yt-dlp can't do a range of a live).

    start: seconds into the stream, or negative = that many seconds before now. length: seconds to capture.
    Install once: winget install Kethsar.ytarchive  (needs v0.5.0+ for --live-from / --capture-duration)
    """
    exe = shutil.which("ytarchive")
    if not exe:
        raise RuntimeError("To grab part of a stream that is still live, install ytarchive on this PC once: "
                           "winget install Kethsar.ytarchive  - then restart the helper.")
    quality = f"{height}p60/{height}p/best"
    cmd = [exe, "--no-wait", "--live-from", hms(start), "--capture-duration", hms(length),
           "-o", str(work / "src"), url, quality]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    tail = []
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        tail = (tail + [line])[-8:]
        with lock:
            gone = jid not in jobs
        if gone:
            proc.terminate()
            return
        if "Fragments" in line or "Downloaded" in line:
            update(jid, note=line[-80:])
    proc.wait()
    if not any(p.suffix in (".mp4", ".mkv", ".ts") for p in work.glob("src*")):
        raise RuntimeError("ytarchive didn't produce a video: " + " | ".join(tail)[-300:])


def record_live(jid, url, work, minutes):
    """Records the next `minutes` of a live stream with ffmpeg straight from its HLS playlist.

    yt-dlp hands live streams to ffmpeg, which reports no progress and ignores a time limit, so the old
    version sat at 0% forever. Here ffmpeg gets the playlist and a fixed length, and progress is the clock.
    """
    import yt_dlp
    h = MAX_HEIGHT
    fmt = f"best[protocol^=m3u8][height<={h}][vcodec^=avc1]/best[protocol^=m3u8][height<={h}]/best[protocol^=m3u8]/best"
    with yt_dlp.YoutubeDL(ydl_opts({"format": fmt})) as ydl:
        info = ydl.extract_info(url, download=False)
    src_url = info.get("url")
    if not src_url:
        raise RuntimeError("Couldn't find the live stream's video address.")
    secs = max(60, minutes * 60)
    headers = "".join(f"{k}: {v}\r\n" for k, v in (info.get("http_headers") or {}).items())
    cmd = ["ffmpeg", "-y", "-v", "error"]
    if headers:
        cmd += ["-headers", headers]
    cmd += ["-i", src_url, "-t", str(secs), "-c", "copy", "-f", "mpegts", str(work / "src.ts")]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    started = time.time()
    while proc.poll() is None:
        with lock:
            gone = jid not in jobs
        if gone:
            proc.terminate()
            return
        update(jid, progress=round(min(0.99, (time.time() - started) / secs), 3))
        if time.time() - started > secs + 90:       # a stuck stream: stop and keep what was recorded
            proc.terminate()
            break
        time.sleep(1)
    err = proc.stderr.read() if proc.stderr else ""
    out = work / "src.ts"
    if not out.exists() or out.stat().st_size < 100_000:
        raise RuntimeError("Recording the live stream failed: " + (err or "nothing was recorded")[-300:])


def video_format(h):
    return (f"bv*[height<={h}][vcodec^=avc1]+ba[ext=m4a]/bv*[height<={h}][vcodec^=avc1]+ba/"
            f"b[height<={h}][vcodec^=avc1]/bv*[height<={h}]+ba/b[height<={h}]/b")


def download_ranges(jid, url, work, ranges, h):
    """Only the given (start, end) parts of a finished video. yt-dlp asks YouTube for just those bytes, so
    ten 90-second parts of a 10-hour stream download in minutes. Returns the part files in order."""
    import yt_dlp
    from yt_dlp.utils import download_range_func
    done = []

    def hook(d):
        if d.get("status") == "finished":
            done.append(d.get("filename"))
            update(jid, progress=round(min(0.99, len(done) / (2 * len(ranges))), 3))

    opts = ydl_opts({"format": video_format(h), "progress_hooks": [hook],
                     "outtmpl": str(work / "part-%(section_start)08.1f.%(ext)s"),
                     "download_ranges": download_range_func(None, ranges),
                     "force_keyframes_at_cuts": False, "merge_output_format": "mp4"})
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    parts = sorted(p for p in work.glob("part-*") if p.suffix in (".mp4", ".mkv", ".webm"))
    if not parts:
        raise RuntimeError("YouTube didn't return those parts of the video.")
    return parts


def probe_duration(path) -> float:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def concat(parts, out):
    lst = out.parent / "parts.txt"
    lst.write_text("".join(f"file '{p.as_posix()}'\n" for p in parts))
    r = subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy",
                        str(out)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("Joining the parts failed: " + r.stderr[-300:])
    for p in parts:
        p.unlink(missing_ok=True)


# ---- Best moments: find the peaks from cheap signals, then download only those parts ----

HYPE = ("lol", "lmao", "kekw", "lul", "omg", "wtf", "clip", "pog", "w", "insane", "bruh", "haha", "😂", "🤣", "💀", "🔥",
        "😭", "bhai", "pagal", "op", "gajab", "kya", "arre")


def chat_replay(url, work, seconds_limit=360):
    """YouTube live-chat replay of a finished stream, as (seconds, text). Text only, but a long stream has
    a lot of it, so it stops after `seconds_limit` and uses what it has."""
    cmd = [sys.executable, "-m", "yt_dlp", "--skip-download", "--write-subs", "--sub-langs", "live_chat",
           "-o", str(work / "chat"), url]
    if COOKIES_FROM:
        cmd[3:3] = ["--cookies-from-browser", COOKIES_FROM]
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=seconds_limit)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    out = []
    for f in list(work.glob("chat*live_chat.json*")):
        try:
            lines = f.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                j = json.loads(line)
            except ValueError:
                continue
            r = j.get("replayChatItemAction") or {}
            try:
                t = int(r.get("videoOffsetTimeMsec", "0")) / 1000
            except ValueError:
                continue
            for a in r.get("actions", []):
                item = ((a.get("addChatItemAction") or {}).get("item") or {}).get("liveChatTextMessageRenderer")
                if not item:
                    continue
                runs = (item.get("message") or {}).get("runs", [])
                text = "".join(x.get("text") or ((x.get("emoji") or {}).get("shortcuts") or [""])[0] for x in runs)
                out.append((t, text[:120]))
    return out


def audio_loudness(jid, url, work):
    """Downloads only the smallest audio track (about 50 MB per hour) and measures loudness per second."""
    import yt_dlp
    opts = ydl_opts({"format": "wa[acodec=opus]/wa/ba", "outtmpl": str(work / "audio.%(ext)s")})
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    files = [p for p in work.glob("audio.*") if p.suffix not in (".part", ".ytdl")]
    if not files:
        return []
    meta = work / "loud.txt"
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(files[0]), "-ac", "1", "-ar", "8000", "-af",
                    "aresample=8000,asetnsamples=n=8000,astats=metadata=1:reset=1,"
                    f"ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file={meta.as_posix()}",
                    "-f", "null", "-"], capture_output=True)
    vals = []
    if meta.exists():
        for line in meta.read_text().splitlines():
            if "RMS_level=" in line:
                v = line.split("=", 1)[1]
                vals.append(float(v) if v not in ("-inf", "inf", "nan") else -90.0)
    for f in files:
        f.unlink(missing_ok=True)
    return vals


def normalise(vals):
    if len(vals) < 10:
        return [0.0] * len(vals)
    s = sorted(vals)
    lo, hi = s[len(s) // 2], s[min(len(s) - 1, int(len(s) * 0.995))]
    span = max(hi - lo, 1e-6)
    return [min(1.0, max(0.0, (v - lo) / span)) for v in vals]


def best_ranges(duration, loud_db, chat, heat, count, before=55, after=35):
    """Per-second score from every signal there is, then the `count` best peaks, at least a clip apart."""
    n = max(1, int(duration))
    signals = []
    if loud_db:
        signals.append((1.0, normalise((loud_db + [-90.0] * n)[:n])))
    if len(chat) >= 30:
        raw = [0.0] * n
        for t, text in chat:
            i = int(t - 12)                      # chat reacts ~12 s after the moment
            if 0 <= i < n:
                low = text.lower()
                raw[i] += 1.6 if (len(low) <= 6 or any(h in low for h in HYPE)) else 1.0
        vel, acc = [], 0.0
        for i in range(n):
            acc += raw[i] - (raw[i - 10] if i >= 10 else 0)
            vel.append(acc)
        signals.append((1.5, normalise(vel)))
    if heat:
        per = [0.0] * n
        for h in heat:
            a, b = int(h.get("start_time", 0)), int(h.get("end_time", 0))
            for i in range(max(0, a), min(n, b + 1)):
                per[i] = float(h.get("value", 0))
        signals.append((1.5, per))
    if not signals:
        return [], []
    wsum = sum(w for w, _ in signals)
    score = [sum(w * sig[i] for w, sig in signals) / wsum for i in range(n)]
    sm, acc = [], 0.0                            # 10 s smoothing
    for i in range(n):
        acc += score[i] - (score[i - 10] if i >= 10 else 0)
        sm.append(acc / 10)
    order = sorted(range(30, max(31, n - 10)), key=lambda i: sm[i], reverse=True)
    peaks = []
    for i in order:
        if len(peaks) >= count:
            break
        if all(abs(i - p) >= before + after for p in peaks):
            peaks.append(i)
    peaks.sort()
    ranges = [(max(0, p - before), min(duration, p + after)) for p in peaks]
    return ranges, peaks


def chat_sample(chat, t0, t1, limit=12):
    counts = {}
    for t, text in chat:
        if t0 <= t <= t1 and 0 < len(text) <= 80:
            counts[text] = counts.get(text, 0) + 1
    top = sorted(counts.items(), key=lambda kv: (-kv[1], len(kv[0])))[:limit]
    return [f"{k} x{v}" if v > 1 else k for k, v in top]


def run_job(jid, url, opts):
    import yt_dlp
    work = DATA / jid
    work.mkdir(exist_ok=True)
    mode = opts.get("mode", "whole")
    h = min(MAX_HEIGHT, int(opts.get("height") or MAX_HEIGHT))
    try:
        with yt_dlp.YoutubeDL(ydl_opts({})) as ydl:
            info = ydl.extract_info(url, download=False)
        if info.get("_type") == "playlist":
            raise RuntimeError("That is a channel or playlist link. Open one video (or the live stream) and copy its link.")
        is_live = bool(info.get("is_live"))
        duration = float(info.get("duration") or 0)
        update(jid, title=info.get("title") or "", uploader=info.get("uploader") or info.get("channel") or "",
               duration=duration, live=is_live, state="downloading", heatmap=info.get("heatmap") or [])

        markers = []
        if is_live:
            if mode == "range" and opts.get("from") is not None and opts.get("to") is not None:
                start, end = float(opts["from"]), float(opts["to"])
                update(jid, note="Grabbing that part of the live stream")
                ytarchive_range(jid, url, work, start, max(10, end - start), h)
            elif mode == "last" or (mode == "best" and shutil.which("ytarchive")):
                mins = int(opts.get("live_minutes", 10))
                update(jid, note=f"Grabbing the last {mins} min")
                ytarchive_range(jid, url, work, -mins * 60, mins * 60, h)
            else:
                record_live(jid, url, work, int(opts.get("live_minutes", 30)))
        elif mode == "best":
            count = max(3, min(20, int(opts.get("count", 8))))
            update(jid, note="Reading chat and listening for the loud parts (audio only)")
            chat_box = {}
            t = threading.Thread(target=lambda: chat_box.setdefault("chat", chat_replay(url, work)), daemon=True)
            t.start()
            loud = audio_loudness(jid, url, work)
            t.join(timeout=420)
            chat = chat_box.get("chat", [])
            ranges, peaks = best_ranges(duration, loud, chat, info.get("heatmap") or [], count)
            if not ranges:
                raise RuntimeError("Couldn't find any signal to pick moments from. Try a time range instead.")
            update(jid, note=f"Downloading the {len(ranges)} best parts only")
            parts = download_ranges(jid, url, work, ranges, h)
            at = 0.0
            for (s0, e0), p, part in zip(ranges, peaks, parts):
                length = probe_duration(part) or (e0 - s0)
                markers.append({"at": at, "length": length, "src_start": s0, "peak": p - s0,
                                "chat": chat_sample(chat, p - 5, p + 30)})
                at += length
            concat(parts, work / "src.mp4")
        elif mode == "range" and opts.get("from") is not None and opts.get("to") is not None:
            parts = download_ranges(jid, url, work, [(float(opts["from"]), float(opts["to"]))], h)
            parts[0].rename(work / "src.mp4")
        else:
            def hook(d):
                if d.get("status") == "downloading":
                    total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                    p = (d.get("downloaded_bytes", 0) / total) if total else 0
                    update(jid, progress=round(min(p, 0.99), 3))

            yopts = ydl_opts({"format": video_format(h), "outtmpl": str(work / "src.%(ext)s"),
                              "progress_hooks": [hook], "merge_output_format": "mp4"})
            with yt_dlp.YoutubeDL(yopts) as ydl:
                ydl.download([url])
        update(jid, markers=markers)

        src = max((p for p in work.glob("src*") if p.suffix not in (".part", ".ytdl", ".txt")),
                  key=lambda p: p.stat().st_size, default=None)
        if src is None:
            parts = sorted(work.glob("src*.part"), key=lambda p: p.stat().st_size, reverse=True)
            src = parts[0] if parts else None
        if src is None:
            raise RuntimeError("The download finished but no video file was made.")

        out = work / "video.mp4"
        update(jid, state="converting", progress=1)
        # make sure the phone gets H.264/AAC in an MP4 it can read; copy streams when they already fit
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "stream=codec_name", "-of", "csv=p=0", str(src)], capture_output=True, text=True)
        vcodec = probe.stdout.strip()
        vargs = ["-c:v", "copy"] if vcodec == "h264" else ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
        p = subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(src), *vargs, "-c:a", "aac", "-b:a", "160k",
                            "-movflags", "+faststart", str(out)], capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError("ffmpeg failed: " + p.stderr[-400:])
        for f in work.glob("src*"):
            f.unlink(missing_ok=True)
        update(jid, state="ready", file=str(out), size=out.stat().st_size, finished=time.time())
    except Exception as e:  # noqa: BLE001
        update(jid, state="error", error=explain(e))
        shutil.rmtree(work, ignore_errors=True)


def cleanup():
    while True:
        time.sleep(600)
        now = time.time()
        with lock:
            old = [j for j, v in jobs.items() if now - v.get("created", now) > KEEP_HOURS * 3600]
        for j in old:
            shutil.rmtree(DATA / j, ignore_errors=True)
            with lock:
                jobs.pop(j, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "ClipForgeHelper/1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if secrets.compare_digest(self.headers.get("X-Key", ""), KEY):
            return True
        self._json(401, {"error": "Wrong key. Copy the key the helper printed into ClipForge settings."})
        return False

    def do_GET(self):
        if self.path == "/ping":
            return self._json(200, {"ok": True, "app": "clipforge-helper"})
        if not self._authed():
            return
        parts = self.path.strip("/").split("/")
        if len(parts) >= 2 and parts[0] == "jobs":
            with lock:
                job = dict(jobs.get(parts[1]) or {})
            if not job:
                return self._json(404, {"error": "No such download."})
            if len(parts) == 3 and parts[2] == "file":
                if job.get("state") != "ready":
                    return self._json(409, {"error": "Not ready yet."})
                path = Path(job["file"])
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(path.stat().st_size))
                self.end_headers()
                with open(path, "rb") as f:
                    shutil.copyfileobj(f, self.wfile, 1024 * 1024)
                return
            job.pop("file", None)
            return self._json(200, job)
        self._json(404, {"error": "Not found."})

    def do_POST(self):
        if not self._authed():
            return
        if self.path != "/jobs":
            return self._json(404, {"error": "Not found."})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(n, 10000)) or b"{}")
        except ValueError:
            return self._json(400, {"error": "Bad request."})
        url = str(body.get("url", "")).strip()
        if not site_allowed(url):
            return self._json(400, {"error": "Only YouTube, Twitch and Kick links are accepted."})
        def num(key, lo, hi):
            v = body.get(key)
            try:
                return None if v is None else max(lo, min(hi, float(v)))
            except (TypeError, ValueError):
                return None

        opts = {"mode": str(body.get("mode") or "whole"),
                "live_minutes": int(num("live_minutes", 1, 180) or 30),
                "from": num("from", -12 * 3600, 48 * 3600), "to": num("to", -12 * 3600, 48 * 3600),
                "count": int(num("count", 3, 20) or 8), "height": int(num("height", 360, 1080) or MAX_HEIGHT)}
        if opts["from"] is not None and opts["to"] is not None and opts["to"] <= opts["from"]:
            return self._json(400, {"error": "The end time must be after the start time."})
        jid = uuid.uuid4().hex[:12]
        with lock:
            jobs[jid] = {"id": jid, "url": url, "state": "queued", "progress": 0, "created": time.time(),
                         "mode": opts["mode"]}
        threading.Thread(target=run_job, args=(jid, url, opts), daemon=True).start()
        self._json(200, {"id": jid})

    def do_DELETE(self):
        if not self._authed():
            return
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "jobs":
            shutil.rmtree(DATA / parts[1], ignore_errors=True)
            with lock:
                jobs.pop(parts[1], None)
            return self._json(200, {"ok": True})
        self._json(404, {"error": "Not found."})


def main():
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        raise SystemExit("yt-dlp is not installed. Run:  pip install -U yt-dlp")
    if not shutil.which("ffmpeg"):
        print("Warning: ffmpeg was not found. Install it (Windows: winget install Gyan.FFmpeg).")
    threading.Thread(target=cleanup, daemon=True).start()
    addr = f"http://{lan_ip()}:{PORT}"
    print("\nClipForge helper is running.")
    print(f"  Address: {addr}")
    print(f"  Key:     {KEY}")
    print("Put both into ClipForge > Settings > Stream links. Keep this window open while downloading.")
    print("Your phone and this computer must be on the same Wi-Fi.\n")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
