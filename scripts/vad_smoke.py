"""Verify real Silero VAD: silence handling and original timestamps after leading silence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('jfk',type=Path)
parser.add_argument('--output',type=Path,required=True)
args = parser.parse_args()
if not os.environ.get('VTRACKER_VAD_MODEL'):
    raise SystemExit('Set VTRACKER_VAD_MODEL to the verified Silero model first')
repo = Path(__file__).resolve().parents[1]
report = {'date':'2026-11-01','platform':'Linux CPU','cases':[]}
with tempfile.TemporaryDirectory(prefix='vtracker-vad-') as tmp:
    root = Path(tmp)
    with wave.open(str(args.jfk),'rb') as wav:
        assert wav.getnchannels()==1 and wav.getsampwidth()==2 and wav.getframerate()==16000
        speech = wav.readframes(wav.getnframes())
    for name,audio in [('padded_speech',b'\x00\x00'*48000+speech+b'\x00\x00'*32000),('silence',b'\x00\x00'*96000)]:
        source = root/f'{name}.wav'
        with wave.open(str(source),'wb') as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(audio)
        cmd=[str(repo/'target/debug/vtracker'),'--db',str(root/f'{name}.sqlite3')]
        env=os.environ.copy();env['VTRACKER_LANGUAGE']='en'
        def cli(*parts):return subprocess.check_output(cmd+list(parts),text=True,env=env)
        meeting=int(cli('meeting','create',name))
        cli('audio','import',str(meeting),str(source),'--root',str(root/'audio'))
        cli('jobs','enqueue',str(meeting));cli('jobs','run')
        transcript=json.loads(cli('meeting','transcript',str(meeting)))
        segments=transcript['segments']
        if name=='silence':assert segments==[], 'VAD generated speech from digital silence'
        else:
            assert 'country' in ' '.join(s['text'] for s in segments).lower()
            assert min(s['start_ms'] for s in segments)>=2500, 'VAD lost the original timeline'
            assert max(s['end_ms'] for s in segments)<=len(audio)//32
            assert all(s['sources'] for s in segments)
        report['cases'].append({'name':name,'passed':True,'segments':segments,'parameters':transcript['parameters']})
        print(f'Real VAD {name}: passed ({len(segments)} segments)',flush=True)
args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
