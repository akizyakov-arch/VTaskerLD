#!/usr/bin/env python3
"""Protocol fixture only; does not run diarization models."""
import json
from pathlib import Path
import sys
import wave
segmentation,embedding,source,output,speakers=sys.argv[1:]
assert Path(segmentation).is_file() and Path(embedding).is_file()
if Path(segmentation).read_bytes()==b'FAIL':sys.exit(1)
with wave.open(source,'rb') as wav:
    assert wav.getnchannels()==1 and wav.getframerate()==16000
    duration=wav.getnframes()*1000//16000
midpoint=duration//2
turns=[
    {'start_ms':0,'end_ms':midpoint,'speaker':0},
    {'start_ms':midpoint,'end_ms':duration,'speaker':1}
]
if speakers=='1':turns=[{'start_ms':0,'end_ms':duration,'speaker':0}]
Path(output).write_text(json.dumps({'turns':turns}))
