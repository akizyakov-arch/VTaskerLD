"""Run real Whisper on its upstream JFK sample; requires a verified model installed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 4:
    raise SystemExit('Usage: python3 scripts/real_speech_smoke.py WHISPER_BIN MODEL JFK_WAV')
repo = Path(__file__).resolve().parents[1]
engine, model, sample = (str(Path(v).resolve()) for v in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='vtracker-real-speech-') as tmp:
    args = [str(repo / 'target/debug/vtracker'), '--db', str(Path(tmp) / 'data.sqlite3')]
    meeting = int(subprocess.check_output(args + ['meeting', 'create', 'Official English smoke sample']))
    subprocess.check_call(args + ['audio', 'import', str(meeting), sample, '--root', str(Path(tmp) / 'audio')])
    subprocess.check_call(args + ['jobs', 'enqueue', str(meeting)])
    env = os.environ.copy()
    env.update(VTRACKER_WHISPER_BIN=engine, VTRACKER_WHISPER_MODEL=model, VTRACKER_LANGUAGE='en')
    subprocess.check_call(args + ['jobs', 'run'], env=env)
    transcript = json.loads(subprocess.check_output(args + ['meeting', 'transcript', str(meeting)]))
    segments = transcript['segments']
    text = ' '.join(s['text'] for s in segments).lower()
    assert 'country' in text and 'ask' in text, 'Expected words absent from recognized sample'
    assert all(0 <= s['start_ms'] <= s['end_ms'] for s in segments)
    assert all(s['sources'] for s in segments)
    print(f'Real Whisper smoke passed: {len(segments)} segments; English sample only, Russian quality not measured')
