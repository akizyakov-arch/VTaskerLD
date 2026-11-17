"""Local functional speaker matching check: public WAV, real embeddings, stub STT/diarization."""
import argparse
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
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ui-seconds',type=int,default=0,choices=range(0,61))
args=parser.parse_args()
tools=Path.home()/'.local/share/vtracker';sample=tools/'whisper.cpp/samples/jfk.wav'
with tempfile.TemporaryDirectory(prefix='vtask-voice-matching-') as tmp:
    tmp=Path(tmp);db=tmp/'db.sqlite3';model=tmp/'stt-model';model.write_bytes(b'fixture');seg=tmp/'segmentation';seg.write_bytes(b'fixture')
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    base=f'http://127.0.0.1:{port}'
    env={k:v for k,v in os.environ.items() if not k.startswith('VTRACKER_')}
    fixture=root/'tests/fixtures'
    env.update(VTRACKER_PORT=str(port),VTRACKER_WHISPER_BIN=str(fixture/'whisper.py'),VTRACKER_WHISPER_MODEL=str(model),
               VTRACKER_DIARIZATION_BIN=str(fixture/'diarize.py'),VTRACKER_SEGMENTATION_MODEL=str(seg),VTRACKER_SPEAKERS='1',
               VTRACKER_EMBEDDING_MODEL=str(tools/'diarization/embedding.onnx'),VTRACKER_EMBED_BIN=str(root/'native/diarization/.build/vtracker-embed'),
               VTRACKER_FFMPEG_BIN=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg',VTRACKER_CAPTURE_BIN=str(fixture/'capture.py'))
    log=(tmp/'server.log').open('w+')
    server=subprocess.Popen([str(root/'target/debug/vtracker'),'--db',str(db),'serve'],env=env,stdout=log,stderr=log)
    def request(path,body=None,raw=None):
        data=raw if raw is not None else None if body is None else json.dumps(body).encode()
        with urllib.request.urlopen(urllib.request.Request(base+'/api/'+path,data=data,headers={'Origin':base,'Content-Type':'application/json'}),timeout=10) as response:return json.load(response)
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
    def voice_done():
        data=request('status')['voice_data']
        failed=[j for j in data['jobs'] if j['state']=='failed']
        if failed:raise AssertionError(failed[0]['error'])
        return data['profiles'] if data['jobs'] and data['jobs'][0]['state']=='completed' else None
    def match_done(run):
        data=request('status')['voice_data'];jobs=[j for j in data['match_jobs'] if j['model_run_id']==run]
        if not jobs:return None
        if jobs[0]['state']=='failed':raise AssertionError(jobs[0]['error'])
        return request('meeting/1')['transcript'] if jobs[0]['state']=='completed' else None
    try:
        wait(lambda:request('status'))
        person=request('people',{'name':'Public test speaker'})['id'];meeting=request('meetings',{'title':'Isolated speaker matching check'})['id'];assert meeting==1
        request('import?meeting_id=1',raw=sample.read_bytes());request('jobs',{'meeting_id':1});request('jobs/run',{'meeting_id':1})
        t=wait(lambda:request('meeting/1').get('transcript'));run=t['model_run_id'];speaker=t['speaker_turns'][0]['speaker_id']
        plan=request('voice/source',{'model_run_id':run,'speaker_id':speaker});assert plan['duration_ms']>=6000
        try:request('voice/from-meeting',{'person_id':person,'model_run_id':run,'speaker_id':speaker,'single_speaker':True})
        except urllib.error.HTTPError as e:assert e.code==400
        else:raise AssertionError('Consent is required')
        began=time.monotonic();request('voice/from-meeting',{'person_id':person,'model_run_id':run,'speaker_id':speaker,'consent':True,'single_speaker':True});wait(voice_done)
        enroll_ms=round((time.monotonic()-began)*1000)
        began=time.monotonic();request('voice/match',{'model_run_id':run});t=wait(lambda:match_done(run));matching_ms=round((time.monotonic()-began)*1000)
        candidate=t['voice_matches'][0];assert candidate['status']=='candidate' and candidate['person_id']==person
        similarity=candidate['similarity'];assert similarity>0.99
        assert t['segments'][0]['person_id'] is None and t['segments'][0]['voice_suggestion']['status']=='candidate'
        if args.ui_seconds:
            print(json.dumps({'ui_url':base,'meeting_id':1,'hold_seconds':args.ui_seconds}),flush=True)
            time.sleep(args.ui_seconds)
        request('speaker/assign',{'model_run_id':run,'speaker_id':speaker,'person_id':person})
        t=request('meeting/1')['transcript'];assert t['segments'][0]['person_id']==person and 'voice_suggestion' not in t['segments'][0]
        request('voice/matching/settings',{'enabled':True,'threshold':0.75,'margin':0.1})
        request('jobs',{'meeting_id':1});request('jobs/run',{'meeting_id':1})
        t=wait(lambda:match_done(request('meeting/1')['transcript']['model_run_id']) if request('meeting/1')['transcript']['model_run_id']!=run else None)
        new_run=t['model_run_id'];assert new_run!=run and t['segments'][0]['person_id'] is None
        second=request('people',{'name':'Ambiguous same sample'})['id']
        request('voice/from-meeting',{'person_id':second,'model_run_id':new_run,'speaker_id':speaker,'consent':True,'single_speaker':True});wait(voice_done)
        request('voice/match',{'model_run_id':new_run});t=wait(lambda:match_done(new_run));assert t['voice_matches'][0]['status']=='unknown'
        request('voice/delete',{'person_id':person,'confirmed':True})
        c=sqlite3.connect(db)
        assert c.execute('SELECT person_id FROM speaker_assignments WHERE model_run_id=? ORDER BY id DESC LIMIT 1',(run,)).fetchone()[0]==person
        assert c.execute('pragma integrity_check').fetchone()[0]=='ok';assert c.execute('pragma foreign_key_check').fetchall()==[]
        print(json.dumps({'passed':True,'real_embeddings':True,'stt_and_diarization':'protocol fixtures','source_duration_ms':plan['duration_ms'],
                          'enrollment_ms':enroll_ms,'matching_ms':matching_ms,'same_sample_similarity':similarity,'ambiguous_voice':'unknown',
                          'manual_assignment_preserved':True,'automatic_matching_opt_in':True,'integrity':'ok'}),flush=True)
        c.close()
    finally:
        try:wait(lambda:not request('status')['voice']['running'],70)
        except Exception:pass
        server.terminate();server.wait(timeout=10);log.close()
