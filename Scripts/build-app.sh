#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

app_dir=".build/WhisperMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/WhisperMeet" "$app_dir/Contents/MacOS/WhisperMeet"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"

print -r -- "$PWD/$app_dir"
