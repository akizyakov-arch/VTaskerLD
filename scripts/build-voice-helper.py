"""Build the speaker embedding adapter against the already installed sherpa-onnx SDK."""
import os
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
tools=Path(os.environ.get('VTRACKER_TOOLS_DIR',Path.home()/'.local/share/vtracker'))/'diarization'
bundles=[p for p in tools.glob('sherpa-onnx-*-shared-no-tts') if (p/'include/sherpa-onnx/c-api/c-api.h').is_file()]
if len(bundles)!=1:
    raise SystemExit('Install the pinned diarization SDK first (scripts/setup-diarization.py).')
bundle=bundles[0]
out=root/'native/diarization/.build/vtracker-embed';out.parent.mkdir(parents=True,exist_ok=True)
subprocess.check_call([os.environ.get('CXX','c++'),'-std=c++17','-O2',str(root/'native/diarization/embedding.cpp'),'-I'+str(bundle/'include'),'-L'+str(bundle/'lib'),'-Wl,-rpath,'+str(bundle/'lib'),'-lsherpa-onnx-c-api','-lonnxruntime','-o',str(out)])
print('Built embedding adapter:',out)
