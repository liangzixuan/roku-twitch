import stat

import pytest

from server.favorites import Favorites
from server.storage import read_json
from tests.test_app import api
from tests.test_auth import IDENTITY, TOKEN


HEADERS = {"X-App-Key": "pairing-secret"}


def test_favorites_persist_by_account_and_id(tmp_path):
    favorites = Favorites(tmp_path)
    assert favorites.ids("7") == set()
    favorites.set_pinned("7", "123", True)
    favorites.set_pinned("7", "123", True)
    favorites.set_pinned("8", "456", True)
    restored = Favorites(tmp_path)
    assert restored.ids("7") == {"123"}
    assert restored.ids("8") == {"456"}
    restored.set_pinned("7", "123", False)
    restored.set_pinned("7", "123", False)
    assert restored.ids("7") == set()
    assert restored.ids("8") == {"456"}
    assert stat.S_IMODE(restored.path.stat().st_mode) == 0o600
    assert read_json(restored.path) == {"7": [], "8": ["456"]}


def test_pin_unpin_enriches_each_page_and_preserves_playback(api, monkeypatch):
    client, app, data = api
    auth = app.state.auth
    auth.token = TOKEN
    monkeypatch.setattr(auth, "follows", lambda cursor: {
        "channels": [{"id": "123", "login": "renamed", "live": False}, {"id": "456", "live": True}],
        "cursor": "page2" if not cursor else ""})
    # A favorite change must not invoke any playback operation.
    def unexpected(*args, **kwargs):
        pytest.fail("Favorite changes must not change playback")
    monkeypatch.setattr(app.state.player, "stop", unexpected)
    body = {"channel_id": "123", "pinned": True}
    response = client.post("/api/favorites", headers=HEADERS, json=body)
    assert response.status_code == 200 and response.json() == body
    for cursor in ("", "page2"):
        response = client.get("/api/follows", headers=HEADERS, params={"cursor": cursor})
        assert response.status_code == 200
        channels = response.json()["channels"]
        assert channels[0]["pinned"] is True and channels[1]["pinned"] is False
        assert "secret" not in response.text
    monkeypatch.setattr(auth, "validate", lambda: {**IDENTITY, "user_id": "8"})
    assert not client.get("/api/follows", headers=HEADERS).json()["channels"][0]["pinned"]
    client.post("/api/favorites", headers=HEADERS, json={"channel_id": "123", "pinned": False})
    assert Favorites(data).ids("7") == {"123"}
    monkeypatch.setattr(auth, "validate", lambda: IDENTITY)
    assert client.post("/api/favorites", headers=HEADERS, json={"channel_id": "123", "pinned": False}).status_code == 200
    assert Favorites(data).ids("7") == set()


def test_favorite_requires_pairing_and_login(api):
    client, _, data = api
    body = {"channel_id": "123", "pinned": True}
    assert client.post("/api/favorites", json=body).status_code == 401
    assert client.post("/api/favorites", headers=HEADERS, json=body).status_code == 401
    assert not (data / "favorites.json").exists()


@pytest.mark.parametrize("body", [
    {}, {"channel_id": "../123", "pinned": True}, {"channel_id": "", "pinned": True},
    {"channel_id": "1" * 21, "pinned": True}, {"channel_id": "123", "pinned": "false"},
    {"channel_id": "123", "pinned": 1}, {"channel_id": "123"},
])
def test_invalid_favorite_does_not_write(api, body):
    client, app, data = api
    app.state.auth.token = TOKEN
    assert client.post("/api/favorites", headers=HEADERS, json=body).status_code == 422
    assert not (data / "favorites.json").exists()
