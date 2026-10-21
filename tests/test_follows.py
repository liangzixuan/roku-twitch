from urllib.parse import parse_qs

import httpx
import pytest
from fastapi import HTTPException

from server.auth import Auth, FOLLOW_SCOPE, LOGIN_SCOPES
from server.storage import read_json, write_json
from tests.test_app import api
from tests.test_auth import IDENTITY, TOKEN

IDENTITY_FOLLOWS = {**IDENTITY, "scopes": [*IDENTITY["scopes"], FOLLOW_SCOPE]}
HEADERS = {"X-App-Key": "pairing-secret"}


def follow(n):
    return {"broadcaster_id": str(n), "broadcaster_login": f"channel{n}", "broadcaster_name": f"Channel {n}"}


def test_follows_pages_and_live_counts(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)

    def handle(r):
        if r.url.path.endswith("validate"):
            return httpx.Response(200, json=IDENTITY_FOLLOWS)
        if r.url.path.endswith("channels/followed"):
            assert r.url.params["user_id"] == "7"
            assert r.url.params["first"] == "100"
            if r.url.params.get("after"):
                assert r.url.params["after"] == "next+page/=="
                return httpx.Response(200, json={"data": [follow(101)], "pagination": {}})
            return httpx.Response(200, json={"data": [follow(n) for n in range(100)],
                                            "pagination": {"cursor": "next+page/=="}})
        if r.url.path.endswith("users"):
            ids = r.url.params.get_list("id")
            assert len(ids) in (1, 100)
            return httpx.Response(200, json={"data": [{"id": user_id, "profile_image_url": f"https://static-cdn.jtvnw.net/{user_id}.png"} for user_id in ids]})
        assert r.url.path.endswith("streams")
        ids = r.url.params.get_list("user_id")
        assert len(ids) in (1, 100)
        return httpx.Response(200, json={"data": [{"user_id": ids[-1], "viewer_count": 900, "title": "Live title", "game_name": "A game"}]})

    auth = Auth(tmp_path, "app", http=httpx.Client(transport=httpx.MockTransport(handle)))
    page = auth.follows()
    assert len(page["channels"]) == 100
    assert page["channels"][0]["live"] is False
    assert page["channels"][-1]["viewers"] == 900
    assert page["channels"][-1]["live"] is True
    assert page["channels"][-1]["title"] == "Live title"
    assert page["channels"][-1]["game"] == "A game"
    assert page["channels"][0]["title"] == "" and page["channels"][0]["game"] == ""
    assert page["channels"][0]["avatar"] == "https://static-cdn.jtvnw.net/0.png"
    page2 = auth.follows(page["cursor"])
    assert page2["channels"][0]["login"] == "channel101"
    assert page2["cursor"] == ""


def test_missing_permission_preserves_login_and_playback(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)
    write_json(tmp_path / "playback.json", {"token": "web-secret"})
    auth = Auth(tmp_path, "app", http=httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json=IDENTITY))))
    with pytest.raises(HTTPException) as error:
        auth.follows()
    assert error.value.status_code == 403
    assert read_json(tmp_path / "account.json") == TOKEN
    assert read_json(tmp_path / "playback.json")["token"] == "web-secret"


@pytest.mark.parametrize("outcome", ["success", "other_account", "missing_scope", "denied", "network"])
def test_permission_upgrade_is_atomic(tmp_path, outcome):
    now = [100]
    write_json(tmp_path / "account.json", TOKEN)
    write_json(tmp_path / "playback.json", {"token": "web-secret"})
    new_token = {**TOKEN, "access_token": "new-secret"}

    def handle(r):
        if r.url.path.endswith("device"):
            assert parse_qs(r.content.decode())["scopes"] == [LOGIN_SCOPES]
            return httpx.Response(200, json={"device_code": "code", "user_code": "ABC",
                "verification_uri": "https://www.twitch.tv/activate", "expires_in": 100, "interval": 5})
        if r.url.path.endswith("token"):
            if outcome == "denied":
                return httpx.Response(400, json={"message": "access_denied"})
            return httpx.Response(200, json=new_token)
        if r.headers["Authorization"] == "OAuth app-secret":
            return httpx.Response(200, json=IDENTITY)
        if outcome == "network":
            raise httpx.ConnectError("offline")
        identity = IDENTITY_FOLLOWS
        if outcome == "other_account":
            identity = {**identity, "user_id": "other"}
        if outcome == "missing_scope":
            identity = IDENTITY
        return httpx.Response(200, json=identity)

    auth = Auth(tmp_path, "app", http=httpx.Client(transport=httpx.MockTransport(handle)), clock=lambda: now[0])
    code = auth.start()
    assert auth.token == TOKEN
    now[0] += 5
    if outcome in ("other_account", "missing_scope", "network"):
        with pytest.raises(HTTPException):
            auth.poll(code["id"])
    else:
        assert auth.poll(code["id"])["state"] == ("complete" if outcome == "success" else "denied")
    assert auth.token == (new_token if outcome == "success" else TOKEN)
    assert read_json(tmp_path / "account.json") == auth.token
    assert read_json(tmp_path / "playback.json") == {"token": "web-secret"}


