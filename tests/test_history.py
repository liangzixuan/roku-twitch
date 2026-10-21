import pytest

from server.history import History
from server.storage import read_json, write_json
from tests.test_app import api
from tests.test_auth import TOKEN, IDENTITY
from tests.test_vod import HEADERS, VIDEO, mock_resolver
from server.auth import Auth


def start_vod(api, monkeypatch, resume=False):
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / "playback.json", {"token": "web-secret"})
    monkeypatch.setattr(app.state.auth, "video", lambda _: Auth.video_info(VIDEO))
    mock_resolver(monkeypatch)
    response = client.post("/api/vod/play", headers=HEADERS, json={"video_id": VIDEO["id"], "resume": resume})
    assert response.status_code == 200
    return response.json()


def test_progress_persists_and_resume_uses_saved_position(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    assert job["play_start"] == 0
    response = client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": job["id"], "position": 1234.8})
    assert response.status_code == 200
    assert History(data).position("7", VIDEO["id"]) == 1234
    assert (data / "history.json").stat().st_mode & 0o777 == 0o600
    assert "https://" not in (data / "history.json").read_text()
    assert "secret" not in (data / "history.json").read_text()
    assert client.get("/api/vod/progress/12345", headers=HEADERS).json()["position"] == 1234
    assert start_vod(api, monkeypatch, resume=True)["play_start"] == 1234
    assert start_vod(api, monkeypatch, resume=False)["play_start"] == 0
    # Opening a recording is not evidence that it played. Keep the bookmark until a position arrives.
    assert History(data).position("7", VIDEO["id"]) == 1234


def test_stop_flushes_latest_position_before_clearing_job(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    response = client.post("/api/stop", headers=HEADERS, json={"job_id": job["id"], "position": 456})
    assert response.status_code == 200 and app.state.player.job is None
    assert History(data).position("7", VIDEO["id"]) == 456
    recent = client.get("/api/history", headers=HEADERS).json()["videos"]
    assert recent[0]["id"] == VIDEO["id"] and recent[0]["position"] == 456


def test_stale_updates_cannot_overwrite_or_stop_new_session(api, monkeypatch):
    client, app, data = api
    old = start_vod(api, monkeypatch)
    new = start_vod(api, monkeypatch)
    for path in ("/api/player/heartbeat", "/api/stop"):
        assert client.post(path, headers=HEADERS, json={"job_id": old["id"], "position": 999}).status_code == 409
        assert app.state.player.job["id"] == new["id"]
    assert not (data / "history.json").exists()


@pytest.mark.parametrize("body", [{"position": 7380}, {"position": 100, "finished": True}, {"position": 0}])
def test_completed_or_restarted_recording_leaves_continue_watching(api, monkeypatch, body):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": job["id"], "position": 300})
    response = client.post("/api/stop", headers=HEADERS, json={"job_id": job["id"], **body})
    assert response.status_code == 200
    assert client.get("/api/history", headers=HEADERS).json() == {"videos": []}


def test_account_history_is_separate_and_survives_logout(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    client.post("/api/stop", headers=HEADERS, json={"job_id": job["id"], "position": 300})
    client.post("/api/logout", headers=HEADERS)
    assert History(data).position("7", VIDEO["id"]) == 300
    assert client.get("/api/history", headers=HEADERS).status_code == 401
    app.state.auth.token = TOKEN
    app.state.auth.identity = {**IDENTITY, "user_id": "other"}
    app.state.auth.checked_at = app.state.auth.clock()
    assert client.get("/api/history", headers=HEADERS).json() == {"videos": []}
    assert client.get("/api/vod/progress/12345", headers=HEADERS).json()["position"] == 0


def test_history_bounds_and_sort_order(tmp_path):
    now = [1]
    history = History(tmp_path, clock=lambda: now[0])
    for n in range(102):
        now[0] = n
        history.save("7", {"kind": "vod", "video_id": str(n), "channel": "channel", "title": "video", "duration_seconds": 1000}, 100)
    result = History(tmp_path).recent("7")
    assert len(result) == 100 and result[0]["id"] == "101" and result[-1]["id"] == "2"


@pytest.mark.parametrize("position", [-1, 100000001, "nan", "inf"])
def test_invalid_positions_do_not_change_history(api, monkeypatch, position):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    response = client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": job["id"], "position": position})
    assert response.status_code == 422
    assert not (data / "history.json").exists()


@pytest.mark.parametrize("path", ["/api/history", "/api/vod/progress/12345"])
def test_history_requires_pairing(api, path):
    client, _, _ = api
    assert client.get(path).status_code == 401


def test_stop_without_session_cannot_save_progress(api):
    client, _, _ = api
    assert client.post("/api/stop", headers=HEADERS, json={"position": 12}).status_code == 400


def test_finish_save_failure_still_stops_video(api, monkeypatch):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    def fail(*args):
        from fastapi import HTTPException
        raise HTTPException(503, "Cannot save progress.")
    monkeypatch.setattr(app.state.history, "save", fail)
    assert client.post("/api/stop", headers=HEADERS, json={"job_id": job["id"], "position": 300}).status_code == 503
    assert app.state.player.job is None


@pytest.mark.parametrize("operation", ["remove", "watched"])
def test_history_management_clears_only_selected_record_and_account(api, operation):
    client, app, data = api
    app.state.auth.token = TOKEN
    original = {"7": {"123": {"id": "123", "position": 30, "updated_at": 1},
                       "456": {"id": "456", "position": 40, "updated_at": 2}},
                "other": {"123": {"id": "123", "position": 50, "updated_at": 3}}}
    write_json(data / "history.json", original)
    response = client.post("/api/history/update", headers=HEADERS, json={"video_id": "123", "operation": operation})
    assert response.status_code == 200
    assert response.json()["state"] == ("removed" if operation == "remove" else "watched")
    remaining = read_json(data / "history.json")
    assert remaining["7"] == {"456": original["7"]["456"]}
    assert remaining["other"] == original["other"]
    assert History(data).position("7", "123") == 0
    assert client.post("/api/history/update", headers=HEADERS, json={"video_id": "123", "operation": operation}).status_code == 200
    assert read_json(data / "history.json") == remaining


def test_history_management_does_not_interrupt_playback(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    client.post("/api/player/heartbeat", headers=HEADERS, json={"job_id": job["id"], "position": 500})
    for operation in ("remove", "watched"):
        response = client.post("/api/history/update", headers=HEADERS, json={"video_id": VIDEO["id"], "operation": operation})
        assert response.status_code == 409
        assert app.state.player.job["id"] == job["id"]
        assert History(data).position("7", VIDEO["id"]) == 500
    assert client.post("/api/history/update", headers=HEADERS, json={"video_id": "999", "operation": "remove"}).status_code == 200
    assert app.state.player.job["id"] == job["id"]


@pytest.mark.parametrize("body", [{"video_id": "../123", "operation": "remove"},
                                  {"video_id": "123", "operation": "delete_all"}])
def test_history_management_rejects_bad_requests(api, body):
    client, _, data = api
    assert client.post("/api/history/update", headers=HEADERS, json=body).status_code == 422
    assert not (data / "history.json").exists()


def test_history_management_requires_pairing_and_login(api):
    client, _, data = api
    body = {"video_id": "123", "operation": "remove"}
    assert client.post("/api/history/update", json=body).status_code == 401
    assert client.post("/api/history/update", headers=HEADERS, json=body).status_code == 401
    assert not (data / "history.json").exists()


@pytest.mark.parametrize("status", [404, 502, 403])
def test_only_missing_video_gets_cleanup_error_code(api, monkeypatch, status):
    from fastapi import HTTPException
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / "playback.json", {"token": "web-secret"})
    def unavailable(video_id):
        raise HTTPException(status, "Video lookup failed.")
    monkeypatch.setattr(app.state.auth, "video", unavailable)
    monkeypatch.setattr(app.state.player, "start_vod", lambda *_: pytest.fail("Unavailable video must not start"))
    response = client.post("/api/vod/play", headers=HEADERS, json={"video_id": "123"})
    assert response.status_code == status
    if status == 404:
        assert response.json()["detail"]["code"] == "vod_unavailable"
    else:
        assert "vod_unavailable" not in response.text
    assert not (data / "history.json").exists()
