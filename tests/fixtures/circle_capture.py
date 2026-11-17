#!/usr/bin/env python3
"""Artificial five-second audio source for circle control tests. No microphone access."""
import json,os,select,sys,time,wave,struct
from pathlib import Path
device={'uid':'circle-test','id':1,'name':'Synthetic circle test','isDefault':True}
if sys.argv[1]=='--devices':print(json.dumps([device]));raise SystemExit()
out=Path(sys.argv[1]);limit=int(sys.argv[2]);print('DEVICE\t'+json.dumps(device),flush=True);print('CAPABILITIES\tpause,level',flush=True);print('READY',flush=True);print('LEVEL\t0.2',flush=True)
began=time.monotonic();next_at=began+5;seq=0;paused=False
while time.monotonic()-began<limit:
 ready,_,_=select.select([sys.stdin],[],[],max(0,min(.2,next_at-time.monotonic())) if not paused else .2)
 if ready:
  cmd=sys.stdin.readline().strip()
  if cmd in ('stop',''):break
  if cmd=='pause':paused=True;print('LEVEL\t0',flush=True)
  if cmd=='resume':paused=False;next_at=time.monotonic()+5;print('LEVEL\t0.2',flush=True)
 if not paused and time.monotonic()>=next_at:
  path=out/('%06d.partial.wav'%seq)
  with wave.open(str(path),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b''.join(struct.pack('<h',((i%100)-50)*200) for i in range(80000)))
  with path.open('rb') as f:os.fsync(f.fileno())
  path.rename(out/('%06d.wav'%seq));seq+=1;next_at=time.monotonic()+5
