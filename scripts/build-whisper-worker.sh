#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tools_dir="${VTRACKER_TOOLS_DIR:-$HOME/.local/share/vtracker}"
whisper="$tools_dir/whisper.cpp"
mkdir -p "$repo_dir/native/inference/.build"
c++ -std=c++17 -O2 "$repo_dir/native/inference/main.cpp" \
  -I"$whisper/include" -I"$whisper/ggml/include" -isystem "$whisper/examples" \
  -L"$whisper/build/src" -Wl,-rpath,"$whisper/build/src" -lwhisper \
  -o "$repo_dir/native/inference/.build/vtracker-whisper-worker"
sherpa="$tools_dir/diarization/sherpa-onnx-v2.0.1-osx-$(uname -m)-shared-no-tts"
if [[ -f "$sherpa/include/sherpa-onnx/c-api/c-api.h" ]]; then
  c++ -std=c++17 -O2 "$repo_dir/native/diarization/block_worker.cpp" \
    -isystem "$whisper/examples" -I"$sherpa/include" \
    -L"$sherpa/lib" -Wl,-rpath,"$sherpa/lib" -lsherpa-onnx-c-api -lonnxruntime \
    -o "$repo_dir/native/inference/.build/vtracker-speaker-worker"
fi
