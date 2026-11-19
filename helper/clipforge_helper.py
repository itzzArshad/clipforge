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


def run_job(jid, url, live_minutes):
    import yt_dlp
    work = DATA / jid
    work.mkdir(exist_ok=True)
    try:
        with yt_dlp.YoutubeDL(ydl_opts({})) as ydl:
            info = ydl.extract_info(url, download=False)
        if info.get("_type") == "playlist":
            raise RuntimeError("That is a channel or playlist link. Open one video (or the live stream) and copy its link.")
        is_live = bool(info.get("is_live"))
        update(jid, title=info.get("title") or "", uploader=info.get("uploader") or info.get("channel") or "",
               duration=float(info.get("duration") or 0), live=is_live, state="downloading",
               heatmap=info.get("heatmap") or [])   # YouTube "most replayed" graph, when YouTube has one

        started = time.time()

        def hook(d):
            if d.get("status") == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                if is_live:
                    p = min(0.99, (time.time() - started) / max(60, live_minutes * 60))
                    if time.time() - started >= live_minutes * 60:
                        raise Stop()
                else:
                    p = (d.get("downloaded_bytes", 0) / total) if total else 0
                update(jid, progress=round(p, 3))

        h = MAX_HEIGHT
        fmt = (f"bv*[height<={h}][vcodec^=avc1]+ba[ext=m4a]/bv*[height<={h}][vcodec^=avc1]+ba/"
               f"b[height<={h}][vcodec^=avc1]/bv*[height<={h}]+ba/b[height<={h}]/b")
        opts = ydl_opts({"format": fmt, "outtmpl": str(work / "src.%(ext)s"), "progress_hooks": [hook],
                         "merge_output_format": "mp4"})
        if is_live:
            # record from now for the chosen minutes; MPEG-TS so a stopped recording is still a valid file
            opts.update({"hls_use_mpegts": True, "outtmpl": str(work / "src.ts")})
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([url])
        except Exception as e:  # noqa: BLE001 - Stop() arrives wrapped in yt-dlp's own error
            stopped = isinstance(e, Stop) or "Stop" in repr(e) or isinstance(getattr(e, "exc_info", [None, None])[1], Stop)
            if not (is_live and stopped):
                raise
        src = max((p for p in work.glob("src*") if p.suffix not in (".part", ".ytdl")),
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
        minutes = max(1, min(180, int(body.get("live_minutes", 30) or 30)))
        jid = uuid.uuid4().hex[:12]
        with lock:
            jobs[jid] = {"id": jid, "url": url, "state": "queued", "progress": 0, "created": time.time()}
        threading.Thread(target=run_job, args=(jid, url, minutes), daemon=True).start()
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