def test_empty_follows_does_not_query_streams(tmp_path):
    auth = Auth(tmp_path, "app")
    auth.validate = lambda: IDENTITY_FOLLOWS
    def helix(endpoint, params):
        assert endpoint == "channels/followed"
        return httpx.Response(200, json={"data": [], "pagination": {}})
    auth.helix = helix
    assert auth.follows() == {"channels": [], "cursor": ""}
    auth.http.close()


@pytest.mark.parametrize("live", [True, False])
def test_channel_status_rechecks_twitch(tmp_path, live):
    auth = Auth(tmp_path, "app")
    def helix(endpoint, params):
        assert endpoint == "streams"
        assert params["user_login"] == "channel"
        return httpx.Response(200, json={"data": [{"user_id": "1"}] if live else []})
    auth.helix = helix
    assert auth.channel_status("channel") == {"channel": "channel", "live": live}
    auth.http.close()


@pytest.mark.parametrize("path", ["/api/follows", "/api/channel/channel"])
def test_follow_routes_require_pairing(api, path):
    client, _, _ = api
    assert client.get(path).status_code == 401


def test_account_reports_upgrade_without_losing_playback(api):
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / "playback.json", {"token": "web-secret"})
    account = client.get("/api/account", headers=HEADERS).json()
    assert account["signed_in"] and account["playback_ready"]
    assert not account["follows_ready"]
    assert client.get("/api/follows", headers=HEADERS).status_code == 403
    assert app.state.auth.token == TOKEN
    assert client.get("/api/channel/bad-name", headers=HEADERS).status_code == 400


def test_avatar_cache_refreshes_after_one_hour(tmp_path):
    calls, now = [], [100]
    auth = Auth(tmp_path, "app", clock=lambda: now[0])
    def helix(endpoint, params):
        assert endpoint == "users"
        calls.append(params["id"])
        return httpx.Response(200, json={"data": [{"id": i, "profile_image_url": f"https://static-cdn.jtvnw.net/{i}.png"} for i in params["id"]]})
    auth.helix = helix
    assert auth.avatars(["1"])["1"].endswith("1.png")
    now[0] += 60
    auth.avatars(["1", "2"])
    assert calls == [["1"], ["2"]]
    now[0] += 3600
    auth.avatars(["1", "2"])
    assert calls[-1] == ["1", "2"]
    auth.http.close()


@pytest.mark.parametrize("url", ["http://static-cdn.jtvnw.net/1.png", "https://elsewhere.test/a", "https://[invalid", "https://user:pass@static-cdn.jtvnw.net/a"])
def test_avatar_urls_only_use_public_twitch_cdn(tmp_path, url):
    auth = Auth(tmp_path, "app")
    auth.helix = lambda *_: httpx.Response(200, json={"data": [{"id": "1", "profile_image_url": url}]})
    assert auth.avatars(["1"]) == {"1": ""}
    auth.http.close()


@pytest.mark.parametrize("failure", ["network", "rate_limit"])
def test_missing_avatars_do_not_hide_live_channels(tmp_path, failure):
    auth = Auth(tmp_path, "app")
    auth.validate = lambda: IDENTITY_FOLLOWS
    def helix(endpoint, params):
        if endpoint == "channels/followed":
            return httpx.Response(200, json={"data": [follow(1)]})
        if endpoint == "streams":
            return httpx.Response(200, json={"data": [{"user_id": "1", "viewer_count": 5, "title": "Live", "game_name": "Game"}]})
        if failure == "network":
            raise HTTPException(502, "Offline")
        return httpx.Response(429)
    auth.helix = helix
    channel = auth.follows()["channels"][0]
    assert channel["live"] and channel["viewers"] == 5 and channel["avatar"] == ""
    auth.http.close()
