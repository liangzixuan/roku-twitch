import secrets
import shutil
import subprocess
import sys
import time

from fastapi import HTTPException

from .storage import private_write
from .quality import read_variants, quality_choices


class Player:
    # All methods run under the app state lock.
    def __init__(self, data, clock=time.time):
        self.root = data / "streams"
        self.clock = clock
        self.job = None
        self.processes = []
        self.last_read = 0
        self.variants = {}
        self.catalog_process = None
        self.catalog_started = 0

    def stop(self):
        if self.catalog_process:
            self.processes.append(self.catalog_process)
            self.catalog_process = None
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
        for process in self.processes:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        self.processes = []
        self.job = None
        self.variants = {}
        shutil.rmtree(self.root, ignore_errors=True)
        (self.root.parent / "streamlink.conf").unlink(missing_ok=True)

    def start(self, channel, token, quality="best"):
        if not shutil.which("ffmpeg"):
            raise HTTPException(503, "Install FFmpeg on the computer or NAS first.")
        self.stop()
        job_id = secrets.token_hex(16)
        folder = self.root / job_id
        folder.mkdir(parents=True, mode=0o700)
        config = self.root.parent / "streamlink.conf"
        # Keep the token out of process arguments and logs.
        private_write(config, f"twitch-api-header=Authorization=OAuth {token}\n")
        try:
            stream = subprocess.Popen([
                sys.executable, "-m", "streamlink", "--config", str(config),
                "--loglevel", "none", "--twitch-supported-codecs", "h264",
                "--stream-segment-timeout", "20", "--stream-timeout", "45",
                "--stdout", f"https://www.twitch.tv/{channel}", quality + ",best"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.processes.append(stream)
            mux = subprocess.Popen([
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", "pipe:0", "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
                "-f", "hls", "-hls_time", "4", "-hls_list_size", "8",
                "-hls_flags", "delete_segments+temp_file+omit_endlist",
                "-hls_segment_filename", str(folder / "segment%06d.ts"), str(folder / "index.m3u8")],
                stdin=stream.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.processes.append(mux)
            stream.stdout.close()
        except OSError:
            self.stop()
            raise HTTPException(503, "Could not start playback. Check Streamlink and FFmpeg installation.") from None
        self.job = {"id": job_id, "kind": "live", "channel": channel, "started_at": self.clock(), "state": "starting", "quality": quality}
        self.last_read = self.clock()
        return self.status()

    def start_vod(self, video, token, quality="best"):
        self.stop()
        job_id = secrets.token_hex(16)
        folder = self.root / job_id
        folder.mkdir(parents=True, mode=0o700)
        config = self.root.parent / "streamlink.conf"
        private_write(config, f"twitch-api-header=Authorization=OAuth {token}\n")
        output = folder / "variants.json"
        private_write(output, "")
        try:
            # Resolve the full VOD playlist without downloading the recording.
            with output.open("wb") as destination:
                process = subprocess.Popen([
                    sys.executable, "-m", "streamlink", "--config", str(config),
                    "--loglevel", "none", "--twitch-supported-codecs", "h264",
                    "--json", f"https://www.twitch.tv/videos/{video['id']}"],
                    stdout=destination, stderr=subprocess.DEVNULL)
            self.processes.append(process)
        except OSError:
            self.stop()
            raise HTTPException(503, "Could not start VOD playback. Check Streamlink installation.") from None
        self.job = {"id": job_id, "kind": "vod", "video_id": video["id"], "channel": video["channel"],
                    "title": video["title"], "duration_seconds": video["duration_seconds"],
                    "play_start": video.get("play_start", 0),
                    "thumbnail": video.get("thumbnail", ""), "created_at": video.get("created_at", ""),
                    "quality": quality,
                    "started_at": self.clock(), "state": "starting"}
        self.last_read = self.clock()
        return self.status()

    def vod_status(self):
        if self.job["state"] == "ready":
            return {**self.job, "ad_free": "unverified"}
        code = self.processes[0].poll()
        if code is None and self.clock() - self.job["started_at"] <= 90:
            return {**self.job, "ad_free": "unverified"}
        output = self.root / self.job["id"] / "variants.json"
        self.variants = read_variants(output) if code == 0 else {}
        if not self.variants:
            self.stop()
            return {"state": "error", "message": "Cannot open this VOD. It may be deleted, restricted to subscribers, or require a new playback login."}
        self.processes[0].wait()
        self.processes = []
        output.unlink(missing_ok=True)
        (self.root.parent / "streamlink.conf").unlink(missing_ok=True)
        quality = self.job["quality"]
        if quality not in self.variants:
            quality = "best"
        self.job.update(state="ready", url=self.variants[quality], quality=quality)
        return {**self.job, "ad_free": "unverified"}

    def qualities(self):
        if self.variants:
            return {"state": "ready", "qualities": quality_choices(self.variants), "quality": self.job["quality"]}
        if not self.job or self.job["kind"] != "live":
            raise HTTPException(409, "Wait for playback to start.")
        output = self.root / self.job["id"] / "variants.json"
        if self.catalog_process is None:
            private_write(output, "")
            config = self.root.parent / "streamlink.conf"
            try:
                with output.open("wb") as destination:
                    self.catalog_process = subprocess.Popen([
                        sys.executable, "-m", "streamlink", "--config", str(config),
                        "--loglevel", "none", "--twitch-supported-codecs", "h264", "--json",
                        f"https://www.twitch.tv/{self.job['channel']}"], stdout=destination, stderr=subprocess.DEVNULL)
            except OSError:
                output.unlink(missing_ok=True)
                raise HTTPException(503, "Cannot load quality choices. Try again.") from None
            self.catalog_started = self.clock()
        code = self.catalog_process.poll()
        if code is None and self.clock() - self.catalog_started <= 45:
            return {"state": "starting"}
        if code is None:
            self.catalog_process.kill()
        self.catalog_process.wait(timeout=3)
        self.catalog_process = None
        self.variants = read_variants(output) if code == 0 else {}
        output.unlink(missing_ok=True)
        if not self.variants:
            raise HTTPException(502, "Cannot load quality choices. Playback will continue. Try again.")
        if self.job["quality"] not in self.variants:
            self.job["quality"] = "best"
        return {"state": "ready", "qualities": quality_choices(self.variants), "quality": self.job["quality"]}

    def change_quality(self, quality, token, position=None):
        if quality not in self.variants:
            raise HTTPException(409, "This quality is unavailable.")
        if self.job["kind"] == "vod":
            self.job.update(quality=quality, url=self.variants[quality],
                            play_start=min(position, max(0, self.job["duration_seconds"] - 2)))
            self.last_read = self.clock()
            return self.status()
        variants = self.variants
        result = self.start(self.job["channel"], token, quality)
        self.variants = variants
        return result

    def status(self):
        if self.catalog_process and self.catalog_process.poll() is None and self.clock() - self.catalog_started > 45:
            self.catalog_process.kill()
            self.catalog_process.wait(timeout=3)
        if not self.job:
            return {"state": "idle"}
        if self.job.get("kind") == "vod":
            return self.vod_status()
        if any(p.poll() is not None for p in self.processes):
            self.stop()
            return {"state": "error", "message": "Stream ended or could not start. Check that the channel is live and playback login is current."}
        manifest = self.root / self.job["id"] / "index.m3u8"
        if manifest.exists():
            self.job["state"] = "ready"
        elif self.clock() - self.job["started_at"] > 90:
            self.stop()
            return {"state": "error", "message": "Stream startup timed out. Check the channel, network and playback login."}
        return {**self.job, "path": f"/media/{self.job['id']}/index.m3u8", "ad_free": "unverified"}

    def expire_idle(self):
        if self.job and self.clock() - self.last_read > 120:
            self.stop()
