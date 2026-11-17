"""Fetch checksum-pinned sherpa-onnx assets and build the local C++ diarization adapter."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request

ASSETS = {
    ('Linux','x86_64'): ('sherpa-onnx-v2.0.1-linux-x64-shared-no-tts.tar.bz2','b3b095f619059d54914027ff38f8a0a132ea3bbc5df32a212a9743a8bd1467b2'),
    ('Darwin','arm64'): ('sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts.tar.bz2','4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79'),
    ('Darwin','x86_64'): ('sherpa-onnx-v2.0.1-osx-x64-shared-no-tts.tar.bz2','029b5ea0a4bd2f0c034a337c0043019323fd06491728d7fc712592e3b558be52'),
}

def checksum(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def fetch(url,path,expected):
    if path.exists():
        if checksum(path)!=expected:raise RuntimeError(f'Existing artifact checksum mismatch: {path}')
        return
    fd,name=tempfile.mkstemp(dir=path.parent,prefix='.download-')
    staging=Path(name)
    try:
        with os.fdopen(fd,'wb') as output,urllib.request.urlopen(url,timeout=60) as response:
            while block:=response.read(1024*1024):output.write(block)
            output.flush();os.fsync(output.fileno())
        if checksum(staging)!=expected:raise RuntimeError('Artifact checksum mismatch')
        os.link(staging,path)
    finally:staging.unlink(missing_ok=True)

def main(root):
    root.mkdir(parents=True,exist_ok=True)
    root=root.resolve()
    try:name,sha=ASSETS[(platform.system(),platform.machine())]
    except KeyError:raise RuntimeError('Supported platforms: Linux x86_64, macOS arm64/x86_64')
    archive=root/name
    fetch('https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/'+name,archive,sha)
    bundle=root/name.removesuffix('.tar.bz2')
    if not bundle.exists():
        with tarfile.open(archive,'r:bz2') as tar:
            if {Path(m.name).parts[0] for m in tar.getmembers()}!={bundle.name}:raise RuntimeError('Unexpected archive root')
            tar.extractall(root,filter='data')
    # Verify reused headers/libraries against the checked archive; do not overwrite local edits.
    with tarfile.open(archive,'r:bz2') as tar:
        for member in tar.getmembers():
            target=root/member.name
            if member.isdir():
                if not target.is_dir():raise RuntimeError('Incomplete sherpa bundle cache')
            elif member.issym():
                if not target.is_symlink() or os.readlink(target)!=member.linkname:
                    raise RuntimeError('Cached sherpa symlink differs from release')
            elif member.isfile() or member.islnk():
                if target.is_symlink() or not target.is_file():raise RuntimeError('Cached sherpa file missing')
                h=hashlib.sha256()
                with tar.extractfile(member) as stream:
                    for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
                if checksum(target)!=h.hexdigest():raise RuntimeError('Cached sherpa file differs from release; preserved unchanged')
    fetch('https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx',
          root/'segmentation.onnx','220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079')
    fetch('https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/0743f301363dec56491a490f6d6cbc9d67f9a3bf/wespeaker_en_voxceleb_resnet34.onnx',
          root/'embedding.onnx','5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94')
    source=Path(__file__).resolve().parents[1]/'native/diarization/main.cpp'
    subprocess.check_call([os.environ.get('CXX','c++'),'-std=c++17','-O2',str(source),'-I'+str(bundle/'include'),
        '-L'+str(bundle/'lib'),'-Wl,-rpath,'+str(bundle/'lib'),'-lsherpa-onnx-c-api','-lonnxruntime','-o',str(root/'vtracker-diarize')])
    print(f'Diarization helper: {root/"vtracker-diarize"}',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    main(parser.parse_args().root)
