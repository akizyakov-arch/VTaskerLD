#!/usr/bin/env python3
"""Simulated disconnected microphone with one completed recoverable fragment."""
from pathlib import Path
import sys
import wave
output=Path(sys.argv[1]);output.mkdir(exist_ok=True)
with wave.open(str(output/'000000.wav'),'wb') as wav:
    wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b'\0\0'*1600)
print('READY',flush=True)
print('ERROR\tMicrophone disconnected: default input',flush=True)
sys.exit(1)
