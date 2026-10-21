import io
import json

from server.storage import read_json, write_json


def test_migrated_unicode_data_survives_a_non_utf8_default(tmp_path, monkeypatch):
    original_open = io.open

    def windows_default(file, mode='r', buffering=-1, encoding=None, errors=None, newline=None, **kwargs):
        if 'b' not in mode and encoding in (None, 'locale'):
            encoding = 'cp1252'
        return original_open(file, mode, buffering, encoding, errors, newline, **kwargs)

    path = tmp_path / 'history.json'
    expected = {'title': '中文录像 🎮', 'channel': 'channel', 'position': 123}
    path.write_bytes(json.dumps(expected, ensure_ascii=False).encode('utf-8'))
    monkeypatch.setattr(io, 'open', windows_default)
    assert read_json(path) == expected
    expected['title'] = '下一场直播 🎉'
    write_json(path, expected)
    assert json.loads(path.read_bytes().decode('utf-8')) == expected
    assert read_json(path) == expected
