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
# openai-whisper drives meetings (LocalWhisperClient) and MUST succeed — install and verify it
# first so the meetings runtime is never left unverified by a later, optional dependency.
"$runtime_directory/venv/bin/python" -m pip install --upgrade openai-whisper
"$runtime_directory/venv/bin/whisper" --help >/dev/null

# mlx-whisper drives quick dictation (Apple-Silicon warm helper). It is arm64-only with a larger
# dependency tree, so install it best-effort: a failure here must NOT abort the meetings runtime.
# (Commands in an `if` condition are exempt from `set -e`, so a failure won't kill the script.)
if ! "$runtime_directory/venv/bin/python" -m pip install --upgrade mlx-whisper; then
  print -u2 "Note: mlx-whisper install failed — Quick Dictation unavailable on this Mac (meetings unaffected)."
fi

script_source="${0:A:h}/whisper_dictate_server.py"
if [[ -f "$script_source" ]]; then
  cp "$script_source" "$runtime_directory/whisper_dictate_server.py"
fi

print "Local Whisper is ready at $runtime_directory/venv/bin/whisper"
