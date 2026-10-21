from urllib.parse import parse_qs

import httpx
import pytest
from fastapi import HTTPException

from server.auth import Auth, SCOPE, FOLLOW_SCOPE, LOGIN_SCOPES
from server.storage import read_json, write_json


IDENTITY = {"user_id": "7", "login": "viewer", "client_id": "app", "scopes": [SCOPE], "expires_in": 3600}
TOKEN = {"access_token": "app-secret", "refresh_token": "refresh-secret", "scope": [SCOPE]}


def client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_device_poll_throttle_pending_slowdown_and_success(tmp_path):
    now, token_calls = [1000], []

    def handle(request):
        if request.url.path.endswith("/device"):
            assert parse_qs(request.content.decode())["scopes"] == [LOGIN_SCOPES]
            return httpx.Response(200, json={"device_code": "private-code", "user_code": "ABCDEF", "verification_uri": "https://www.twitch.tv/activate", "expires_in": 100, "interval": 5})
        if request.url.path.endswith("/validate"):
            return httpx.Response(200, json={**IDENTITY, "scopes": [SCOPE, FOLLOW_SCOPE]})
        token_calls.append(request)
        if len(token_calls) == 1:
            return httpx.Response(400, json={"message": "authorization_pending"})
        if len(token_calls) == 2:
            return httpx.Response(400, json={"message": "slow_down"})
        return httpx.Response(200, json=TOKEN)

    auth = Auth(tmp_path, "app", client(handle), clock=lambda: now[0])
    result = auth.start()
    assert "device_code" not in result
    assert auth.poll(result["id"])["state"] == "pending"
    assert not token_calls
    now[0] += 5
    assert auth.poll(result["id"])["interval"] == 5
    now[0] += 5
    assert auth.poll(result["id"])["interval"] == 10
    now[0] += 9
    assert auth.poll(result["id"])["state"] == "pending"
    assert len(token_calls) == 2
    now[0] += 1
    assert auth.poll(result["id"]) == {"state": "complete", "login": "viewer"}
    assert read_json(tmp_path / "account.json") == TOKEN
    assert (tmp_path / "account.json").stat().st_mode & 0o777 == 0o600
    assert auth.pending is None


@pytest.mark.parametrize("error,state", [("access_denied", "denied"), ("invalid device code", "expired")])
def test_terminal_device_errors(tmp_path, error, state):
    auth = Auth(tmp_path, "app", client(lambda r: httpx.Response(400, json={"message": error})), clock=lambda: 10)
    auth.pending = {"id": "login", "expires_at": 20, "next_poll": 0, "interval": 5, "device_code": "secret"}
    assert auth.poll("login")["state"] == state
    assert auth.pending is None


def test_device_expiry_does_not_call_twitch(tmp_path):
    def unexpected(request):
        pytest.fail("Expired code must not be sent to Twitch")
    auth = Auth(tmp_path, "app", client(unexpected), clock=lambda: 20)
    auth.pending = {"id": "login", "expires_at": 20}
    assert auth.poll("login") == {"state": "expired"}


def test_rotated_refresh_token_survives_restart(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)
    requests = []

    def handle(request):
        requests.append(request)
        if request.url.path.endswith("/token"):
            data = parse_qs(request.content.decode())
            assert data["refresh_token"] == ["refresh-secret"]
            assert "client_secret" not in data
            return httpx.Response(200, json={**TOKEN, "access_token": "new-secret", "refresh_token": "rotated"})
        if request.headers["Authorization"] == "OAuth app-secret":
            return httpx.Response(401)
        return httpx.Response(200, json=IDENTITY)

    auth = Auth(tmp_path, "app", client(handle))
    assert auth.validate()["user_id"] == "7"
    assert read_json(tmp_path / "account.json")["refresh_token"] == "rotated"
    restarted = Auth(tmp_path, "app", client(handle))
    assert restarted.identity is None
    assert restarted.validate()["login"] == "viewer"


def test_hourly_validation_and_revocation(tmp_path):
    now, calls = [10000], []
    write_json(tmp_path / "account.json", TOKEN)

    def handle(request):
        calls.append(request)
        if now[0] == 10000:
            return httpx.Response(200, json=IDENTITY)
        return httpx.Response(401)

    auth = Auth(tmp_path, "app", client(handle), clock=lambda: now[0])
    auth.validate()
    now[0] += 3499
    auth.validate()
    assert len(calls) == 1
    now[0] += 1
    with pytest.raises(HTTPException) as error:
        auth.validate()
    assert error.value.status_code == 401
    assert not (tmp_path / "account.json").exists()


def test_playback_must_match_logged_in_account(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)
    write_json(tmp_path / "playback.json", {"token": "web-secret"})

    def handle(request):
        value = IDENTITY if request.headers["Authorization"] == "OAuth app-secret" else {**IDENTITY, "user_id": "different"}
        return httpx.Response(200, json=value)

    auth = Auth(tmp_path, "app", client(handle))
    with pytest.raises(HTTPException) as error:
        auth.playback_identity()
    assert error.value.status_code == 409


def test_subscription_does_not_claim_ad_free(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)

    def handle(request):
        if request.url.path.endswith("validate"):
            return httpx.Response(200, json=IDENTITY)
        if request.url.path.endswith("users"):
            return httpx.Response(200, json={"data": [{"id": "9"}]})
        assert request.url.params["user_id"] == "7"
        assert request.url.params["broadcaster_id"] == "9"
        return httpx.Response(200, json={"data": [{"tier": "1000"}]})

    auth = Auth(tmp_path, "app", client(handle))
    assert auth.subscription("channel") == {"channel": "channel", "subscribed": True, "ad_free": "unverified"}


def test_logout_clears_local_credentials_when_twitch_is_down(tmp_path):
    write_json(tmp_path / "account.json", TOKEN)
    write_json(tmp_path / "playback.json", {"token": "web-secret"})

    def fail(request):
        raise httpx.ConnectError("offline")

    auth = Auth(tmp_path, "app", client(fail))
    result = auth.logout()
    assert not result["app_token_revoked"]
    assert auth.token is None
    assert not (tmp_path / "playback.json").exists()
    assert not (tmp_path / "account.json").exists()
