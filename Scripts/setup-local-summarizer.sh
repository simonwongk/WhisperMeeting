#!/bin/zsh
set -euo pipefail

# Installs the on-device summarization runtime (F164): a dedicated mlx_lm venv + a pinned Qwen3 model
# + the summarize_local.py helper, under Runtime/Summarizer. It is deliberately separate from the
# Qwen3-ASR runtime because local summaries are the DEFAULT summarizer and must not require the opt-in
# ASR runtime. Mirrors setup-qwen-asr.sh: staging dir, cross-process lock, sha256 gate, atomic
# activation with backup/restore. The caller (AppModel) exports SUMMARIZER_REPOSITORY to pick 8B vs 4B.

target_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime/Summarizer}"
script_directory="${0:A:h}"
helper_source="$script_directory/summarize_local.py"
correction_helper_source="$script_directory/correct_local.py"
runtime_parent="${target_directory:h}"
staging_directory="$runtime_parent/.Summarizer-install-$$"
backup_directory="$runtime_parent/.Summarizer-backup-$$"
lock_file="$runtime_parent/.Summarizer-install.lock"
activation_complete=0
lock_acquired=0

mlx_lm_version="0.30.5"
default_repository="mlx-community/Qwen3-8B-4bit"
default_revision="545dc4251c05440727734bcd94334791f6ab0192"
default_sha256="f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8"
fallback_repository="mlx-community/Qwen3-4B-4bit"
fallback_revision="4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"
fallback_sha256="e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d"

# The Swift side chooses the model by physical RAM and exports it; default to the 8B model.
repository="${SUMMARIZER_REPOSITORY:-$default_repository}"
case "$repository" in
  "$default_repository") revision="$default_revision"; model_sha256="$default_sha256" ;;
  "$fallback_repository") revision="$fallback_revision"; model_sha256="$fallback_sha256" ;;
  *) print -u2 "Unknown summarizer model: $repository"; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "Local summaries currently require an Apple-silicon Mac."
  exit 1
fi
if [[ ! -f "$helper_source" ]]; then
  print -u2 "The bundled local-summarizer helper is missing."
  exit 1
fi
if [[ ! -f "$correction_helper_source" ]]; then
  print -u2 "The bundled transcript-correction helper is missing."
  exit 1
fi

mkdir -p "$runtime_parent"

runtime_is_complete() {
  candidate="$1"
  [[ -x "$candidate/venv/bin/python"
    && -f "$candidate/summarize_local.py"
    && -f "$candidate/model/model.safetensors" ]]
}

cleanup_and_restore() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  if [[ "$activation_complete" -eq 0
        && ! -e "$target_directory"
        && -e "$backup_directory" ]]; then
    mv "$backup_directory" "$target_directory"
  fi
  if [[ -d "$staging_directory" ]]; then
    rm -rf "$staging_directory"
  fi
  if [[ "$lock_acquired" -eq 1 ]]; then
    rm -f "$lock_file"
  fi
  exit "$exit_status"
}
trap cleanup_and_restore EXIT
trap 'exit 130' HUP INT TERM

if ! /usr/bin/shlock -p $$ -f "$lock_file"; then
  print -u2 "Another local-summarizer installation is already running."
  exit 1
fi
lock_acquired=1

# Reclaim installer-owned artifacts while holding the lock: restore a complete prior backup if the
# canonical path vanished, and remove incomplete backups and abandoned staging dirs.
if [[ ! -e "$target_directory" ]]; then
  for orphaned_backup in "$runtime_parent"/.Summarizer-backup-*(N); do
    if runtime_is_complete "$orphaned_backup"; then
      mv "$orphaned_backup" "$target_directory"
      print -u2 "Restored the previous summarization model after an interrupted installation."
      break
    fi
  done
fi
for orphaned_backup in "$runtime_parent"/.Summarizer-backup-*(N); do
  if ! runtime_is_complete "$orphaned_backup"; then
    rm -rf "$orphaned_backup"
  fi
done
for abandoned_staging in "$runtime_parent"/.Summarizer-install-*(N); do
  rm -rf "$abandoned_staging"
done

available_kib="$(df -Pk "$runtime_parent" | awk 'NR == 2 { print $4 }')"
if [[ -z "$available_kib" || "$available_kib" -lt 8388608 ]]; then
  print -u2 "Local summaries need at least 8 GB of available storage to install safely."
  exit 1
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  brew_executable=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
  brew_executable=/usr/local/bin/brew
else
  print -u2 "Homebrew is required to install the isolated Python runtime."
  exit 1
fi
if ! "$brew_executable" list python@3.11 >/dev/null 2>&1; then
  "$brew_executable" install python@3.11
fi
python_executable="$($brew_executable --prefix python@3.11)/bin/python3.11"

mkdir -p "$staging_directory"
"$python_executable" -m venv "$staging_directory/venv"
"$staging_directory/venv/bin/python" -m pip install --upgrade pip
"$staging_directory/venv/bin/python" -m pip install "mlx-lm==$mlx_lm_version"

SUMMARIZER_STAGE="$staging_directory" \
SUMMARIZER_REPOSITORY="$repository" \
SUMMARIZER_REVISION="$revision" \
"$staging_directory/venv/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download

stage = os.environ["SUMMARIZER_STAGE"]
snapshot_download(
    repo_id=os.environ["SUMMARIZER_REPOSITORY"],
    revision=os.environ["SUMMARIZER_REVISION"],
    local_dir=os.path.join(stage, "model"),
)
PY

actual_model_sha="$(shasum -a 256 "$staging_directory/model/model.safetensors" | awk '{ print $1 }')"
if [[ "$actual_model_sha" != "$model_sha256" ]]; then
  print -u2 "Summarization model verification failed; the existing model was not changed."
  exit 1
fi

cp "$helper_source" "$staging_directory/summarize_local.py"
chmod 644 "$staging_directory/summarize_local.py"
cp "$correction_helper_source" "$staging_directory/correct_local.py"
chmod 644 "$staging_directory/correct_local.py"
{
  print "mlx-lm=$mlx_lm_version"
  print "summarizer_repository=$repository"
  print "summarizer_revision=$revision"
  print "summarizer_model_sha256=$model_sha256"
} > "$staging_directory/MANIFEST"

"$staging_directory/venv/bin/python" "$staging_directory/summarize_local.py" --help >/dev/null
"$staging_directory/venv/bin/python" "$staging_directory/correct_local.py" --help >/dev/null

if [[ -e "$target_directory" ]]; then
  mv "$target_directory" "$backup_directory"
fi
if ! mv "$staging_directory" "$target_directory"; then
  if [[ -e "$backup_directory" ]]; then
    mv "$backup_directory" "$target_directory"
  fi
  print -u2 "The new summarization model could not be activated; the previous one was restored."
  exit 1
fi
activation_complete=1
if [[ -e "$backup_directory" ]]; then
  if ! rm -rf "$backup_directory"; then
    print -u2 "Local summaries were activated, but the prior-model backup could not be removed."
  fi
fi
rm -f "$lock_file"
lock_acquired=0
trap - EXIT HUP INT TERM

print "Local summarization model is ready at $target_directory"
