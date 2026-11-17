"""Real local speaker embedding check using a public WAV and an isolated HTTP server/DB."""
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root=Path(__file__).resolve().parents[1]
tools=Path.home()/'.local/share/vtracker'
sample=tools/'whisper.cpp/samples/jfk.wav'
with tempfile.TemporaryDirectory(prefix='vtask-voice-smoke-') as tmp:
    tmp=Path(tmp);db=tmp/'db.sqlite3'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    base=f'http://127.0.0.1:{port}'
    env={k:v for k,v in os.environ.items() if not k.startswith('VTRACKER_')}
    env.update(VTRACKER_PORT=str(port),VTRACKER_EMBED_BIN=str(root/'native/diarization/.build/vtracker-embed'),
               VTRACKER_EMBEDDING_MODEL=str(tools/'diarization/embedding.onnx'),VTRACKER_FFMPEG_BIN=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg',
               VTRACKER_CAPTURE_BIN=str(root/'tests/fixtures/capture.py'))
    log=(tmp/'log').open('w+')
    server=subprocess.Popen([str(root/'target/debug/vtracker'),'--db',str(db),'serve'],env=env,stdout=log,stderr=log)
    def request(path,body=None,raw=None,consent=False):
        headers={'Origin':base,'Content-Type':'application/json'}
        if consent:headers.update({'X-Voice-Consent':'confirmed','X-Voice-Single-Speaker':'confirmed'})
        data=raw if raw is not None else None if body is None else json.dumps(body).encode()
        with urllib.request.urlopen(urllib.request.Request(base+'/api/'+path,data=data,headers=headers),timeout=10) as response:return json.load(response)
    def wait(fn,seconds=60):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if server.poll() is not None:
                log.seek(0);raise AssertionError(log.read())
            try:
                value=fn()
                if value:return value
            except urllib.error.URLError:pass
            time.sleep(0.1)
        raise AssertionError('Timed out')
    try:
        wait(lambda:request('status'))
        person=request('people',{'name':'Public WAV enrollment test'})['id']
        meeting=request('meetings',{'title':'History must remain'})['id']
        try:request('voice/enroll?person_id='+str(person),raw=sample.read_bytes())
        except urllib.error.HTTPError as error:assert error.code==400
        else:raise AssertionError('Consent must be required')
        began=time.monotonic();request('voice/enroll?person_id='+str(person),raw=sample.read_bytes(),consent=True)
        def completed():
            state=request('status')['voice_data']
            if state['jobs'] and state['jobs'][0]['state']=='failed':raise AssertionError(state['jobs'][0]['error'])
            return state['profiles'] or None
        profiles=wait(completed)
        elapsed=round((time.monotonic()-began)*1000)
        assert profiles[0]['sample_count']==1 and profiles[0]['revision']==1
        assert 'embedding_json' not in json.dumps(request('status')['voice_data'])
        c=sqlite3.connect(db);vector=json.loads(c.execute('select embedding_json from voice_profiles').fetchone()[0]);assert len(vector)==256
        assert abs(sum(v*v for v in vector)-1)<1e-6
        request('voice/delete',{'person_id':person,'confirmed':True})
        assert not request('status')['voice_data']['profiles']
        assert request('people')[0]['id']==person
        assert request('meeting/'+str(meeting))['meeting']['title']=='History must remain'
        assert not list((tmp/'voice').glob('sample-*'))
        assert c.execute('pragma integrity_check').fetchone()[0]=='ok'
        assert c.execute('select count(*) from voice_consents where revoked_at is not null').fetchone()[0]==1
        print(json.dumps({'passed':True,'embedding_dimensions':len(vector),'enrollment_ms':elapsed,'consent_required':True,'delete_keeps_history':True,'integrity':'ok'}))
        c.close()
    finally:
        try:wait(lambda:not request('status')['voice']['running'],70)
        except Exception:pass
        server.terminate();server.wait(timeout=10);log.close()
