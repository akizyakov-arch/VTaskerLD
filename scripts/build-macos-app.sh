#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_dir/native/macos"
tools_dir="${VTRACKER_TOOLS_DIR:-$HOME/.local/share/vtracker}"
if [[ -f "$tools_dir/whisper.cpp/build/src/libwhisper.dylib" ]]; then
    bash "$repo_dir/scripts/build-whisper-worker.sh"
fi
cargo build --locked --manifest-path "$repo_dir/Cargo.toml"
swift build --package-path "$package" --product VTASK
swift build --package-path "$package" --product vtracker-capture
bin_dir="$(swift build --package-path "$package" --show-bin-path)"
app="$package/.build/VTASK.app"

resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/scripts"
cp "$package/Resources/VTASK.icns" "$package/Sources/VTASK/Resources/meeting-topics.json" "$resources/"
cp "$repo_dir/web/vtask-light.svg" "$repo_dir/web/vtask-dark.svg" "$resources/"
# Replace executables atomically so a running core keeps its signed inode.
install -S -m 755 "$repo_dir/target/debug/vtracker" "$app/Contents/MacOS/vtracker"
install -S -m 755 "$bin_dir/vtracker-capture" "$app/Contents/MacOS/vtracker-capture"
cp "$repo_dir/scripts/start-macos.sh" "$repo_dir/scripts/groq-analyze.py" "$repo_dir/scripts/piper-irina.py" "$resources/scripts"
for helper in vtracker-diarize vtracker-embed; do
    source="$repo_dir/native/diarization/.build/$helper"
    if [[ -x "$source" ]]; then
        install -S -m 755 "$source" "$app/Contents/MacOS/$helper"
    fi
done
for helper in vtracker-whisper-worker vtracker-speaker-worker; do
    source="$repo_dir/native/inference/.build/$helper"
    if [[ -x "$source" ]]; then
        install -S -m 755 "$source" "$app/Contents/MacOS/$helper"
    fi
done
install -S -m 755 "$bin_dir/VTASK" "$app/Contents/MacOS/VTASK"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VTASK</string>
    <key>CFBundleIdentifier</key><string>local.vtask.desktop</string>
    <key>CFBundleName</key><string>VTASK</string>
    <key>CFBundleIconFile</key><string>VTASK.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>NSMicrophoneUsageDescription</key><string>VTASK использует микрофон для голосового поиска.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>VTASK распознаёт поисковый запрос.</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Finder may attach metadata to a previously opened build.
if xattr -p com.apple.FinderInfo "$app" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$app"
fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$app/Contents/MacOS/vtracker"
codesign --verify --strict "$app/Contents/MacOS/vtracker-capture"
printf '%s\n' "$app"
