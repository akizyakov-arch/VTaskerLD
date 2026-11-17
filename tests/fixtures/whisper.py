#!/usr/bin/env python3
"""Protocol fixture; produces deterministic text, never runs an ML model."""
import json
from pathlib import Path
import sys
import wave

args = sys.argv[1:]
if '--vad' in args:
    assert Path(args[args.index('-vm') + 1]).is_file()
    for flag,expected in [('-vt','0.5'),('-vspd','250'),('-vsd','100'),('-vp','30'),('-vo','0.1')]:
        assert args[args.index(flag)+1] == expected
with wave.open(args[args.index('-f') + 1], 'rb') as wav:
    assert wav.getframerate() == 16000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2
    duration = wav.getnframes() * 1000 // 16000
if Path(args[args.index('-m') + 1]).read_bytes() == b'BAD_JSON':
    duration = -1
Path(args[args.index('-of') + 1] + '.json').write_text(json.dumps({
    'transcription': [{'text': ' Тестовый результат ', 'offsets': {'from': 0, 'to': duration}}]
}), encoding='utf-8')
