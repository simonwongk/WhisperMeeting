#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

cache_root="${TMPDIR:-/tmp}/whispermeet-build"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root/xdg}"

# The app is already built inside the caller's security boundary. Disabling
# SwiftPM's nested sandbox also makes this script work in managed CI/agent
# environments where sandbox-exec cannot create another profile.
swift build --disable-sandbox -c release

app_dir=".build/WhisperMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/WhisperMeet" "$app_dir/Contents/MacOS/WhisperMeet"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "Scripts/setup-local-whisper.sh" "$app_dir/Contents/Resources/setup-local-whisper.sh"
chmod +x "$app_dir/Contents/Resources/setup-local-whisper.sh"
cp "Scripts/whisper_dictate_server.py" "$app_dir/Contents/Resources/whisper_dictate_server.py"
cp "Scripts/setup-qwen-asr.sh" "$app_dir/Contents/Resources/setup-qwen-asr.sh"
chmod +x "$app_dir/Contents/Resources/setup-qwen-asr.sh"
cp "Scripts/qwen_transcribe.py" "$app_dir/Contents/Resources/qwen_transcribe.py"
codesign --force --deep --sign - "$app_dir"

print -r -- "$PWD/$app_dir"
