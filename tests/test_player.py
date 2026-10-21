import shutil
import subprocess
import time

import pytest

from server.player import Player


def test_idle_player_cleans_up_credentials_and_segments(tmp_path):
    now = [100]
    player = Player(tmp_path, clock=lambda: now[0])
    player.root.mkdir()
    (player.root / "old.ts").write_bytes(b"old")
    (tmp_path / "streamlink.conf").write_text("secret")
    player.job = {"id": "old"}
    player.last_read = 100
    now[0] = 221
    player.expire_idle()
    assert player.job is None
    assert not player.root.exists()
    assert not (tmp_path / "streamlink.conf").exists()


@pytest.mark.skipif(not shutil.which("ffmpeg") or not shutil.which("ffprobe"), reason="FFmpeg required")
def test_real_ffmpeg_pipeline_generates_h264_hls(tmp_path, monkeypatch):
    original = subprocess.Popen
    commands = []

    def local_source(args, **kwargs):
        commands.append(args)
        assert "private-web-token" not in " ".join(args)
        if args[1:3] == ["-m", "streamlink"]:
            assert args[-1] == "720p60,best"
            args = ["ffmpeg", "-nostdin", "-loglevel", "error", "-re", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=15",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "20",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "30", "-c:a", "aac", "-f", "mpegts", "pipe:1"]
        return original(args, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", local_source)
    player = Player(tmp_path)
    processes = []
    try:
        result = player.start("testchannel", "private-web-token", "720p60")
        processes = list(player.processes)
        assert result["state"] == "starting"
        assert (tmp_path / "streamlink.conf").stat().st_mode & 0o777 == 0o600
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            result = player.status()
            if result["state"] != "starting":
                break
            time.sleep(0.2)
        assert result["state"] == "ready"
        folder = player.root / result["id"]
        manifest = (folder / "index.m3u8").read_text()
        assert "#EXTM3U" in manifest
        assert "private-web-token" not in manifest
        segment = next(folder.glob("*.ts"))
        probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(segment)], text=True)
        assert "h264" in probe
    finally:
        player.stop()
    assert processes and all(process.poll() is not None for process in processes)
    assert not (tmp_path / "streamlink.conf").exists()
    assert not player.root.exists()
