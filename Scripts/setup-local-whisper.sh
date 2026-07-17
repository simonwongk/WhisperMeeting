#!/bin/zsh
set -euo pipefail

runtime_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime}"

if [[ -x /opt/homebrew/bin/brew ]]; then
  brew_executable=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
  brew_executable=/usr/local/bin/brew
else
  print -u2 "Homebrew is required to install FFmpeg and Python 3.11."
  exit 1
fi

if [[ ! -x /opt/homebrew/bin/ffmpeg && ! -x /usr/local/bin/ffmpeg ]]; then
  "$brew_executable" install ffmpeg
fi

if ! "$brew_executable" list python@3.11 >/dev/null 2>&1; then
  "$brew_executable" install python@3.11
fi

python_executable="$($brew_executable --prefix python@3.11)/bin/python3.11"
mkdir -p "$runtime_directory"
"$python_executable" -m venv "$runtime_directory/venv"
"$runtime_directory/venv/bin/python" -m pip install --upgrade pip
"$runtime_directory/venv/bin/python" -m pip install --upgrade openai-whisper
"$runtime_directory/venv/bin/whisper" --help >/dev/null

print "Local Whisper is ready at $runtime_directory/venv/bin/whisper"
