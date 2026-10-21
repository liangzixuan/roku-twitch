import json
import subprocess

import httpx
import pytest
from fastapi import HTTPException

from server.auth import Auth
from server.player import Player
from server.storage import write_json
from tests.test_app import api
from tests.test_auth import IDENTITY, TOKEN


VIDEO = {"id": "12345", "user_login": "offlinechannel", "title": "Past broadcast",
         "created_at": "2026-10-19T10:00:00Z", "duration": "2h3m4s"}
HEADERS = {"X-App-Key": "pairing-secret"}
URL = "https://video.example.cloudfront.net/archive/chunked/index-dvr.m3u8?sig=temporary"


def test_offline_channel_vods_and_pagination(tmp_path):
    calls = []

    def handle(request):
        calls.append(request)
        if request.url.path.endswith("validate"):
            return httpx.Response(200, json=IDENTITY)
        if request.url.path.endswith("users"):
            return httpx.Response(200, json={"data": [{"id": "99"}]})
        assert request.url.path.endswith("videos")
        assert request.url.params["type"] == "archive"
        assert request.url.params["user_id"] == "99"
        assert request.url.params["first"] == "20"
        if request.url.params.get("after") == "page2":
            return httpx.Response(200, json={"data": [], "pagination": {}})
        return httpx.Response(200, json={"data": [VIDEO], "pagination": {"cursor": "page2"}})

    write_json(tmp_path / "account.json", TOKEN)
    auth = Auth(tmp_path, "app", http=httpx.Client(transport=httpx.MockTransport(handle)))
    first = auth.videos("offlinechannel")
    assert first["videos"][0]["duration_seconds"] == 7384
    assert first["cursor"] == "page2"
    assert auth.videos("offlinechannel", first["cursor"]) == {"channel": "offlinechannel", "videos": [], "cursor": ""}
    assert all(not request.url.path.endswith("streams") for request in calls)


@pytest.mark.parametrize("status,body", [(200, {"data": []}), (404, {})])
def test_deleted_vod_has_clear_error(tmp_path, status, body):
    auth = Auth(tmp_path, "app")
    auth.helix = lambda endpoint, params: httpx.Response(status, json=body)
    with pytest.raises(HTTPException) as exc:
        auth.video("123")
    assert exc.value.status_code == 404
    assert "no longer available" in exc.value.detail
    auth.http.close()


def mock_resolver(monkeypatch, output=URL, code=0):
    class Process:
        returncode = code

        def poll(self):
            return self.returncode

        def terminate(self):
            self.returncode = -15

        def wait(self, timeout=None):
            return self.returncode

    def spawn(args, **kwargs):
        assert "web-secret" not in " ".join(args)
        assert "--json" in args
        assert "https://www.twitch.tv/videos/12345" in args
        catalog = {"streams": {"best": {"type": "hls", "url": output}, "1080p60": {"type": "hls", "url": output}, "720p60": {"type": "hls", "url": output.replace("chunked", "720p60")}}}
        kwargs["stdout"].write(json.dumps(catalog).encode())
        kwargs["stdout"].flush()
        return Process()

    monkeypatch.setattr(subprocess, "Popen", spawn)


def test_vod_resolver_exit_keeps_finite_recording_available(tmp_path, monkeypatch):
    mock_resolver(monkeypatch)
    now = [100]
    player = Player(tmp_path, clock=lambda: now[0])
    result = player.start_vod(Auth.video_info(VIDEO), "web-secret")
    assert result["state"] == "ready"
    assert result["url"] == URL
    assert result["kind"] == "vod"
    assert result["duration_seconds"] == 7384
    assert "web-secret" not in str(result)
    assert not player.processes
    assert not (tmp_path / "streamlink.conf").exists()
    assert not list(player.root.rglob("variants.json"))
    now[0] += 60
    assert player.status()["state"] == "ready"
    player.last_read = now[0]
    now[0] += 61
    player.expire_idle()
    assert player.status()["state"] == "ready"
    now[0] += 60
    player.expire_idle()
    assert player.status()["state"] == "idle"


@pytest.mark.parametrize("output,code", [(URL, 1), ("", 0), ("http://video.cloudfront.net/a", 0),
    ("https://cloudfront.net.evil.test/a", 0), ("file:///private/secret", 0), (URL + "\n" + URL, 0)])
def test_bad_vod_resolution_cleans_up(tmp_path, monkeypatch, output, code):
    mock_resolver(monkeypatch, output, code)
    player = Player(tmp_path)
    assert player.start_vod(Auth.video_info(VIDEO), "web-secret")["state"] == "error"
    assert player.job is None
    assert not player.root.exists()
    assert not (tmp_path / "streamlink.conf").exists()


def test_vod_resolver_timeout_terminates_process(tmp_path, monkeypatch):
    mock_resolver(monkeypatch, code=None)
    now = [100]
    player = Player(tmp_path, clock=lambda: now[0])
    assert player.start_vod(Auth.video_info(VIDEO), "web-secret")["state"] == "starting"
    process = player.processes[0]
    assert (tmp_path / "streamlink.conf").stat().st_mode & 0o777 == 0o600
    now[0] += 91
    assert player.status()["state"] == "error"
    assert process.poll() == -15
    assert not player.root.exists()


def test_vod_api_validates_ids_and_requires_playback_login(api, monkeypatch):
    client, app, _ = api
    monkeypatch.setattr(app.state.player, "start_vod", lambda *args: pytest.fail("Must validate first"))
    assert client.post("/api/vod/play", headers=HEADERS, json={"video_id": "../../private"}).status_code == 422
    assert client.post("/api/vod/play", headers=HEADERS, json={"video_id": "12345"}).status_code == 409


def test_vod_api_uses_matching_playback_identity(api, monkeypatch):
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / "playback.json", {"token": "web-secret"})
    monkeypatch.setattr(app.state.auth, "video", lambda video_id: Auth.video_info(VIDEO))
    mock_resolver(monkeypatch)
    response = client.post("/api/vod/play", headers=HEADERS, json={"video_id": "12345"})
    assert response.status_code == 200
    assert response.json()["state"] == "ready"
    assert "web-secret" not in response.text
    assert response.headers["Cache-Control"] == "no-store"


def test_heartbeat_only_renews_current_job_and_does_not_return_url(api):
    client, app, _ = api
    player = app.state.player
    player.job = {"id": "current", "kind": "vod", "state": "ready", "url": URL}
    player.last_read = 0
    assert client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": "old"}).status_code == 409
    assert player.last_read == 0
    response = client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": "current"})
    assert response.json() == {"state": "ready", "message": ""}
    assert player.last_read > 0
    assert URL not in response.text
    client.post("/api/stop", headers=HEADERS)
    assert client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": "current"}).status_code == 409


@pytest.mark.parametrize("method,path,body", [("get", "/api/videos/channel", None),
    ("post", "/api/vod/play", {"video_id": "12345"}),
    ("post", "/api/player/heartbeat", {"job_id": "current"})])
def test_vod_endpoints_require_pairing(api, method, path, body):
    client, _, _ = api
    assert client.request(method, path, json=body).status_code == 401
