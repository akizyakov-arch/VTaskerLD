"""Fetch three distinct FLEURS Russian dev sentences from a checksum-verified archive."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import urllib.request

REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
BASE = f'https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/ru_ru/'
EXPECTED = '4dc533cd0f312f749bd6d0fe968f3183288d938e07ed97dc141d9f10570457f9'

def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()

def main(root):
    root.mkdir(parents=True, exist_ok=True)
    archive = root / 'dev.tar.gz'
    if not archive.exists():
        fd, name = tempfile.mkstemp(dir=root, prefix='.fleurs-')
        staging = Path(name)
        try:
            h = hashlib.sha256()
            size = 0
            with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(BASE+'audio/dev.tar.gz', timeout=60) as response:
                while block := response.read(1024*1024):
                    output.write(block); h.update(block); size += len(block)
                    if size % (32*1024*1024) == 0:
                        print(f'FLEURS archive: {size//(1024*1024)} MiB', flush=True)
                output.flush(); os.fsync(output.fileno())
            if h.hexdigest() != EXPECTED:
                raise RuntimeError('FLEURS archive checksum mismatch')
            os.link(staging, archive)
        finally:
            staging.unlink(missing_ok=True)
    if checksum(archive) != EXPECTED:
        raise RuntimeError('Existing FLEURS archive checksum mismatch; preserved unchanged')
    with urllib.request.urlopen(BASE+'dev.tsv', timeout=30) as response:
        rows = list(csv.reader(io.StringIO(response.read().decode('utf-8')), delimiter='\t'))
    selected = {}
    texts = set()
    for row in rows:
        if row[3] not in texts:
            selected[row[1]] = {'file': row[1], 'reference': row[3]}
            texts.add(row[3])
        if len(selected) == 3: break
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            name = Path(member.name).name
            if name in selected and member.isfile():
                if member.size > 10*1024*1024: raise RuntimeError('Unexpected sample size')
                data = tar.extractfile(member).read()
                destination = root / name
                if destination.exists():
                    if destination.read_bytes() != data: raise RuntimeError('Existing sample differs')
                else:
                    with destination.open('xb') as f: f.write(data)
                selected[name]['sha256'] = hashlib.sha256(data).hexdigest()
    if not all('sha256' in row for row in selected.values()): raise RuntimeError('Sample missing from archive')
    metadata = {'dataset':'Google FLEURS','split':'ru_ru dev','license':'CC-BY-4.0',
                'attribution':'Google FLEURS dataset contributors; https://huggingface.co/datasets/google/fleurs',
                'revision':REVISION,'archive_sha256':EXPECTED,'selection':'first three distinct sentences in dev.tsv',
                'samples':list(selected.values())}
    (root/'samples.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n')
    print(f'Verified {len(selected)} Russian samples: {root}')

if __name__ == '__main__':
    if len(sys.argv)!=2: raise SystemExit('Usage: python3 scripts/fetch-russian-samples.py OUTPUT_DIRECTORY')
    main(Path(sys.argv[1]))
