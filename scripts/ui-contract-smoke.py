"""Targeted API checks against an explicitly isolated test server."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave
base=os.environ.get('VTASK_TEST_URL','http://127.0.0.1:8765')
http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def api(path,body=None):
    req=urllib.request.Request(base+'/api/'+path,data=None if body is None else json.dumps(body).encode(),headers={'Origin':base,'Content-Type':'application/json'})
    with http.open(req,timeout=10) as response:return json.load(response)
# This script adds a labelled test meeting only; no changes to existing data.
meeting=api('workspace/action',{'op':'save_meeting','data':{'title':'API import test','participants':[]}})['id']
with tempfile.TemporaryDirectory(prefix='vtask-import-') as tmp:
    wav=Path(tmp)/'source.wav';m4a=Path(tmp)/'source.m4a'
    with wave.open(str(wav),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(b'\0\0'*16000)
    subprocess.check_call(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(wav),str(m4a)])
    req=urllib.request.Request(base+f'/api/import?meeting_id={meeting}',data=m4a.read_bytes(),headers={'Origin':base,'Content-Type':'application/octet-stream'})
    with http.open(req,timeout=10) as response:result=json.load(response)
    assert result['frames']>0
    exported=api(f'meeting/{meeting}');recording=exported['recordings'][0]
    assert recording['sample_rate']==16000 and recording['channels']==1
    req=urllib.request.Request(base+f'/api/audio/{recording["id"]}',headers={'Range':'bytes=0-43'})
    with http.open(req) as response:
        assert response.status==206 and len(response.read())==44
    job=api('jobs',{'meeting_id':meeting})['id']
    api('jobs/run',{'meeting_id':meeting})
    for _ in range(100):
        jobs=api('jobs');state=next(j for j in jobs if j['id']==job)
        if state['status']=='completed':break
        if state['status']=='failed':raise AssertionError(state)
        time.sleep(.1)
    else:raise AssertionError('Job did not complete')
    assert api(f'transcript/{meeting}')['segments']
print('API contract passed: M4A import -> PCM WAV -> ranged playback -> selected-meeting job -> transcript')
