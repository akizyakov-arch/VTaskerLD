"""Exercise the compiled local HTTP adapter and CLI against a disposable database."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave

binary = Path(__file__).resolve().parents[1] / 'target/debug/vtracker'
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
base = 'http://127.0.0.1:8765'

def request(path, body=None, origin=base):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data)
    if data is not None:
        req.add_header('Origin', origin)
        req.add_header('Content-Type', 'application/json')
    return http.open(req, timeout=3)

with tempfile.TemporaryDirectory(prefix='vtracker-smoke-') as tmp:
    db = str(Path(tmp) / 'test.sqlite3')
    args = [str(binary), '--db', db]
    def cli(*cmd):
        return subprocess.check_output(args + list(cmd), text=True)
    cli('init')
    cli('init')
    person = cli('people', 'add', 'Антон').strip()
    meeting = int(cli('meeting', 'create', 'Планирование').strip())
    assert person == '1'
    assert json.loads(cli('export', str(meeting)))['transcript'] is None
    assert 'Планирование' in cli('export', str(meeting), '--format', 'txt')
    audio = Path(tmp) / 'input.wav'
    with wave.open(str(audio), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b'\x00\x00' * 1600)
    root = str(Path(tmp) / 'audio')
    imported = json.loads(cli('audio', 'import', str(meeting), str(audio), '--root', root))
    assert imported['frames'] == 1600
    cli('audio', 'recover', str(meeting), '--root', root)
    assert len(json.loads(cli('audio', 'list', str(meeting)))) == 1
    assert len(json.loads(cli('export', str(meeting)))['recordings']) == 1
    server = subprocess.Popen(args + ['serve'], stdout=subprocess.DEVNULL)
    try:
        for _ in range(50):
            if server.poll() is not None:
                raise RuntimeError('server exited during startup (port may be occupied)')
            try:
                with request('/api/status') as r:
                    assert json.load(r)['speech']['running'] is False
                break
            except urllib.error.URLError:
                time.sleep(0.1)
        else:
            raise RuntimeError('server did not become ready')
        with request('/') as r:
            assert 'VTASK' in r.read().decode()
        with request('/api/people', {'name': 'Участник 2'}) as r:
            assert json.load(r)['id'] == 2
        with request('/api/meetings', {'title': 'Обзор'}) as r:
            assert json.load(r)['id'] == 2
        with request('/api/jobs', {'meeting_id': meeting}) as r:
            assert json.load(r)['id'] == 1
        for path, body, origin, status in [
            ('/api/people', {'name': '  '}, base, 400),
            ('/api/jobs', {'meeting_id': meeting}, base, 400),
            ('/api/jobs', {'meeting_id': 999}, base, 400),
            ('/api/people', {'name': 'Blocked'}, 'https://example.com', 403),
        ]:
            try:
                request(path, body, origin)
                raise AssertionError('invalid request accepted')
            except urllib.error.HTTPError as error:
                assert error.code == status
        with request('/api/jobs') as r:
            assert json.load(r)[0]['status'] == 'pending'
    finally:
        server.terminate()
        server.wait(timeout=5)
    assert len(json.loads(cli('people', 'list'))) == 2
print('CLI + HTTP smoke passed: persistence, creation, export, queue and invalid requests')
