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
cp "Scripts/qwen_dictate_server.py" "$app_dir/Contents/Resources/qwen_dictate_server.py"
cp "Scripts/setup-local-summarizer.sh" "$app_dir/Contents/Resources/setup-local-summarizer.sh"
chmod +x "$app_dir/Contents/Resources/setup-local-summarizer.sh"
cp "Scripts/update-yt-dlp.sh" "$app_dir/Contents/Resources/update-yt-dlp.sh"
chmod +x "$app_dir/Contents/Resources/update-yt-dlp.sh"
cp "Scripts/summarize_local.py" "$app_dir/Contents/Resources/summarize_local.py"
cp "Scripts/correct_local.py" "$app_dir/Contents/Resources/correct_local.py"
# Sign with a stable identity when one exists, so macOS TCC keeps the user's permission grants
# across rebuilds — an ad-hoc signature's identity changes every build, which resets microphone,
# screen-recording, and accessibility grants each time (F127). Override with
# WHISPERMEET_SIGNING_IDENTITY; otherwise a keychain certificate named "WhisperMeet Dev" is picked
# up automatically; otherwise fall back to ad-hoc and say how to fix it.
signing_identity="${WHISPERMEET_SIGNING_IDENTITY:-}"
# Match even an untrusted identity (note: no -v). A self-signed dev certificate is
# CSSMERR_TP_NOT_TRUSTED by default, yet codesign signs with it fine — signing needs the private key,
# not trust. Requiring a *trusted* identity (-v) meant the F128 certificate was never picked up and
# builds silently fell back to ad-hoc: the exact permission-reset loop this is meant to end (F131).
if [[ -z "$signing_identity" ]] \
  && security find-identity -p codesigning 2>/dev/null | grep -q '"WhisperMeet Dev"'; then
  signing_identity="WhisperMeet Dev"
fi
if [[ -n "$signing_identity" ]]; then
  codesign --force --deep --sign "$signing_identity" "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
  print -u2 "note: signed ad-hoc — macOS will re-ask for microphone/screen/accessibility after every rebuild."
  print -u2 "      One-time fix: Keychain Access → Certificate Assistant → Create a Certificate…"
  print -u2 "      Name: WhisperMeet Dev  ·  Identity Type: Self-Signed Root  ·  Certificate Type: Code Signing."
  print -u2 "      Rebuild afterwards and this script signs with it automatically."
fi

print -r -- "$PWD/$app_dir"
