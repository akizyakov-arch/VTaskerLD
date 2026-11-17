"""Real Whisper + sherpa-onnx on the upstream two-speaker sample; does not measure DER."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('sample',type=Path)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
sample=args.sample.resolve()
repo=Path(__file__).resolve().parents[1]
env=os.environ.copy()
env['VTRACKER_LANGUAGE']='en'
env['VTRACKER_SPEAKERS']='0'
env.pop('VTRACKER_VAD_MODEL',None)
with tempfile.TemporaryDirectory(prefix='vtracker-diarization-') as tmp:
    cmd=[str(repo/'target/debug/vtracker'),'--db',str(Path(tmp)/'data.sqlite3')]
    def cli(*parts):return subprocess.check_output(cmd+list(parts),env=env,text=True)
    meeting=int(cli('meeting','create','Public upstream two-speaker example'))
    cli('audio','import',str(meeting),str(sample),'--root',str(Path(tmp)/'audio'))
    cli('jobs','enqueue',str(meeting))
    start=time.monotonic();cli('jobs','run');elapsed=time.monotonic()-start
    transcript=json.loads(cli('meeting','transcript',str(meeting)))
    turns=transcript['speaker_turns']
    clusters={turn['speaker_id'] for turn in turns}
    assert len(clusters)==2, f'Expected two automatic clusters, got {clusters}'
    assert transcript['parameters']['diarization']['num_speakers']==0
    assert transcript['segments'], 'No speech recognized'
    assert all(0<=turn['start_ms']<turn['end_ms'] for turn in turns)
    assert all(segment['sources'] for segment in transcript['segments'])
    assert all(candidate['speaker_id'] in clusters for segment in transcript['segments'] for candidate in segment['speaker_candidates'])
    report={'date':'2026-11-01','platform':'Linux CPU','sherpa_onnx':'v2.0.1','clustering':'automatic (no known speaker count supplied)',
        'sample_source':'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/1-two-speakers-en.wav',
        'sample_sha256':hashlib.sha256(sample.read_bytes()).hexdigest(),
        'expected_speakers':2,'detected_speakers':len(clusters),'end_to_end_seconds':round(elapsed,3),'passed':True,
        'limits':'One English upstream example. No reference intervals, DER measurement, Russian multi-speaker test or macOS validation.',
        'transcript':transcript}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(f'Real diarization passed: {len(clusters)} automatic clusters, {len(turns)} turns, {len(transcript["segments"])} text segments, {elapsed:.2f}s')
