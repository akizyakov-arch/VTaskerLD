#!/usr/bin/env python3
"""Bounded real-time replay of a public WAV; no microphone access."""
import json
import os
from pathlib import Path
import select
import sys
import time
import wave

device = {'id': 1, 'uid': 'public-replay', 'name': 'Public speech test replay', 'isDefault': True}
if sys.argv[1] == '--devices':
    print(json.dumps([device]), flush=True)
    sys.exit(0)
output, seconds = Path(sys.argv[1]), int(sys.argv[2])
with wave.open(os.environ['VTRACKER_LIVE_SAMPLE'], 'rb') as wav:
    params = wav.getparams()
    data = wav.readframes(wav.getnframes())
frame_size = params.nchannels * params.sampwidth
samples = len(data) // frame_size
sequence = 0
print('DEVICE\t' + json.dumps(device), flush=True)
print('CAPABILITIES\tpause,level', flush=True)
print('READY', flush=True)
began = time.monotonic()
while sequence * 5 * params.framerate < samples:
    ready, _, _ = select.select([sys.stdin], [], [], max(0, began + (sequence + 1) * 5 - time.monotonic()))
    if ready and sys.stdin.readline().strip() in ('stop', ''):
        break
    start = sequence * 5 * params.framerate * frame_size
    end = min(len(data), start + 5 * params.framerate * frame_size)
    partial = output / f'{sequence:06}.partial.wav'
    with wave.open(str(partial), 'wb') as wav:
        wav.setparams(params)
        wav.writeframes(data[start:end])
    with partial.open('rb') as stream:
        os.fsync(stream.fileno())
    partial.rename(output / f'{sequence:06}.wav')
    sequence += 1
    print('LEVEL\t0.1', flush=True)
while time.monotonic() - began < seconds:
    ready, _, _ = select.select([sys.stdin], [], [], 0.1)
    if ready and sys.stdin.readline().strip() in ('stop', ''):
        break
