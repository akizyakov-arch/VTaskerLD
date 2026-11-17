# -*- coding: utf-8 -*-
"""Opt-in synthetic full-meeting test. No microphone and no real meeting data."""
import hashlib,importlib.util,json,os,subprocess,sys,wave
from pathlib import Path
root=Path(__file__).resolve().parents[2]
mode=sys.argv[1];out=Path(sys.argv[2])
if mode=='prepare':
 out.mkdir(parents=True,exist_ok=True)
 subprocess.run(['/usr/bin/say','-v','Milena','-r','140','-f',str(root/'tests/fixtures/full_meeting.txt'),'-o',str(out/'speech.aiff')],check=True,capture_output=True)
 subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(out/'speech.aiff'),'-ac','1','-ar','16000','-c:a','pcm_s16le',str(out/'meeting.wav')],check=True)
 with wave.open(str(out/'meeting.wav'),'rb') as f:frames=f.readframes(f.getnframes())
 with wave.open(str(out/'meeting.wav'),'rb') as f:parameters=f.getparams()
 pieces=out/'pieces';pieces.mkdir()
 for i,start in enumerate(range(0,len(frames),16000*2*5)):
  with wave.open(str(pieces/('%06d.wav'%i)),'wb') as f:f.setparams(parameters);f.writeframes(frames[start:start+16000*2*5])
 (out/'audio_manifest.json').write_text(json.dumps({'seconds':len(frames)/32000,'fragments':len(list(pieces.glob('*.wav'))),'pcm_sha256':hashlib.sha256(frames).hexdigest(),'synthesized':True,'voice':'Milena','speakers':1,'real_microphone':False}),encoding='utf-8')
 print('Synthetic audio prepared',flush=True)
elif mode=='groq':
 if os.environ.get('VTASK_FULL_GROQ')!='1':raise SystemExit('Enable VTASK_FULL_GROQ=1 explicitly')
 spec=importlib.util.spec_from_file_location('groq',root/'scripts/groq-analyze.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
 account=hashlib.sha256(str(Path.home()/'Library/Application Support/VTracker/data.sqlite3').encode()).hexdigest()
 try:
  key=g.keychain({'mode':'load_key','account':account}).get('key')
  if not key:raise SystemExit('No persisted Groq key for the opt-in test')
  snapshot=json.loads((out/'analysis_input.json').read_text())
  result=g.analyze({'input':snapshot,'model':'openai/gpt-oss-120b','key':key})
  (out/'analysis_result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
  print('Synthetic transcript analyzed by Groq',flush=True)
 except g.ProviderError as e:raise SystemExit(str(e))
