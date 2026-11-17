#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then echo 'This script is for macOS.' >&2; exit 1; fi
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
tools_dir="${VTRACKER_TOOLS_DIR:-$HOME/.local/share/vtracker}"
runtime="$repo_dir/runtime"
if [[ -x "$runtime/bin/whisper-cli" ]]; then
  export VTRACKER_WHISPER_BIN="${VTRACKER_WHISPER_BIN:-$runtime/bin/whisper-cli}"
  export VTRACKER_FFMPEG_BIN="${VTRACKER_FFMPEG_BIN:-$runtime/bin/ffmpeg}"
  export VTRACKER_SEGMENTATION_MODEL="${VTRACKER_SEGMENTATION_MODEL:-$runtime/models/segmentation.onnx}"
  export VTRACKER_EMBEDDING_MODEL="${VTRACKER_EMBEDDING_MODEL:-$runtime/models/embedding.onnx}"
  export PATH="$runtime/python/bin:$PATH"
  if [[ -r /etc/ssl/cert.pem ]]; then export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"; fi
fi
export VTRACKER_WHISPER_BIN="${VTRACKER_WHISPER_BIN:-$tools_dir/whisper.cpp/build/bin/whisper-cli}"
default_model="$tools_dir/models/ggml-tiny.bin"
[[ ! -f "$tools_dir/models/ggml-large-v3-turbo-q5_0.bin" ]] || default_model="$tools_dir/models/ggml-large-v3-turbo-q5_0.bin"
if [[ ! -f "$default_model" && -f "$runtime/models/ggml-large-v3-turbo-q5_0.bin" ]]; then
  default_model="$runtime/models/ggml-large-v3-turbo-q5_0.bin"
fi
export VTRACKER_WHISPER_MODEL="${VTRACKER_WHISPER_MODEL:-$default_model}"
if [[ -z "${VTRACKER_VAD_MODEL+x}" ]]; then
  for vad_model in "$runtime/models/ggml-silero-v5.1.2.bin" \
    "$tools_dir/models/ggml-silero-v5.1.2.bin" \
    "$tools_dir/whisper.cpp/models/for-tests-silero-v5.1.2-ggml.bin"; do
    if [[ -r "$vad_model" ]]; then
      export VTRACKER_VAD_MODEL="$vad_model"
      break
    fi
  done
fi
if [[ -x "$repo_dir/native/inference/.build/vtracker-whisper-worker" ]]; then
  export VTRACKER_WHISPER_WORKER="${VTRACKER_WHISPER_WORKER:-$repo_dir/native/inference/.build/vtracker-whisper-worker}"
fi
if [[ -x "$repo_dir/native/inference/.build/vtracker-speaker-worker" ]]; then
  export VTRACKER_SPEAKER_WORKER="${VTRACKER_SPEAKER_WORKER:-$repo_dir/native/inference/.build/vtracker-speaker-worker}"
fi
# The workspace adapter supports an optional clustering threshold.
if [[ -z "${VTRACKER_DIARIZATION_BIN:-}" && -x "$repo_dir/native/diarization/.build/vtracker-diarize" ]]; then
  export VTRACKER_DIARIZATION_BIN="$repo_dir/native/diarization/.build/vtracker-diarize"
  export VTRACKER_CLUSTER_THRESHOLD="${VTRACKER_CLUSTER_THRESHOLD:-0.8}"
fi
export VTRACKER_DIARIZATION_BIN="${VTRACKER_DIARIZATION_BIN:-$tools_dir/diarization/vtracker-diarize}"
export VTRACKER_SEGMENTATION_MODEL="${VTRACKER_SEGMENTATION_MODEL:-$tools_dir/diarization/segmentation.onnx}"
export VTRACKER_EMBEDDING_MODEL="${VTRACKER_EMBEDDING_MODEL:-$tools_dir/diarization/embedding.onnx}"
export VTRACKER_EMBED_BIN="${VTRACKER_EMBED_BIN:-$repo_dir/native/diarization/.build/vtracker-embed}"
export VTRACKER_LANGUAGE="${VTRACKER_LANGUAGE:-ru}"
export VTRACKER_CAPTURE_BIN="${VTRACKER_CAPTURE_BIN:-$repo_dir/native/macos/.build/debug/vtracker-capture}"
core="${VTRACKER_CORE_BIN:-target/debug/vtracker}"
[[ -x "$core" ]] || { echo 'Build the core first: bash scripts/setup-macos.sh --recording-only' >&2; exit 1; }
# Missing speech assets are reported in the panel; they do not block microphone recording.
exec "$core" "$@" serve
