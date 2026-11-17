"""Evaluate local Whisper on the three fetched FLEURS samples; not an acceptance benchmark."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def words(text):
    return re.findall(r'[а-яa-z0-9]+', text.lower().replace('ё', 'е'))

def distance(reference, hypothesis):
    row = list(range(len(hypothesis)+1))
    for i, ref in enumerate(reference,1):
        current = [i]
        for j, hyp in enumerate(hypothesis,1):
            current.append(min(current[-1]+1,row[j]+1,row[j-1]+(ref!=hyp)))
        row = current
    return row[-1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path)
    parser.add_argument('--vad-model', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    metadata = json.loads((args.corpus/'samples.json').read_text())
    variants = [('without_vad',None)]
    if args.vad_model: variants.append(('with_vad',args.vad_model.resolve()))
    results = []
    for variant,vad in variants:
        for sample in metadata['samples']:
            source = (args.corpus/sample['file']).resolve()
            if hashlib.sha256(source.read_bytes()).hexdigest() != sample['sha256']:
                raise RuntimeError('Sample checksum mismatch')
            with tempfile.TemporaryDirectory(prefix='vtracker-russian-') as tmp:
                cmd = [str(repo/'target/debug/vtracker'),'--db',str(Path(tmp)/'data.sqlite3')]
                env = os.environ.copy()
                env['VTRACKER_LANGUAGE'] = 'ru'
                env.pop('VTRACKER_VAD_MODEL',None)
                if vad: env['VTRACKER_VAD_MODEL'] = str(vad)
                def cli(*parts): return subprocess.check_output(cmd+list(parts),env=env,text=True)
                meeting = int(cli('meeting','create','Public FLEURS Russian evaluation'))
                cli('audio','import',str(meeting),str(source),'--root',str(Path(tmp)/'audio'))
                cli('jobs','enqueue',str(meeting))
                start = time.monotonic()
                cli('jobs','run')
                elapsed = time.monotonic()-start
                transcript = json.loads(cli('meeting','transcript',str(meeting)))
                text = ' '.join(s['text'] for s in transcript['segments'])
                if not re.search('[а-яА-Я]',text): raise RuntimeError('No Cyrillic speech recognized')
                assert all(s['sources'] for s in transcript['segments'])
                assert bool(transcript['parameters']['vad']) == bool(vad)
                ref,hyp = words(sample['reference']),words(text)
                errors = distance(ref,hyp)
                results.append({'variant':variant,'sample':sample['file'],'reference':sample['reference'],
                    'recognized':text,'reference_words':len(ref),'word_errors':errors,'wer':errors/len(ref),
                    'end_to_end_seconds':round(elapsed,3),'model_sha256':transcript['model_sha256'],
                    'parameters':transcript['parameters'],'segments':transcript['segments']})
                print(f'{variant} {sample["file"]}: WER={errors/len(ref):.1%}, {elapsed:.2f}s',flush=True)
    aggregate = {}
    for variant,_ in variants:
        rows = [r for r in results if r['variant']==variant]
        aggregate[variant] = {'samples':len(rows),'reference_words':sum(r['reference_words'] for r in rows),
            'word_errors':sum(r['word_errors'] for r in rows),
            'wer':sum(r['word_errors'] for r in rows)/sum(r['reference_words'] for r in rows)}
    report = {'date':'2026-11-01','platform':'Linux x86_64 CPU','dataset':metadata,'normalization':'lowercase; ё→е; punctuation removed; digits kept',
        'scope':'Three deterministic public samples; no meeting, microphone, DER or Mac performance validation',
        'aggregate':aggregate,'results':results}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(aggregate,ensure_ascii=False))
if __name__ == '__main__': main()
