"""Exercise web worker supervision with real FFmpeg and a fake Whisper protocol peer."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave

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

with tempfile.TemporaryDirectory(prefix='vtracker-speech-') as tmp:
    args = [str(repo / 'target/debug/vtracker'), '--db', str(Path(tmp) / 'data.sqlite3')]
    model = Path(tmp) / 'fake-model'
    model.write_text('NOT AN ML MODEL')
    env = os.environ.copy()
    env['VTRACKER_WHISPER_BIN'] = str(repo / 'tests/fixtures/whisper.py')
    env['VTRACKER_WHISPER_MODEL'] = str(model)
    env['VTRACKER_LANGUAGE'] = 'ru'
    env['VTRACKER_DIARIZATION_BIN'] = str(repo / 'tests/fixtures/diarize.py')
    segmentation = Path(tmp) / 'fixture-segmentation'
    embedding = Path(tmp) / 'fixture-embedding'
    segmentation.write_text('NOT A SEGMENTATION MODEL')
    embedding.write_text('NOT AN EMBEDDING MODEL')
    env['VTRACKER_SEGMENTATION_MODEL'] = str(segmentation)
    env['VTRACKER_EMBEDDING_MODEL'] = str(embedding)
    env['VTRACKER_SPEAKERS'] = '1' 
    env['VTRACKER_CAPTURE_BIN'] = str(repo / 'tests/fixtures/capture.py')
    meeting = int(subprocess.check_output(args + ['meeting', 'create', 'Synthetic speech']))
    source = Path(tmp) / 'input.wav'
    with wave.open(str(source), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b'\x00\x00' * 1600)
    subprocess.check_call(args + ['audio', 'import', str(meeting), str(source), '--root', str(Path(tmp) / 'audio')])
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
        assert api('status')['speech']['configured'] is True
        api('jobs', {'meeting_id': meeting})
        api('jobs/run', {})
        for _ in range(100):
            assert len(api('meetings')) == 1  # HTTP responds while worker runs
            status = api('status')['speech']
            if not status['running']:
                assert status['last']['success'] is True, status
                break
            time.sleep(.1)
        else:
            raise AssertionError('worker did not finish')
        assert api('jobs')[0]['status'] == 'completed'
        transcript = api(f'transcript/{meeting}')
        assert transcript['segments'][0]['text'] == 'Тестовый результат'
        assert transcript['segments'][0]['end_ms'] == 100
        assert 'Тестовый результат' in subprocess.check_output(args + ['export', str(meeting), '--format', 'txt'], text=True)
        person = api('people', {'name': 'Антон'})['id']
        assignment = {'model_run_id': transcript['model_run_id'], 'speaker_id': 'speaker_0', 'person_id': person}
        api('speaker/assign', assignment)
        assert api(f'transcript/{meeting}')['segments'][0]['person_name'] == 'Антон'
        assert '[Антон]' in subprocess.check_output(args + ['export', str(meeting), '--format', 'txt'], text=True)
        assignment['person_id'] = 999
        try:
            api('speaker/assign', assignment)
            raise AssertionError('Nonexistent person accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 400
        assignment['person_id'] = None
        api('speaker/assign', assignment)
        assert api(f'transcript/{meeting}')['segments'][0]['person_name'] is None
        history = json.loads(subprocess.check_output(args + ['speaker', 'history', str(transcript['model_run_id'])]))
        assert len(history) == 2

    finally:
        server.terminate()
        server.wait(timeout=5)
print('Speech integration passed using real FFmpeg + fake Whisper: background job, HTTP, timestamped transcript, manual names, clearing/history and TXT export')
