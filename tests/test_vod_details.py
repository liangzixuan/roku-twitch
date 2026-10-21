import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from server.auth import Auth
from tests.test_app import api
from tests.test_history import start_vod
from tests.test_vod import HEADERS, VIDEO


@pytest.mark.parametrize('url', [None, '', 'http://static-cdn.jtvnw.net/a.jpg',
    'https://static-cdn.jtvnw.net.evil.test/a.jpg', 'https://user@static-cdn.jtvnw.net/a.jpg',
    'https://static-cdn.jtvnw.net:444/a.jpg', 'https://static-cdn.jtvnw.net/a.jpg?token=secret',
    'https://static-cdn.jtvnw.net/a.jpg\n', 'https://static-cdn.jtvnw.net/a.jpg#secret'])
def test_cover_rejects_non_public_or_unexpected_urls(url):
    assert Auth.video_thumbnail(url) == ''


def test_cover_resizes_template_and_survives_history(api, monkeypatch):
    client, app, _ = api
    job = start_vod(api, monkeypatch)
    metadata = Auth.video_info({**VIDEO, 'thumbnail_url': 'https://static-cdn.jtvnw.net/a/%{width}x%{height}.jpg'})
    assert metadata['thumbnail'] == 'https://static-cdn.jtvnw.net/a/640x360.jpg'
    monkeypatch.setattr(app.state.auth, 'video', lambda _: metadata)
    job = client.post('/api/vod/play', headers=HEADERS, json={'video_id': VIDEO['id']}).json()
    assert job['thumbnail'] == metadata['thumbnail']
    client.post('/api/player/heartbeat', headers=HEADERS, json={'job_id': job['id'], 'position': 120})
    saved = client.get('/api/history', headers=HEADERS).json()['videos'][0]
    assert saved['thumbnail'] == metadata['thumbnail'] and saved['created_at'] == metadata['created_at']
    assert 'url' not in saved and 'recovery_id' not in saved


def test_scene_references_existing_nodes_and_scripts():
    root = Path(__file__).resolve().parents[1] / 'roku'
    for xml in (root / 'components').glob('*.xml'):
        scene = ET.parse(xml)
        ids = {node.attrib['id'] for node in scene.iter() if 'id' in node.attrib}
        for script in scene.findall('script'):
            source = root / script.attrib['uri'].removeprefix('pkg:/')
            assert source.is_file()
            for name in re.findall(r'findNode\("([^"]+)"\)', source.read_text()):
                assert name in ids, f'{source.name} references missing node {name} in {xml.name}'
