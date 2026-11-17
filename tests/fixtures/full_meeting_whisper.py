#!/usr/bin/env python3
"""Audit the real inference input, then delegate once to the real local engine."""
import hashlib,json,os,subprocess,sys,wave
from pathlib import Path
out=Path(os.environ['VTASK_FULL_MEETING_DIR']);args=sys.argv[1:]
with wave.open(args[args.index('-f')+1],'rb') as f:
 frames=f.readframes(f.getnframes());duration=len(frames)/f.getsampwidth()/f.getnchannels()/f.getframerate()
manifest=json.loads((out/'audio_manifest.json').read_text())
assert hashlib.sha256(frames).hexdigest()==manifest['pcm_sha256'],'Merged PCM differs from full original'
audit=out/'engine_calls.jsonl'
with audit.open('a') as f:f.write(json.dumps({'duration_seconds':duration,'pcm_equal':True})+'\n')
raise SystemExit(subprocess.run([os.environ['VTASK_REAL_WHISPER_BIN'],*args]).returncode)
