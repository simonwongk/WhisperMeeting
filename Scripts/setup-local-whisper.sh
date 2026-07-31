#!/bin/zsh
set -euo pipefail

runtime_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime}"
script_directory="${0:A:h}"
dictation_helper_source="$script_directory/whisper_dictate_server.py"

# The default meetings runtime is the venv under $runtime_directory. That directory ALSO holds the
# optional Qwen3ASR runtime and the dictation helper, so staging/backup/swap are scoped to `venv`
# alone — never the whole $runtime_directory — and the new venv is built in a staging directory and
# swapped in atomically, keeping the prior venv as a restore-on-failure backup. This mirrors the
# proven pattern in setup-qwen-asr.sh, so a failed or interrupted `pip install --upgrade` (which
# uninstalls the old package before installing the new) can never leave a working install broken with
# no rollback (F52).
venv_target="$runtime_directory/venv"
staging_venv="$runtime_directory/.venv-install-$$"
backup_venv="$runtime_directory/.venv-backup-$$"
lock_file="$runtime_directory/.venv-install.lock"
activation_complete=0
lock_acquired=0

mkdir -p "$runtime_directory"

venv_is_complete() {
  candidate="$1"
  [[ -x "$candidate/bin/python" && -x "$candidate/bin/whisper" ]]
}

cleanup_and_restore() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  # If activation never completed and the live venv had been moved aside, put it back.
  if [[ "$activation_complete" -eq 0
        && ! -e "$venv_target"
        && -e "$backup_venv" ]]; then
    mv "$backup_venv" "$venv_target"
  fi
  [[ -d "$staging_venv" ]] && rm -rf "$staging_venv"
  [[ "$lock_acquired" -eq 1 ]] && rm -f "$lock_file"
  exit "$exit_status"
}
trap cleanup_and_restore EXIT
trap 'exit 130' HUP INT TERM

if ! /usr/bin/shlock -p $$ -f "$lock_file"; then
  print -u2 "Another Local Whisper installation is already running."
  exit 1
fi
lock_acquired=1

# Reclaim installer-owned artifacts while holding the lock: restore a complete backup if the live
# venv vanished (an install interrupted after the swap moved it aside), and clear abandoned staging
# directories and incomplete backups — neither can ever serve as a runtime.
if [[ ! -e "$venv_target" ]]; then
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do
    if venv_is_complete "$orphaned_backup"; then
      mv "$orphaned_backup" "$venv_target"
      print -u2 "Restored the previous Local Whisper runtime after an interrupted installation."
      break
    fi
  done
fi
if venv_is_complete "$venv_target"; then
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do rm -rf "$orphaned_backup"; done
else
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do
    venv_is_complete "$orphaned_backup" || rm -rf "$orphaned_backup"
  done
fi
for abandoned_staging in "$runtime_directory"/.venv-install-*(N); do rm -rf "$abandoned_staging"; done

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

# Build the new runtime in a STAGING venv; the live venv is untouched until the atomic swap below.
"$python_executable" -m venv "$staging_venv"
"$staging_venv/bin/python" -m pip install --upgrade pip
# openai-whisper drives meetings (LocalWhisperClient) and MUST succeed — install and verify it in
# staging first so the meetings runtime is never left unverified by a later, optional dependency, and
# a failed upgrade can never break the working live install.
"$staging_venv/bin/python" -m pip install --upgrade openai-whisper
"$staging_venv/bin/whisper" --help >/dev/null

# mlx-whisper drives quick dictation (Apple-Silicon warm helper). It is arm64-only with a larger
# dependency tree, so install it best-effort: a failure here must NOT abort the meetings runtime.
# (Commands in an `if` condition are exempt from `set -e`, so a failure won't kill the script.)
if ! "$staging_venv/bin/python" -m pip install --upgrade mlx-whisper; then
  print -u2 "Note: mlx-whisper install failed — Quick Dictation unavailable on this Mac (meetings unaffected)."
fi

# Atomically swap the verified staging venv in, keeping the prior venv as a restore-on-failure backup.
if [[ -e "$venv_target" ]]; then
  mv "$venv_target" "$backup_venv"
fi
if ! mv "$staging_venv" "$venv_target"; then
  if [[ -e "$backup_venv" ]]; then
    mv "$backup_venv" "$venv_target"
  fi
  print -u2 "The new Local Whisper runtime could not be activated; the previous runtime was restored."
  exit 1
fi
activation_complete=1
if [[ -e "$backup_venv" ]]; then
  if ! rm -rf "$backup_venv"; then
    print -u2 "Local Whisper was activated, but its prior-runtime backup could not be removed."
  fi
fi

# The dictation helper is a small script the app also keeps in sync on launch (F25); refresh it here.
if [[ -f "$dictation_helper_source" ]]; then
  cp "$dictation_helper_source" "$runtime_directory/whisper_dictate_server.py"
fi

rm -f "$lock_file"
lock_acquired=0
trap - EXIT HUP INT TERM

print "Local Whisper is ready at $venv_target/bin/whisper"
