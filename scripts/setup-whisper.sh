#!/usr/bin/env bash
set -euo pipefail
# Reuse an existing, verified external checkout; never modify application sources.
if [[ -n "${VTRACKER_TOOLS_DIR:-}" ]]; then
  tools_dir="$VTRACKER_TOOLS_DIR"
elif [[ "$(uname -s)" == Darwin ]]; then
  tools_dir="$HOME/.local/share/vtracker"
else
  tools_dir=/workspace/toolchains
fi
cmake_bin="${VTRACKER_CMAKE_BIN:-cmake}"
source_dir="$tools_dir/whisper.cpp"
expected=a8d002cfd879315632a579e73f0148d06959de36
mkdir -p "$tools_dir"
if [[ ! -e "$source_dir" ]]; then
  git clone --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected" ]] || { echo 'Unexpected Whisper source revision' >&2; exit 1; }
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]] || { echo 'Whisper tracked files have local changes; refusing build' >&2; exit 1; }
metal=OFF
if [[ "$(uname -s)" == Darwin ]]; then metal=ON; fi
"$cmake_bin" -S "$source_dir" -B "$source_dir/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL="$metal" -DGGML_CUDA=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
"$cmake_bin" --build "$source_dir/build" --target whisper-cli -j 4
printf 'Whisper executable: %s\n' "$source_dir/build/bin/whisper-cli"
