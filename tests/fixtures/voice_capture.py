#!/usr/bin/env python3
"""Synthetic voice-enrollment microphone. Never opens a real audio device."""
import json,os,sys,wave
from pathlib import Path
if sys.argv[1]=='--devices':
 print(json.dumps([{'uid':'test-voice','name':'Synthetic voice microphone','isDefault':True,'id':42}]),flush=True);sys.exit()
output=Path(sys.argv[1]);device=sys.argv[3] if len(sys.argv)>3 else 'test-voice'
if device=='missing':
 print('ERROR\tSelected microphone is unavailable',flush=True);sys.exit(1)
print('DEVICE\t'+json.dumps({'uid':device,'name':'Synthetic voice microphone','isDefault':True,'id':42}),flush=True)
partial=output/'000000.partial.wav'
with wave.open(str(partial),'wb') as w:
 w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000)
 import struct
 w.writeframes(b''.join(struct.pack('<h',0 if device=='quiet' else ((i%100)-50)*200) for i in range(8*16000)))
with partial.open('rb') as f:os.fsync(f.fileno())
partial.rename(output/'000000.wav')
print('READY',flush=True);print('LEVEL\t0.2',flush=True)
for command in sys.stdin:
 if command.strip()=='stop':break
