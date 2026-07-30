#!/bin/zsh
set -euo pipefail

target_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR}"
script_directory="${0:A:h}"
helper_source="$script_directory/qwen_transcribe.py"
dictation_helper_source="$script_directory/qwen_dictate_server.py"
runtime_parent="${target_directory:h}"
staging_directory="$runtime_parent/.Qwen3ASR-install-$$"
backup_directory="$runtime_parent/.Qwen3ASR-backup-$$"
lock_file="$runtime_parent/.Qwen3ASR-install.lock"
activation_complete=0
lock_acquired=0

mlx_audio_version="0.3.1"
asr_repository="mlx-community/Qwen3-ASR-1.7B-8bit"
asr_revision="a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
asr_sha256="bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
aligner_repository="mlx-community/Qwen3-ForcedAligner-0.6B-8bit"
aligner_revision="0e1a68e91d815300c7c9754b2a7639378b23db15"
aligner_sha256="be19ef8ac4326d032e7673342930b14c2df30bd68c1632493b0f563e30829f91"

if [[ "${QWEN_INSTALL_RECOVERY_ONLY:-0}" != "1"
      && ( "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ) ]]; then
  print -u2 "Qwen3-ASR currently requires an Apple-silicon Mac."
  exit 1
fi
if [[ ! -f "$helper_source" ]]; then
  print -u2 "The bundled Qwen3-ASR helper is missing."
  exit 1
fi
if [[ ! -f "$dictation_helper_source" ]]; then
  print -u2 "The bundled Qwen3-ASR dictation helper is missing."
  exit 1
fi

mkdir -p "$runtime_parent"

runtime_is_complete() {
  candidate="$1"
  [[ -x "$candidate/venv/bin/python"
    && -f "$candidate/qwen_transcribe.py"
    && -f "$candidate/model/model.safetensors"
    && -f "$candidate/aligner/model.safetensors" ]]
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
  print -u2 "Another Qwen3-ASR installation is already running."
  exit 1
fi
lock_acquired=1

# Reclaim only installer-owned artifacts while holding the cross-process lock. A complete prior
# backup is restored if the canonical path vanished; incomplete backups and abandoned staging
# directories can never be used as runtimes and are safe to remove.
if [[ ! -e "$target_directory" ]]; then
  for orphaned_backup in "$runtime_parent"/.Qwen3ASR-backup-*(N); do
    if runtime_is_complete "$orphaned_backup"; then
      mv "$orphaned_backup" "$target_directory"
      print -u2 "Restored the previous Qwen3-ASR runtime after an interrupted installation."
      break
    fi
  done
fi
if runtime_is_complete "$target_directory"; then
  for orphaned_backup in "$runtime_parent"/.Qwen3ASR-backup-*(N); do
    rm -rf "$orphaned_backup"
  done
else
  for orphaned_backup in "$runtime_parent"/.Qwen3ASR-backup-*(N); do
    if ! runtime_is_complete "$orphaned_backup"; then
      rm -rf "$orphaned_backup"
    fi
  done
fi
for abandoned_staging in "$runtime_parent"/.Qwen3ASR-install-*(N); do
  rm -rf "$abandoned_staging"
done

if [[ "${QWEN_INSTALL_RECOVERY_ONLY:-0}" == "1" ]]; then
  exit 0
fi

available_kib="$(df -Pk "$runtime_parent" | awk 'NR == 2 { print $4 }')"
if [[ -z "$available_kib" || "$available_kib" -lt 6291456 ]]; then
  print -u2 "Qwen3-ASR needs at least 6 GB of available storage to install safely."
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
"$staging_directory/venv/bin/python" -m pip install "mlx-audio==$mlx_audio_version"

QWEN_STAGE="$staging_directory" \
QWEN_ASR_REPOSITORY="$asr_repository" \
QWEN_ASR_REVISION="$asr_revision" \
QWEN_ALIGNER_REPOSITORY="$aligner_repository" \
QWEN_ALIGNER_REVISION="$aligner_revision" \
"$staging_directory/venv/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download

stage = os.environ["QWEN_STAGE"]
snapshot_download(
    repo_id=os.environ["QWEN_ASR_REPOSITORY"],
    revision=os.environ["QWEN_ASR_REVISION"],
    local_dir=os.path.join(stage, "model"),
)
snapshot_download(
    repo_id=os.environ["QWEN_ALIGNER_REPOSITORY"],
    revision=os.environ["QWEN_ALIGNER_REVISION"],
    local_dir=os.path.join(stage, "aligner"),
)
PY

actual_asr_sha="$(shasum -a 256 "$staging_directory/model/model.safetensors" | awk '{ print $1 }')"
actual_aligner_sha="$(shasum -a 256 "$staging_directory/aligner/model.safetensors" | awk '{ print $1 }')"
if [[ "$actual_asr_sha" != "$asr_sha256" ]]; then
  print -u2 "Qwen3-ASR model verification failed; the existing runtime was not changed."
  exit 1
fi
if [[ "$actual_aligner_sha" != "$aligner_sha256" ]]; then
  print -u2 "Qwen3 aligner verification failed; the existing runtime was not changed."
  exit 1
fi

cp "$helper_source" "$staging_directory/qwen_transcribe.py"
chmod 644 "$staging_directory/qwen_transcribe.py"
cp "$dictation_helper_source" "$staging_directory/qwen_dictate_server.py"
chmod 644 "$staging_directory/qwen_dictate_server.py"
{
  print "mlx-audio=$mlx_audio_version"
  print "asr_repository=$asr_repository"
  print "asr_revision=$asr_revision"
  print "asr_model_sha256=$asr_sha256"
  print "aligner_repository=$aligner_repository"
  print "aligner_revision=$aligner_revision"
  print "aligner_model_sha256=$aligner_sha256"
} > "$staging_directory/MANIFEST"

"$staging_directory/venv/bin/python" "$staging_directory/qwen_transcribe.py" --help >/dev/null
"$staging_directory/venv/bin/python" "$staging_directory/qwen_dictate_server.py" --help >/dev/null

if [[ -e "$target_directory" ]]; then
  mv "$target_directory" "$backup_directory"
fi
if ! mv "$staging_directory" "$target_directory"; then
  if [[ -e "$backup_directory" ]]; then
    mv "$backup_directory" "$target_directory"
  fi
  print -u2 "The new runtime could not be activated; the previous runtime was restored."
  exit 1
fi
activation_complete=1
if [[ -e "$backup_directory" ]]; then
  if ! rm -rf "$backup_directory"; then
    print -u2 "Qwen3-ASR was activated, but its prior-runtime backup could not be removed."
  fi
fi
rm -f "$lock_file"
lock_acquired=0
trap - EXIT HUP INT TERM

print "Qwen3-ASR is ready at $target_directory"
