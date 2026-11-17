#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This script is for macOS; use README.md for Linux development.' >&2
  exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --with-microphone && "$1" != --recording-only ) ]]; then
  echo 'Usage: bash scripts/setup-macos.sh [--with-microphone | --recording-only]' >&2
  exit 1
fi
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
if [[ "${1:-}" == --recording-only ]]; then
  for tool in cargo swift c++; do command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }; done
  cargo build --locked
  swift build --package-path native/macos
  printf '\nRecording-only setup finished. Start with: bash scripts/start-macos.sh\n'
  exit 0
fi
for tool in cargo git python3 cmake ffmpeg c++; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool. See docs/mac-testing.md" >&2; exit 1; }
done
python3 -c 'import tarfile; assert hasattr(tarfile,"data_filter"), "Use a recent Python (recommended 3.12+)"'
export VTRACKER_TOOLS_DIR="${VTRACKER_TOOLS_DIR:-$HOME/.local/share/vtracker}"
bash scripts/setup-whisper.sh
python3 scripts/download-model.py "$VTRACKER_TOOLS_DIR/models/ggml-tiny.bin"
python3 scripts/setup-diarization.py "$VTRACKER_TOOLS_DIR/diarization"
python3 scripts/build-voice-helper.py
cargo build --locked
if [[ "${1:-}" == --with-microphone || -f native/macos/.build/debug/vtracker-capture ]]; then
  swift build --package-path native/macos
fi
printf '\nSetup finished. Start with: bash scripts/start-macos.sh\n'
