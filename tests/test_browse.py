import httpx
import pytest
from fastapi import HTTPException

from server.auth import Auth
from server.storage import write_json
from tests.test_app import api
from tests.test_auth import IDENTITY, TOKEN
from tests.test_vod import HEADERS, VIDEO


def test_search_uses_login_query_and_pagination_without_follow_scope(tmp_path):
    requests = []
    def handle(request):
        requests.append(request)
        if request.url.path.endswith('validate'):
            return httpx.Response(200, json=IDENTITY)
        assert request.url.path.endswith('search/channels')
        assert request.url.params['query'] == 'name + space'
        assert request.url.params['live_only'] == 'false'
        assert request.url.params['first'] == '20'
        if request.url.params.get('after'):
            assert request.url.params['after'] == 'a+/='
            return httpx.Response(200, json={'data': []})
        return httpx.Response(200, json={'data': [
            {'id': '1', 'broadcaster_login': 'online', 'display_name': 'Online', 'is_live': True, 'title': 'Game'},
            {'id': '2', 'broadcaster_login': 'offline', 'display_name': 'Offline', 'is_live': False, 'title': 'Old title'}
        ], 'pagination': {'cursor': 'a+/='}})
    write_json(tmp_path / 'account.json', TOKEN)
    auth = Auth(tmp_path, 'app', http=httpx.Client(transport=httpx.MockTransport(handle)))
    result = auth.search_channels('name + space')
    assert result['channels'][0]['live'] and result['channels'][0]['title'] == 'Game'
    assert not result['channels'][1]['live'] and result['channels'][1]['title'] == ''
    assert auth.search_channels('name + space', result['cursor']) == {'channels': [], 'cursor': ''}
    auth.http.close()


def test_search_errors_are_not_empty_results(tmp_path):
    auth = Auth(tmp_path, 'app')
    auth.helix = lambda *_: httpx.Response(429)
    with pytest.raises(HTTPException) as error:
        auth.search_channels('channel')
    assert error.value.status_code == 502
    auth.http.close()


def test_search_route_auth_and_validation(api, monkeypatch):
    client, app, _ = api
    assert client.get('/api/search?q=name').status_code == 401
    assert client.get('/api/search?q=name', headers=HEADERS).status_code == 401
    app.state.auth.token = TOKEN
    for query in ('', 'x' * 101):
        assert client.get('/api/search', params={'q': query}, headers=HEADERS).status_code == 422
    assert client.get('/api/search?q=%20%20', headers=HEADERS).status_code == 400
    seen = []
    monkeypatch.setattr(app.state.auth, 'search_channels', lambda q, c: seen.append((q, c)) or {'channels': [], 'cursor': ''})
    assert client.get('/api/search', params={'q': ' name ', 'cursor': 'a+/='}, headers=HEADERS).status_code == 200
    assert seen == [('name', 'a+/=')]


def test_vod_list_progress_is_account_scoped_and_clamped(api, monkeypatch):
    client, app, data = api
    app.state.auth.token = TOKEN
    monkeypatch.setattr(app.state.auth, 'videos', lambda *_: {'videos': [Auth.video_info(VIDEO),
        {**Auth.video_info(VIDEO), 'id': '999'}], 'cursor': ''})
    write_json(data / 'history.json', {'7': {'12345': {'position': 90000}}, '8': {'12345': {'position': 50}}})
    videos = client.get('/api/videos/channel', headers=HEADERS).json()['videos']
    assert videos[0]['position'] == 7384 and videos[1]['position'] == 0
    app.state.auth.identity = {**IDENTITY, 'user_id': '8'}
    app.state.auth.checked_at = app.state.auth.clock()
    assert client.get('/api/videos/channel', headers=HEADERS).json()['videos'][0]['position'] == 50
    app.state.auth.identity['user_id'] = '9'
    assert client.get('/api/videos/channel', headers=HEADERS).json()['videos'][0]['position'] == 0
