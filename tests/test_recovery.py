import pytest
from fastapi import HTTPException

from server.auth import Auth
from server.recovery import Recovery
from server.storage import write_json
from tests.test_app import api
from tests.test_auth import IDENTITY, TOKEN
from tests.test_history import start_vod
from tests.test_vod import HEADERS, VIDEO


def recover(client, job, attempt=1, **fields):
    return client.post('/api/player/recover', headers=HEADERS,
                       json={'recovery_id': job['recovery_id'], 'attempt': attempt, **fields})


def test_vod_recovers_after_job_cleanup_with_position_and_quality(api, monkeypatch):
    client, app, _ = api
    old = start_vod(api, monkeypatch)
    app.state.quality.save('7', '720p60')
    app.state.player.stop()
    response = recover(client, old, position=1234.5)
    assert response.status_code == 200
    new = response.json()
    assert new['id'] != old['id']
    assert new['recovery_id'] == old['recovery_id']
    assert new['play_start'] == 1234.5 and new['quality'] == '720p60'
    assert app.state.player.job['owner_user_id'] == '7'
    assert app.state.history.position('7', VIDEO['id']) == 1234
    assert 'web-secret' not in response.text
    assert response.headers['Cache-Control'] == 'no-store'
    assert recover(client, old, position=2).json()['id'] == new['id']
    assert app.state.history.position('7', VIDEO['id']) == 1234
    assert recover(client, old, attempt=2, position=1300).json()['id'] != new['id']
    current = app.state.player.job['id']
    assert recover(client, old, attempt=1).status_code == 409
    assert app.state.player.job['id'] == current


def test_recovery_uses_saved_position_and_clamps_to_new_duration(api, monkeypatch):
    client, app, _ = api
    old = start_vod(api, monkeypatch)
    client.post('/api/player/heartbeat', headers=HEADERS, json={'job_id': old['id'], 'position': 500})
    assert recover(client, old).json()['play_start'] == 500
    assert recover(client, old, attempt=2, position=1e8).json()['play_start'] == VIDEO_DURATION - 2


VIDEO_DURATION = Auth.video_info(VIDEO)['duration_seconds']


def test_cancel_with_lost_recovery_response_stops_latest_job(api, monkeypatch):
    client, app, _ = api
    old = start_vod(api, monkeypatch)
    new = recover(client, old, position=60).json()
    assert new['id'] != old['id']
    response = client.post('/api/stop', headers=HEADERS, json={
        'job_id': old['id'], 'recovery_id': old['recovery_id'], 'position': 65})
    assert response.status_code == 200
    assert app.state.player.job is None and app.state.recovery.session is None
    assert app.state.history.position('7', VIDEO['id']) == 65
    assert recover(client, old).status_code == 409


def test_old_recovery_or_cancel_cannot_replace_new_selection(api, monkeypatch):
    client, app, _ = api
    old = start_vod(api, monkeypatch)
    new = start_vod(api, monkeypatch)
    assert old['recovery_id'] != new['recovery_id']
    assert recover(client, old).status_code == 409
    assert client.post('/api/stop', headers=HEADERS, json={
        'job_id': old['id'], 'recovery_id': old['recovery_id']}).status_code == 409
    assert app.state.player.job['id'] == new['id']


def test_quality_switch_retains_recovery_session(api, monkeypatch):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    response = client.post('/api/player/quality', headers=HEADERS, json={
        'job_id': job['id'], 'quality': '720p60', 'position': 100})
    assert response.json()['recovery_id'] == job['recovery_id']
    assert recover(client, job, position=110).json()['quality'] == '720p60'


@pytest.mark.parametrize('code', [401, 403, 404, 502])
def test_recovery_checks_current_video_access_before_restarting(api, monkeypatch, code):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    def fail(*_):
        raise HTTPException(code, 'Video lookup failed.')
    monkeypatch.setattr(app.state.auth, 'video', fail)
    assert recover(client, job, position=100).status_code == code
    assert app.state.player.job['id'] == job['id']
    assert app.state.recovery.session['attempt'] == 0


def test_recovery_requires_same_account_and_valid_playback_login(api, monkeypatch):
    client, app, data = api
    job = start_vod(api, monkeypatch)
    app.state.auth.identity = {**IDENTITY, 'user_id': 'other'}
    app.state.auth.checked_at = app.state.auth.clock()
    assert recover(client, job).status_code == 403
    app.state.auth.identity = IDENTITY
    (data / 'playback.json').unlink()
    assert recover(client, job).status_code == 409
    assert app.state.player.job['id'] == job['id']
    app.state.auth.clear_account()
    assert app.state.recovery.session is None and app.state.player.job is None
    assert recover(client, job).status_code == 401


def test_live_recovery_checks_online_status_and_keeps_quality(api, monkeypatch):
    client, app, data = api
    app.state.auth.token = TOKEN
    write_json(data / 'playback.json', {'token': 'web-secret'})
    calls = []
    def start(channel, token, quality):
        calls.append((channel, quality))
        app.state.player.job = {'id': str(len(calls)), 'state': 'starting', 'kind': 'live', 'channel': channel}
        return dict(app.state.player.job)
    monkeypatch.setattr(app.state.player, 'start', start)
    monkeypatch.setattr(app.state.auth, 'channel_status', lambda _: {'live': False})
    job = client.post('/api/play', headers=HEADERS, json={'channel': 'channel'}).json()
    assert recover(client, job).status_code == 410 and len(calls) == 1
    monkeypatch.setattr(app.state.auth, 'channel_status', lambda _: {'live': True})
    app.state.quality.save('7', '480p')
    assert recover(client, job).status_code == 200
    assert calls == [('channel', 'best'), ('channel', '480p')]
    assert app.state.player.job['recovery_id'] == job['recovery_id']


@pytest.mark.parametrize('fields', [ {'position': -1}, {'position': 'nan'}, {'attempt': 0},
    {'attempt': 1000001}, {'recovery_id': '../secret'} ])
def test_invalid_recovery_preserves_playback(api, monkeypatch, fields):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    body = {'recovery_id': job['recovery_id'], 'attempt': 1, **fields}
    assert client.post('/api/player/recover', headers=HEADERS, json=body).status_code == 422
    assert app.state.player.job['id'] == job['id']


def test_recovery_pairing_and_expiry(api, monkeypatch):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    assert client.post('/api/player/recover', json={'recovery_id': job['recovery_id'], 'attempt': 1}).status_code == 401
    app.state.recovery.session['touched'] -= 590
    assert client.post('/api/player/heartbeat', headers=HEADERS, json={'job_id': job['id']}).status_code == 200
    assert app.state.recovery.clock() - app.state.recovery.session['touched'] < 5
    app.state.recovery.session['touched'] -= 601
    assert recover(client, job).status_code == 409
    assert app.state.player.job['id'] == job['id']


def test_restart_does_not_accept_old_recovery_session():
    first = Recovery()
    first.begin('7', 'vod', '123')
    with pytest.raises(HTTPException) as error:
        Recovery().check(first.session['id'], '7')
    assert error.value.status_code == 409
