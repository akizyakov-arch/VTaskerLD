"""Verify append/resume API on an isolated DB with synthetic capture and STT fixtures."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vtask-continue-smoke-') as tmp:
    tmp=Path(tmp);model=tmp/'model';model.write_bytes(b'fixture')
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    base=f'http://127.0.0.1:{port}'
    env={k:v for k,v in os.environ.items() if not k.startswith('VTRACKER_')}
    env.update(VTRACKER_PORT=str(port),VTRACKER_WHISPER_BIN=str(root/'tests/fixtures/whisper.py'),VTRACKER_WHISPER_MODEL=str(model),VTRACKER_CAPTURE_BIN=str(root/'tests/fixtures/capture.py'),VTRACKER_FFMPEG_BIN=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg')
    with (tmp/'log').open('w+') as log:
        process=subprocess.Popen([str(root/'target/debug/vtracker'),'--db',str(tmp/'db'),'serve'],env=env,stdout=log,stderr=log)
        def api(path,body=None):
            data=None if body is None else json.dumps(body).encode()
            with urllib.request.urlopen(urllib.request.Request(base+'/api/'+path,data=data,headers={'Origin':base,'Content-Type':'application/json'}),timeout=5) as response:return json.load(response)
        def wait(fn):
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                try:
                    result=fn()
                    if result:return result
                except urllib.error.URLError:pass
                time.sleep(0.05)
            raise AssertionError('Timed out')
        try:
            wait(lambda:api('status'))
            meeting=api('meetings',{'title':'Synthetic continued meeting'})['id']
            def capture(action):
                api('recording/'+action,{'meeting_id':meeting,'seconds':30,'processing_mode':'post'})
                wait(lambda:(api('status')['recording']['active'] or {}).get('fragments',0)>0)
                api('recording/stop',{'meeting_id':meeting})
                wait(lambda:api('meeting/'+str(meeting)).get('transcript') if not api('status')['speech']['running'] and not api('status')['recording']['active'] else None)
            capture('start');before=api('meeting/'+str(meeting));old_run=before['transcript']['model_run_id'];old_audio={r['path']:Path(r['path']).read_bytes() for r in before['recordings']}
            api('workspace/action',{'op':'settings','data':{'auto_process':False}})
            api('recording/continue',{'meeting_id':meeting,'seconds':30,'processing_mode':'post'})
            wait(lambda:(api('status')['recording']['active'] or {}).get('fragments',0)>0)
            current=api('meeting/'+str(meeting));assert current['transcript']['model_run_id']==old_run and current['transcript']['needs_update']
            api('recording/stop',{'meeting_id':meeting});wait(lambda:api('status')['recording']['active'] is None)
            data=api('meeting/'+str(meeting));assert len(data['audio_timeline'])==4 and data['audio_timeline'][-1]['end_ms']==400
            for path,content in old_audio.items():assert Path(path).read_bytes()==content
            api('jobs',{'meeting_id':meeting});api('jobs/run',{'meeting_id':meeting})
            final=wait(lambda:(d if d['transcript']['model_run_id']!=old_run else None) if (d:=api('meeting/'+str(meeting))) else None)
            assert not final['transcript']['needs_update'];assert final['transcript']['segments'][0]['end_ms']==400
            print(json.dumps({'passed':True,'same_meeting':meeting,'parts':2,'audio_occurrences':4,'duration_ms':400,'old_audio_unchanged':True,'new_transcript_version':True}))
        finally:
            process.terminate();process.wait(timeout=10)
