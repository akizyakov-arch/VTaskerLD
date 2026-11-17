"""Download pinned public Whisper/VAD models; verify checksums before publication."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.request

MODELS = {
    'tiny': {
        # ggml-org/whisper.cpp v1.7.6 models/README.md.
        'algorithm': 'sha1', 'checksum': 'bd577a113a864445d4c299885e0cb97d4ba92b5f',
        'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
    },
    'large-v3-turbo-q5_0': {
        'algorithm': 'sha1', 'checksum': 'e050f7970618a659205450ad97eb95a18d69c9ee',
        'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
    },
    'vad': {
        # Official ggml-org/whisper-vad Git LFS object at the pinned revision.
        'algorithm': 'sha256', 'checksum': '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf',
        'url': 'https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin',
    },
}
def digest(path, algorithm):
    h = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def download(destination, spec):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(destination, spec['algorithm']) != spec['checksum']:
            raise RuntimeError('Existing model does not match upstream checksum; preserved unchanged')
        return
    fd, name = tempfile.mkstemp(prefix='.whisper-', dir=destination.parent)
    staging = Path(name)
    try:
        with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(spec['url'], timeout=60) as response:
            while block := response.read(1024 * 1024):
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if digest(staging, spec['algorithm']) != spec['checksum']:
            raise RuntimeError('Model checksum mismatch; refusing publication')
        os.link(staging, destination)
    finally:
        staging.unlink(missing_ok=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--vad', action='store_true', help='Download Silero v5.1.2 instead of Whisper tiny')
    parser.add_argument('--model', choices=['tiny', 'large-v3-turbo-q5_0'], default='tiny')
    args = parser.parse_args()
    try:
        download(args.destination, MODELS['vad' if args.vad else args.model])
        print(f'Verified model: {args.destination}')
    except (OSError, RuntimeError, urllib.error.URLError) as error:
        raise SystemExit(f'Model download failed: {error}')
