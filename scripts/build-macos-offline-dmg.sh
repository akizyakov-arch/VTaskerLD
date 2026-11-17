#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 4 ]]; then
  echo "Usage: bash scripts/build-macos-offline-dmg.sh FFMPEG FFMPEG_SOURCE_ARCHIVE PORTABLE_PYTHON_DIR OUTPUT_DMG" >&2
  exit 2
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tools="${VTRACKER_TOOLS_DIR:-$HOME/.local/share/vtracker}"
whisper="$tools/whisper.cpp/build"
sherpa="$tools/diarization/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

bash "$repo_dir/scripts/build-macos-app.sh"
app="$stage/VTASK.app"
ditto "$repo_dir/native/macos/.build/VTASK.app" "$app"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 26.0" "$app/Contents/Info.plist"
resources="$app/Contents/Resources"
runtime="$resources/runtime"
lib="$app/Contents/Frameworks"
mkdir -p "$runtime"/{bin,models,voices,notices} "$lib"
install -m 755 "$1" "$runtime/bin/ffmpeg"
cp "$2" "$runtime/notices/"
"$runtime/bin/ffmpeg" -buildconf > "$runtime/notices/ffmpeg-build-config.txt" 2>&1
ditto "$3" "$runtime/python"
install -m 755 "$whisper/bin/whisper-cli" "$runtime/bin/whisper-cli"
cp "$whisper/src/libwhisper.1.dylib" "$lib/"
cp "$whisper/ggml/src/"{libggml,libggml-base,libggml-cpu}.dylib "$lib/"
cp "$whisper/ggml/src/ggml-blas/libggml-blas.dylib" "$whisper/ggml/src/ggml-metal/libggml-metal.dylib" "$lib/"
cp "$sherpa/lib/"{libsherpa-onnx-c-api,libonnxruntime}.dylib "$lib/"
cp "$tools/whisper.cpp/LICENSE" "$runtime/notices/whisper.cpp-LICENSE"
cp "$tools/models/ggml-large-v3-turbo-q5_0.bin" "$runtime/models/"
cp "$tools/diarization/"{segmentation,embedding}.onnx "$runtime/models/"
for voice in irina dmitri; do
  name="vits-piper-ru_RU-$voice-medium"
  ditto "$tools/tts/piper-irina/$name" "$runtime/voices/$name"
done

relocate() {
  local binary="$1" relative="$2" old
  while IFS= read -r old; do
    [[ "$old" = /* ]] || continue
    install_name_tool -delete_rpath "$old" "$binary"
  done < <(otool -l "$binary" | awk '/cmd LC_RPATH/{getline;getline; sub(/^[[:space:]]*path /,""); sub(/ \(offset [0-9]+\)$/,""); print}')
  install_name_tool -add_rpath "$relative" "$binary"
}
relocate "$runtime/bin/whisper-cli" '@loader_path/../../../Frameworks'
for helper in vtracker-diarize vtracker-embed vtracker-whisper-worker vtracker-speaker-worker; do
  [[ -x "$app/Contents/MacOS/$helper" ]] || continue
  relocate "$app/Contents/MacOS/$helper" '@loader_path/../Frameworks'
done
for dylib in "$lib/"*.dylib; do
  codesign --force --sign - "$dylib"
done
for binary in "$runtime/bin/"* "$app/Contents/MacOS/"vtracker-{diarize,embed,whisper-worker,speaker-worker}; do
  [[ -x "$binary" ]] || continue
  codesign --force --sign - "$binary"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

env -i HOME="$stage" PATH=/usr/bin:/bin "$runtime/bin/whisper-cli" --help >/dev/null 2>&1
env -i HOME="$stage" PATH=/usr/bin:/bin "$runtime/bin/ffmpeg" -version >/dev/null
printf 'Привет! Это проверка голоса Валли. Сегодня мы тестируем локальное распознавание речи. После окончания теста можно открыть протокол встречи и прочитать итоговый текст.' > "$stage/check.txt"
for voice in irina dmitri; do
  env -i HOME="$stage" PATH=/usr/bin:/bin "$runtime/python/bin/python3" \
    "$resources/scripts/piper-irina.py" "$runtime/voices/vits-piper-ru_RU-$voice-medium" \
    "$stage/check.txt" "$stage/$voice.wav"
done
env -i HOME="$stage" PATH=/usr/bin:/bin "$runtime/bin/ffmpeg" -nostdin -loglevel error \
  -i "$stage/dmitri.wav" -ac 1 -ar 16000 -c:a pcm_s16le "$stage/asr.wav"
env -i HOME="$stage" PATH=/usr/bin:/bin "$runtime/bin/whisper-cli" \
  -m "$runtime/models/ggml-large-v3-turbo-q5_0.bin" -f "$stage/asr.wav" \
  -l ru -t 2 -oj -of "$stage/asr" > "$stage/whisper.log" 2>&1 || {
    cat "$stage/whisper.log" >&2; exit 1;
  }
"$runtime/python/bin/python3" -c 'import json,sys; assert any(s["text"].strip() for s in json.load(open(sys.argv[1]))["transcription"])' "$stage/asr.json"

env -i HOME="$stage" PATH=/usr/bin:/bin "$app/Contents/MacOS/vtracker-embed" \
  "$runtime/models/embedding.onnx" "$stage/asr.wav" "$stage/embedding.json"
env -i HOME="$stage" PATH=/usr/bin:/bin "$app/Contents/MacOS/vtracker-diarize" \
  "$runtime/models/segmentation.onnx" "$runtime/models/embedding.onnx" \
  "$stage/asr.wav" "$stage/speakers.json" 0
test -s "$stage/embedding.json" && test -s "$stage/speakers.json"

mkdir "$stage/image"
mv "$app" "$stage/image/"
ln -s /Applications "$stage/image/Applications"
hdiutil create -volname VTASK -srcfolder "$stage/image" -format UDZO "$4"
hdiutil verify "$4"
