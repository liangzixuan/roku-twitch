import json
import subprocess

import pytest
from fastapi import HTTPException
from streamlink import Streamlink
from streamlink.plugins.twitch import TwitchHLSStream

from server.player import Player
from server.quality import QualityPreference, read_variants, quality_choices
from server.storage import write_json
from tests.test_app import api
from tests.test_auth import IDENTITY
from tests.test_history import start_vod
from tests.test_vod import URL, HEADERS, VIDEO


def test_catalog_uses_real_streamlink_json_and_only_video_qualities(tmp_path):
    stream = TwitchHLSStream(Streamlink(), URL).__json__()
    path = tmp_path / 'catalog.json'
    write_json(path, {'streams': {'best': stream, '1080p60': stream, '720p60': stream,
        '720p': stream, 'audio_only': stream, 'worst': stream, 'bad;cmd': stream,
        '480p': {'type': 'hls', 'url': 'https://evil.test/a'},
        '360p': {'type': 'http', 'url': URL}}})
    variants = read_variants(path)
    assert quality_choices(variants) == ['best', '1080p60', '720p60', '720p']
    assert variants['best'] == URL
    assert 'headers' not in str(variants)
    path.write_text('invalid')
    assert read_variants(path) == {}
    path.write_text('[]')
    assert read_variants(path) == {}
    path.write_text('x' * 2_000_001)
    assert read_variants(path) == {}


def test_quality_preference_survives_restart_and_separates_accounts(tmp_path):
    p = QualityPreference(tmp_path)
    assert p.get('7') == 'best'
    p.save('7', '720p60')
    p.save('8', '480p')
    assert QualityPreference(tmp_path).get('7') == '720p60'
    assert p.get('8') == '480p'
    assert p.path.stat().st_mode & 0o777 == 0o600


def test_vod_switch_preserves_position_and_remembers_preference(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    result = client.get('/api/player/qualities', params={'job_id': job['id']}, headers=HEADERS)
    assert result.status_code == 200
    assert result.json()['qualities'] == ['best', '1080p60', '720p60']
    assert 'https://' not in result.text and 'secret' not in result.text
    body = {'job_id': job['id'], 'quality': '720p60', 'position': 321.5}
    result = client.post('/api/player/quality', headers=HEADERS, json=body)
    assert result.status_code == 200
    assert result.json()['play_start'] == 321.5
    assert result.json()['url'] == URL.replace('chunked', '720p60')
    assert app.state.history.position('7', VIDEO['id']) == 321
    assert QualityPreference(data).get('7') == '720p60'
    job = start_vod(api, monkeypatch, resume=True)
    assert job['quality'] == '720p60' and job['play_start'] == 321
    app.state.quality.save('7', '480p')
    assert start_vod(api, monkeypatch)['quality'] == 'best'
    assert QualityPreference(data).get('7') == '480p'


@pytest.mark.parametrize('body,status', [
    ({'quality': '480p', 'position': 300}, 409),
    ({'quality': '720p60'}, 400),
    ({'quality': '720p60', 'position': -1}, 422),
    ({'quality': '720p60', 'position': 'nan'}, 422),
    ({'quality': '../private', 'position': 300}, 422),
])
def test_bad_switch_preserves_current_session(api, monkeypatch, body, status):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    response = client.post('/api/player/quality', headers=HEADERS, json={'job_id': job['id'], **body})
    assert response.status_code == status
    assert app.state.player.job['url'] == URL
    assert not (data / 'quality.json').exists()


def test_quality_rejects_stale_or_other_account_session(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    for job_id in ('old', job['id']):
        if job_id == job['id']:
            app.state.auth.identity = {**IDENTITY, 'user_id': 'other'}
            app.state.auth.checked_at = app.state.auth.clock()
        assert client.get('/api/player/qualities', headers=HEADERS, params={'job_id': job_id}).status_code == 409
        assert client.post('/api/player/quality', headers=HEADERS, json={'job_id': job_id, 'quality': '720p60', 'position': 10}).status_code == 409
    assert app.state.player.job['url'] == URL
    assert not (data / 'quality.json').exists()


def test_quality_requires_pairing(api):
    client, _, _ = api
    assert client.get('/api/player/qualities?job_id=test').status_code == 401
    assert client.post('/api/player/quality', json={'job_id': 'test', 'quality': 'best'}).status_code == 401


class CatalogProcess:
    def __init__(self, code):
        self.code = code
    def poll(self):
        return self.code
    def wait(self, timeout=None):
        return self.code
    def kill(self):
        self.code = -9
    def terminate(self):
        self.code = -15


def live_player(tmp_path):
    now = [100]
    p = Player(tmp_path, clock=lambda: now[0])
    p.job = {'id': 'livejob', 'kind': 'live', 'channel': 'channel', 'state': 'ready', 'quality': '480p', 'started_at': 100}
    (p.root / 'livejob').mkdir(parents=True)
    return p, now


def test_live_discovery_failure_does_not_stop_playback_and_can_retry(tmp_path, monkeypatch):
    p, now = live_player(tmp_path)
    process = CatalogProcess(None)
    monkeypatch.setattr(subprocess, 'Popen', lambda *_args, **_kwargs: process)
    assert p.qualities()['state'] == 'starting'
    now[0] += 46
    with pytest.raises(HTTPException) as error:
        p.qualities()
    assert error.value.status_code == 502 and process.code == -9
    assert p.job['id'] == 'livejob' and p.catalog_process is None
    def spawn(args, **kwargs):
        assert '--json' in args and '--twitch-supported-codecs' in args
        kwargs['stdout'].write(json.dumps({'streams': {'best': {'type': 'hls', 'url': URL}, '720p60': {'type': 'hls', 'url': URL}}}).encode())
        kwargs['stdout'].flush()
        return CatalogProcess(0)
    monkeypatch.setattr(subprocess, 'Popen', spawn)
    assert p.qualities() == {'state': 'ready', 'quality': 'best', 'qualities': ['best', '720p60']}
    assert p.job['id'] == 'livejob'
    p.stop()


def test_stop_terminates_pending_quality_discovery(tmp_path, monkeypatch):
    p, _ = live_player(tmp_path)
    process = CatalogProcess(None)
    monkeypatch.setattr(subprocess, 'Popen', lambda *_args, **_kwargs: process)
    p.qualities()
    p.stop()
    assert process.code == -15 and p.catalog_process is None and not p.root.exists()


def test_live_switch_preserves_catalog_and_uses_selected_quality(tmp_path, monkeypatch):
    p, _ = live_player(tmp_path)
    p.variants = {'best': URL, '720p60': URL}
    calls = []
    def start(channel, token, quality):
        calls.append((channel, token, quality))
        p.stop()
        p.job = {'id': 'new', 'kind': 'live', 'state': 'starting', 'quality': quality}
        return p.job
    monkeypatch.setattr(p, 'start', start)
    assert p.change_quality('720p60', 'secret')['id'] == 'new'
    assert calls == [('channel', 'secret', '720p60')]
    assert p.variants == {'best': URL, '720p60': URL}
