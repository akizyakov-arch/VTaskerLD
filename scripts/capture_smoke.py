"""Validate web/CLI recording lifecycle using synthetic audio (no microphone)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

repo = Path(__file__).resolve().parents[1]
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
base = 'http://127.0.0.1:8765'
def api(path, body=None):
    req = urllib.request.Request(base + '/api/' + path,
                                 data=None if body is None else json.dumps(body).encode())
    if body is not None:
        req.add_header('Origin', base)
        req.add_header('Content-Type', 'application/json')
    with http.open(req, timeout=3) as response:
        return json.load(response)

with tempfile.TemporaryDirectory(prefix='vtracker-capture-') as tmp:
    args = [str(repo / 'target/debug/vtracker'), '--db', str(Path(tmp) / 'data.sqlite3')]
    env = os.environ.copy()
    env['VTRACKER_CAPTURE_BIN'] = str(repo / 'tests/fixtures/capture.py')
    subprocess.check_call(args + ['init'])
    meeting = int(subprocess.check_output(args + ['meeting', 'create', 'Synthetic audio']))
    server = subprocess.Popen(args + ['serve'], env=env)
    try:
        for _ in range(50):
            assert server.poll() is None, 'server exited (port occupied?)'
            try:
                api('status')
                break
            except urllib.error.URLError:
                time.sleep(.1)
        else:
            raise AssertionError('server did not start')
        api('workspace/action', {'op':'settings','data':{'auto_process':False}})
        subprocess.check_call(args + ['meeting', 'start', str(meeting), '--seconds', '60'])
        for _ in range(50):
            state = api('status')['recording']['active']
            if state and state['state'] == 'recording':
                break
            time.sleep(.1)
        else:
            raise AssertionError('helper did not become ready')
        for _ in range(50):
            exported = json.loads(subprocess.check_output(args + ['export', str(meeting)]))
            if len(exported['fragments']) == 1:
                break
            time.sleep(.1)
        else:
            raise AssertionError('first fragment was not saved while recording')
        # HTTP must remain responsive throughout recording.
        assert api('meetings')[0]['status'] == 'recording'
        subprocess.check_call(args + ['meeting', 'stop', str(meeting)])
        for _ in range(50):
            status = api('status')['recording']
            if status['active'] is None:
                assert status['last']['state'] == 'completed', status
                break
            time.sleep(.1)
        else:
            raise AssertionError('stop did not finish')
        exported = json.loads(subprocess.check_output(args + ['export', str(meeting)]))
        assert exported['meeting']['status'] == 'completed'
        assert exported['recordings'][0]['frames'] == 1600
        assert len(exported['recordings']) == 1  # repeated silence shares a blob
        assert len(exported['fragments']) == 2  # both occurrences survive
        assert exported['fragments'][1]['start_frame'] == 1600
        try:
            api('recording/start', {'meeting_id': meeting, 'seconds': 60})
            raise AssertionError('completed meeting restarted')
        except urllib.error.HTTPError as error:
            assert error.code == 400
    finally:
        server.terminate()
        server.wait(timeout=5)
print('Synthetic capture: CLI start/stop, responsive HTTP, completed meeting and two timed fragments and deduplicated WAV passed')
