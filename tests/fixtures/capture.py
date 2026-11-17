#!/usr/bin/env python3
"""Synthetic fragmented capture protocol peer; never accesses an audio device."""
from pathlib import Path
import os
import json
import select
import sys
import time
import wave

device = {'uid': 'test-mic', 'name': 'Synthetic microphone', 'isDefault': True, 'id': 42}
if sys.argv[1] == '--devices':
    print(json.dumps([device]), flush=True)
    sys.exit(0)
if sys.argv[1] == '--test':
    print('DEVICE\t' + json.dumps(device), flush=True)
    print('READY', flush=True)
    print('LEVEL\t0.25', flush=True)
    time.sleep(0.15)
    sys.exit(0)
output, seconds = Path(sys.argv[1]), int(sys.argv[2])
if len(sys.argv) > 3:
    if sys.argv[3] != device['uid']:
        print('ERROR\tSelected microphone is unavailable', flush=True)
        sys.exit(1)
(output / 'source.json').write_text(json.dumps(device))
print('DEVICE\t' + json.dumps(device), flush=True)

def publish(sequence):
    partial = output / f'{sequence:06}.partial.wav'
    with wave.open(str(partial), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        # Identical silence intentionally tests occurrence preservation.
        wav.writeframes(b'\x00\x00' * 1600)
    with partial.open('rb') as file:
        os.fsync(file.fileno())
    partial.rename(output / f'{sequence:06}.wav')

print('CAPABILITIES\tpause,level', flush=True)
print('READY', flush=True)
publish(0)
deadline = time.monotonic() + seconds
print('LEVEL\t0.25', flush=True)
while time.monotonic() < deadline:
    ready, _, _ = select.select([sys.stdin], [], [], max(0,deadline-time.monotonic()))
    if not ready: break
    command = sys.stdin.readline().strip()
    if command in ('stop',''): break
publish(1)
