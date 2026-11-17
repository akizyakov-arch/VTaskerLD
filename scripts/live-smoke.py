"""Isolated end-to-end Live -> preview -> stop -> final check. Uses a public WAV, never microphone."""
import argparse
import json
import os
from pathlib import Path
import socket
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--real-model', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='vtask-live-smoke-') as tmp:
    tmp = Path(tmp)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('VTRACKER_'):
            del env[key]
    tools = Path.home() / '.local/share/vtracker'
    sample = tools / 'whisper.cpp/samples/jfk.wav'
    if not sample.is_file():
        raise SystemExit('Public test WAV not installed: ' + str(sample))
    if args.real_model:
        engine = tools / 'whisper.cpp/build/bin/whisper-cli'
        model = tools / 'models/ggml-large-v3-turbo-q5_0.bin'
    else:
        engine = root / 'tests/fixtures/whisper.py'
        model = tmp / 'model'
        model.write_bytes(b'FIXTURE')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    env.update(VTRACKER_PORT=str(port), VTRACKER_WHISPER_BIN=str(engine), VTRACKER_WHISPER_MODEL=str(model),
               VTRACKER_FFMPEG_BIN=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg', VTRACKER_LANGUAGE='en',
               VTRACKER_CAPTURE_BIN=str(root / 'tests/fixtures/live_capture.py'), VTRACKER_LIVE_SAMPLE=str(sample))
    db = tmp / 'data.sqlite3'
    log = (tmp / 'server.log').open('w+')
    server = subprocess.Popen([str(root / 'target/debug/vtracker'), '--db', str(db), 'serve'], env=env,
                              stdout=log, stderr=log, start_new_session=True)
    def request(path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(base + '/api/' + path, data=data, headers={'Origin': base, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=5) as response:
            return json.load(response)
    def wait(predicate, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if server.poll() is not None:
                log.seek(0)
                raise AssertionError('Server exited: ' + log.read())
            try:
                result = predicate()
                if result:
                    return result
            except urllib.error.URLError:
                pass
            time.sleep(0.1)
        raise AssertionError('Timed out')
    try:
        wait(lambda: request('status'))
        meeting = request('meetings', {'title': 'Isolated public Live check'})['id']
        request('recording/start', {'meeting_id': meeting, 'seconds': 30, 'processing_mode': 'live', 'device_uid': 'public-replay'})
        began = time.monotonic()
        def preview():
            status = request('status')
            data = request('meeting/' + str(meeting))
            chunks = (data.get('live') or {}).get('chunks', [])
            completed = [c for c in chunks if c['state'] == 'completed' and c['segments']]
            if completed:
                assert status['recording']['active'], 'preview must precede recording stop'
                assert data['transcript'] is None, 'preview must not become final'
                return completed
        chunks = wait(preview)
        first_preview_ms = round((time.monotonic() - began) * 1000)
        # Let the complete public sentence reach disk before the final pass.
        # Short clips can end mid-word; that is exactly why the preview is preliminary.
        wait(lambda: (request('status')['recording']['active'] or {}).get('saved_ms', 0) >= 11000, 30)
        request('recording/stop', {'meeting_id': meeting})
        def final_result():
            data = request('meeting/' + str(meeting))
            failed = [j for j in request('jobs') if j['meeting_id'] == meeting and j['status'] == 'failed']
            if failed:
                raise AssertionError('Final job failed: ' + str(failed[-1]['error']))
            state = request('status')
            if state.get('auto_process_error'):
                raise AssertionError(state['auto_process_error'])
            return data.get('transcript')
        final = wait(final_result, 60)
        status = request('status')
        assert status['recording']['active'] is None
        assert not status['live']['running'] and final['status'] == 'final'
        c = sqlite3.connect(db)
        assert c.execute('pragma integrity_check').fetchone()[0] == 'ok'
        assert c.execute("select count(*) from live_chunks where state='running'").fetchone()[0] == 0
        assert c.execute('select count(*) from recordings').fetchone()[0] > 0
        print(json.dumps({'passed': True, 'real_model': args.real_model, 'first_preview_ms': first_preview_ms,
                          'first_chunk_processing_ms': chunks[0]['elapsed_ms'], 'preview_segments': len(chunks[0]['segments']),
                          'final_segments': len(final['segments']), 'integrity': 'ok'}, ensure_ascii=False))
        c.close()
    finally:
        try:
            state = request('status')
            active = state['recording']['active']
            if active:
                request('recording/stop', {'meeting_id': active['meeting_id']})
            wait(lambda: not request('status')['live']['running'], 40)
        except Exception:
            pass
        server.terminate()
        server.wait(timeout=10)
        log.close()
