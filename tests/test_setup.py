import json
import zipfile

import pytest

from server import setup
from server.storage import read_json, write_json


def test_setup_generates_installable_zip_without_twitch_credentials(tmp_path, monkeypatch):
    root = tmp_path / "project"
    data = root / "data"
    roku = root / "roku"
    roku.mkdir(parents=True)
    (roku / "manifest").write_text("title=Test")
    (roku / "config.example.json").write_text("{}")
    write_json(data / "playback.json", {"token": "must-not-be-packaged"})
    answers = iter(["testclientid", "http://192.168.1.20:8787"])
    monkeypatch.setattr(setup, "ROOT", root)
    monkeypatch.setattr(setup, "DATA", data)
    monkeypatch.setattr("builtins.input", lambda prompt: next(answers))
    setup.configure()
    settings = read_json(data / "settings.json")
    assert len(settings["app_key"]) >= 32
    assert (data / "settings.json").stat().st_mode & 0o777 == 0o600
    with zipfile.ZipFile(root / "dist/roku-twitch.zip") as archive:
        assert set(archive.namelist()) == {"config.json", "manifest"}
        config = json.loads(archive.read("config.json"))
        assert config["appKey"] == settings["app_key"]
        assert "must-not-be-packaged" not in archive.read("config.json").decode()


def test_setup_does_not_overwrite_existing_login_with_new_client_id(tmp_path, monkeypatch):
    data = tmp_path / "data"
    write_json(data / "settings.json", {"client_id": "old", "app_key": "old-key"})
    write_json(data / "account.json", {"access_token": "old-token"})
    answers = iter(["new", "http://192.168.1.20:8787"])
    monkeypatch.setattr(setup, "ROOT", tmp_path)
    monkeypatch.setattr(setup, "DATA", data)
    monkeypatch.setattr("builtins.input", lambda prompt: next(answers))
    with pytest.raises(SystemExit, match="Sign out"):
        setup.configure()
    assert read_json(data / "settings.json")["client_id"] == "old"
