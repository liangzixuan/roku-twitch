import httpx
import pytest
from fastapi.testclient import TestClient

from server.app import create_app
from server.storage import write_json
from tests.test_auth import IDENTITY, TOKEN


@pytest.fixture
def api(tmp_path):
    write_json(tmp_path / "settings.json", {"client_id": "app", "app_key": "pairing-secret"})
    http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=IDENTITY)))
    app = create_app(tmp_path, http=http)
    with TestClient(app) as client:
        yield client, app, tmp_path


@pytest.mark.parametrize("method,path", [("get", "/api/account"), ("post", "/api/login"), ("post", "/api/logout"), ("post", "/api/stop"), ("get", "/api/player"), ("get", "/media/id/index.m3u8")])
def test_api_and_media_require_pairing_key(api, method, path):
    client, _, _ = api
    assert getattr(client, method)(path).status_code == 401


def test_account_response_never_contains_tokens(api):
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / "playback.json", {"token": "web-secret"})
    response = client.get("/api/account", headers={"X-App-Key": "pairing-secret"})
    assert response.json()["playback_ready"] is True
    assert response.json()["ad_free"] == "unverified"
    assert "secret" not in response.text
    assert response.headers["Cache-Control"] == "no-store"


def test_login_without_playback_credential_does_not_play_anonymously(api, monkeypatch):
    client, app, _ = api
    app.state.auth.token = TOKEN
    def unexpected(*args):
        pytest.fail("Must not start anonymous playback")
    monkeypatch.setattr(app.state.player, "start", unexpected)
    response = client.post("/api/play", json={"channel": "channel"}, headers={"X-App-Key": "pairing-secret"})
    assert response.status_code == 409


def test_invalid_channel_rejected_before_playback(api):
    client, _, _ = api
    response = client.post("/api/play", json={"channel": "../../private"}, headers={"X-App-Key": "pairing-secret"})
    assert response.status_code == 400


def test_logout_stops_media_and_removes_files(api):
    client, app, data = api
    app.state.auth.token = TOKEN
    folder = data / "streams/job"
    folder.mkdir(parents=True)
    (folder / "index.m3u8").write_text("#EXTM3U")
    app.state.player.job = {"id": "job"}
    headers = {"X-App-Key": "pairing-secret"}
    assert client.get("/media/job/index.m3u8", headers=headers).status_code == 200
    assert client.post("/api/logout", headers=headers).status_code == 200
    assert client.get("/media/job/index.m3u8", headers=headers).status_code == 404
    assert not folder.exists()


def test_media_path_only_serves_current_segments(api):
    client, app, data = api
    app.state.player.job = {"id": "job"}
    headers = {"X-App-Key": "pairing-secret"}
    assert client.get("/media/job/settings.json", headers=headers).status_code == 404
    assert client.get("/media/old/index.m3u8", headers=headers).status_code == 404


def test_lost_account_immediately_stops_playback(api):
    client, app, data = api
    app.state.auth.token = TOKEN
    folder = data / "streams/job"
    folder.mkdir(parents=True)
    (folder / "index.m3u8").write_text("#EXTM3U")
    app.state.player.job = {"id": "job"}
    app.state.auth.clear_account()
    assert app.state.player.job is None
    assert not folder.exists()
