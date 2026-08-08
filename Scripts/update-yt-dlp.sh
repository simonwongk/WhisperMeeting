#!/bin/zsh
set -euo pipefail

# Updates just the link-import downloader inside the existing Whisper runtime venv (F183).
#
# This exists because yt-dlp goes stale on a scale of weeks — sites change how they serve media, and
# the honest remedy is "update the downloader", which `MediaDownloadFailureClassifier` surfaces as its
# own `updateDownloader` action. Rebuilding the entire meetings venv to refresh one package would be
# absurd, so this is deliberately small. It takes the SAME cross-process lock as
# setup-local-whisper.sh, so it can never race an install/upgrade of the runtime it is modifying.

runtime_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime}"
venv_target="$runtime_directory/venv"
lock_file="$runtime_directory/.venv-install.lock"
lock_acquired=0

cleanup() {
  [[ "$lock_acquired" -eq 1 ]] && rm -f "$lock_file"
}
trap cleanup EXIT HUP INT TERM

if [[ ! -x "$venv_target/bin/python" ]]; then
  print -u2 "The local Whisper runtime is not installed yet — install it in Settings first; it includes the downloader."
  exit 1
fi

if ! /usr/bin/shlock -p $$ -f "$lock_file"; then
  print -u2 "Another WhisperMeet runtime install or update is already running. Try again when it finishes."
  exit 1
fi
lock_acquired=1

# Unpinned on purpose: tracking the moving target IS this dependency's job (see setup-local-whisper.sh).
"$venv_target/bin/python" -m pip install --upgrade yt-dlp

# Prove the result actually runs, rather than reporting success on a broken install.
"$venv_target/bin/yt-dlp" --version
