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
# F520: set only while the new venv sits at the live path unverified — see cleanup_and_restore.
new_venv_swapped_in=0
lock_acquired=0
# The Quick Dictation model's cache, a sibling of Runtime/ (LocalWhisperRuntime.modelDirectory), and
# the pinned model's directory in it — `models--${dictation_repository//\//--}` below, spelled out
# here because the reclaim needs it before that block runs (a script test pins the two together).
hub_directory="${runtime_directory:h}/Models/hf/hub"
dictation_model_directory_name="models--mlx-community--whisper-large-v3-turbo"
# Set by the Quick Dictation model's own staged swap below; empty until it starts (cleanup_and_restore).
dictation_staging=""
dictation_backup=""
dictation_target=""

mkdir -p "$runtime_directory"

venv_is_complete() {
  candidate="$1"
  [[ -x "$candidate/bin/python" && -x "$candidate/bin/whisper" ]]
}

# Stronger than a structural check: does the venv's whisper actually RUN? A structurally-complete venv
# whose console-script shebang points at a gone path (e.g. left by an interrupted install) passes
# venv_is_complete but is broken, so the live path is validated by whether it runs before any backup
# is purged.
venv_works() {
  candidate="$1"
  [[ -x "$candidate/bin/whisper" ]] && "$candidate/bin/whisper" --help >/dev/null 2>&1
}

cleanup_and_restore() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  # F520: an exit while the new venv sits at the live path unverified — the relocated
  # `whisper --help` below takes seconds with real torch, so that is where a Cancel (SIGTERM to the
  # process group) lands — removes it, so the restore below can put the previous venv back. Before
  # this the restore ran only when the live path was already missing, so a cancel there left the
  # unverified venv live and the previous one stranded in a hidden backup. Gated on this run's own
  # flag rather than on a backup existing: a same-PID leftover backup can exist until the swap
  # removes it, and an early exit must never trade the live venv for that.
  if [[ "$activation_complete" -eq 0 && "$new_venv_swapped_in" -eq 1 ]]; then
    rm -rf "$venv_target"
  fi
  # If activation never completed and the live venv had been moved aside, put it back.
  if [[ "$activation_complete" -eq 0
        && ! -e "$venv_target"
        && -e "$backup_venv" ]]; then
    mv "$backup_venv" "$venv_target"
  fi
  [[ -d "$staging_venv" ]] && rm -rf "$staging_venv"
  # F520 (review): the Quick Dictation model is staged and swapped under Models/hf/hub, outside
  # Runtime/, and this trap used to know nothing of it: a Cancel or Quit during its ~1.5 GB download
  # left the partial download there for good, and one between moving the old model aside and moving
  # the new one in left the model only in its backup. Put a displaced model back if its place is
  # empty, then drop the backup and the staging directory.
  if [[ -n "$dictation_backup" && -e "$dictation_backup" ]]; then
    [[ -e "$dictation_target" ]] || mv "$dictation_backup" "$dictation_target"
    rm -rf "$dictation_backup"
  fi
  [[ -n "$dictation_staging" ]] && rm -rf "$dictation_staging"
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

# Reclaim installer-owned artifacts while holding the lock. Restore the previous runtime if the live
# venv is missing OR present-but-nonfunctional — a crash could leave a structurally-complete but
# broken venv, and purging backups on `venv_is_complete` alone would then delete the only good copy
# while the live runtime is broken (unrecoverable). Gate both the restore and the purge on whether the
# live venv actually RUNS, so a good backup is never removed unless a working runtime is in place.
if ! venv_works "$venv_target"; then
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do
    if venv_is_complete "$orphaned_backup"; then
      rm -rf "$venv_target"
      mv "$orphaned_backup" "$venv_target"
      print -u2 "Restored the previous Local Whisper runtime after an interrupted installation."
      break
    fi
  done
fi
if venv_works "$venv_target"; then
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do rm -rf "$orphaned_backup"; done
else
  for orphaned_backup in "$runtime_directory"/.venv-backup-*(N); do
    venv_is_complete "$orphaned_backup" || rm -rf "$orphaned_backup"
  done
fi
for abandoned_staging in "$runtime_directory"/.venv-install-*(N); do rm -rf "$abandoned_staging"; done
# The same for the Quick Dictation model, left by an install whose trap never ran (a power loss): put
# a displaced model back if its place is empty, and drop partial downloads. Such an install also left
# its `.venv-install-*` behind — the model is fetched while the staging venv exists — so this runs at
# launch whenever it is needed, not only at the next install.
for orphaned_model in "$hub_directory"/.dictation-model-backup-*(N); do
  if [[ ! -e "$hub_directory/$dictation_model_directory_name" ]]; then
    mv "$orphaned_model" "$hub_directory/$dictation_model_directory_name"
  else
    rm -rf "$orphaned_model"
  fi
done
for abandoned_download in "$hub_directory"/.dictation-model-staging-*(N); do rm -rf "$abandoned_download"; done

# Recovery-only mode (F520): reclaim and stop, as QWEN_/SUMMARIZER_/DIARIZATION_INSTALL_RECOVERY_ONLY
# do for their runtimes (F33, F167, F219). The app runs this at launch, before it probes the runtime,
# when an interrupted install left `.venv-backup-*` or `.venv-install-*` behind — a battery that died
# mid-repair, or a force quit. It needs the block above and none of what follows: a Mac recovering
# an install already has its runtime, and requiring Homebrew would fail the reclaim on exactly the
# machines that need it. Placed after the reclaim and before the first precondition.
if [[ "${WHISPER_INSTALL_RECOVERY_ONLY:-0}" == "1" ]]; then
  exit 0
fi

# F545: which optional tools the WORKING install has, recorded before anything is staged. mlx-whisper
# and yt-dlp are installed best-effort below, so on a flaky connection a repair used to build a venv
# without them, swap it in over the one that had them, delete that one, and report "ready" — a
# repair that removed Quick Dictation and link import. Only a working install is protected: keeping
# a venv whose `whisper` does not run, to save an optional tool, would trade the meetings runtime for
# it. (Neither probe joins venv_works — see the yt-dlp note below for why that would be wrong.)
live_has_mlx_whisper=0
live_has_yt_dlp=0
if venv_works "$venv_target"; then
  if "$venv_target/bin/python" -c "import mlx_whisper" >/dev/null 2>&1; then
    live_has_mlx_whisper=1
  fi
  if [[ -x "$venv_target/bin/yt-dlp" ]] && "$venv_target/bin/yt-dlp" --version >/dev/null 2>&1; then
    live_has_yt_dlp=1
  fi
fi

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

# F483: pinned to the exact versions the rest of this repo already assumes, rather than
# `--upgrade` to whatever pip resolves that day. openai-whisper 20250625 is what
# LocalWhisperClient.supportedCLIFlags/commandArguments were derived from — a --carry_initial_prompt
# that only exists from this version on, per the live source at
# https://github.com/openai/whisper/blob/v20250625/whisper/transcribe.py — and an unpinned
# `--upgrade` could resolve a release that removed or renamed a flag commandArguments still emits,
# which exits every vocabulary-bearing meeting with argparse status 2 and no rollback once the
# staging venv passes `--help` and the working venv is deleted. mlx-whisper 0.4.3 is
# EXPECTED_MLX_WHISPER_VERSION in whisper_dictate_server.py, which the F210 fast path's ladder and
# thresholds were read from; that helper already declines the fast path on a mismatch, so pinning
# here keeps the common case matching rather than falling back on every dictation.
openai_whisper_version="20250625"
mlx_whisper_version="0.4.3"

# Build the new runtime in a STAGING venv; the live venv is untouched until the atomic swap below.
"$python_executable" -m venv "$staging_venv"
"$staging_venv/bin/python" -m pip install --upgrade pip
# openai-whisper drives meetings (LocalWhisperClient) and MUST succeed — install and verify it in
# staging first so the meetings runtime is never left unverified by a later, optional dependency, and
# a failed upgrade can never break the working live install.
"$staging_venv/bin/python" -m pip install "openai-whisper==$openai_whisper_version"
"$staging_venv/bin/whisper" --help >/dev/null

# mlx-whisper drives quick dictation (Apple-Silicon warm helper). It is arm64-only with a larger
# dependency tree, so install it best-effort: a failure here must NOT abort the meetings runtime.
# (Commands in an `if` condition are exempt from `set -e`, so a failure won't kill the script.)
if ! "$staging_venv/bin/python" -m pip install "mlx-whisper==$mlx_whisper_version"; then
  print -u2 "Note: mlx-whisper install failed — Quick Dictation unavailable on this Mac (meetings unaffected)."
fi

# F483: pre-download and pin the Quick Dictation model, exactly like every other model this repo
# installs (Ask embeddings, the summarizer, Qwen, diarization all pin a revision and verify
# SHA-256). Until this, whisper_dictate_server.py fetched `mlx-community/whisper-large-v3-turbo`
# from whatever its mutable main branch held the first time dictation warmed up, verified nothing,
# and recorded no revision. Best-effort, like the mlx-whisper package install just above: Quick
# Dictation must never block the meetings runtime, and the helper's own warm-up already falls back
# to an unpinned network fetch if this step did not run or did not finish (no network at install
# time, a build predating this fix, or a failure here) — the difference this makes is that the
# common case gets a verified, pinned model instead of whatever HEAD happens to hold that day.
dictation_repository="mlx-community/whisper-large-v3-turbo"
dictation_revision="a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
dictation_config_sha256="b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"
dictation_weights_sha256="951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"

if "$staging_venv/bin/python" -c "import mlx_whisper" >/dev/null 2>&1; then
  # Models/ is a SIBLING of Runtime/ (LocalWhisperRuntime.modelDirectory vs .managedDirectory) —
  # both openai-whisper's --model_dir and the dictation helper's HF cache live there.
  models_directory="${runtime_directory:h}/Models"
  hub_directory="$models_directory/hf/hub"
  dictation_repo_directory_name="models--${dictation_repository//\//--}"
  dictation_staging="$hub_directory/.dictation-model-staging-$$"
  mkdir -p "$hub_directory"
  rm -rf "$dictation_staging"

  if DICTATION_STAGE="$dictation_staging" DICTATION_REPOSITORY="$dictation_repository" \
     DICTATION_REVISION="$dictation_revision" \
     "$staging_venv/bin/python" - <<'PY' >/dev/null 2>&1
import os
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ["DICTATION_REPOSITORY"],
    revision=os.environ["DICTATION_REVISION"],
    cache_dir=os.environ["DICTATION_STAGE"],
    allow_patterns=["config.json", "weights.safetensors"],
)
PY
  then
    dictation_snapshot="$dictation_staging/$dictation_repo_directory_name/snapshots/$dictation_revision"
    actual_config_sha="$(shasum -a 256 "$dictation_snapshot/config.json" 2>/dev/null | awk '{ print $1 }')"
    actual_weights_sha="$(shasum -a 256 "$dictation_snapshot/weights.safetensors" 2>/dev/null | awk '{ print $1 }')"
    if [[ "$actual_config_sha" == "$dictation_config_sha256"
          && "$actual_weights_sha" == "$dictation_weights_sha256" ]]; then
      # `mlx_whisper.load_model` always resolves the bare repo id through huggingface_hub with no
      # revision argument at all — i.e. always "main" — so an offline load needs a local "main"
      # ref to read; huggingface_hub only writes one when IT resolved "main" itself, which a
      # pinned-commit `snapshot_download` (above) does not do. Write it here, pointing at the
      # commit we just verified, so the helper's `HF_HUB_OFFLINE=1` fast path (once fully cached)
      # keeps resolving to this exact pin rather than failing to resolve "main" at all.
      mkdir -p "$dictation_staging/$dictation_repo_directory_name/refs"
      print -n "$dictation_revision" > "$dictation_staging/$dictation_repo_directory_name/refs/main"

      dictation_target="$hub_directory/$dictation_repo_directory_name"
      dictation_backup="$hub_directory/.dictation-model-backup-$$"
      rm -rf "$dictation_backup"
      if [[ -e "$dictation_target" ]]; then
        mv "$dictation_target" "$dictation_backup"
      fi
      if mv "$dictation_staging/$dictation_repo_directory_name" "$dictation_target"; then
        rm -rf "$dictation_backup"
      elif [[ -e "$dictation_backup" ]]; then
        mv "$dictation_backup" "$dictation_target"
      fi
    else
      print -u2 "Note: the Quick Dictation model failed verification; it will download unpinned on first use (meetings unaffected)."
    fi
  else
    print -u2 "Note: could not pre-download the Quick Dictation model; it will download on first use (meetings unaffected)."
  fi
  rm -rf "$dictation_staging"
fi

# yt-dlp powers "import from a link" (F183). Three constraints fix exactly where and how it goes:
#   - AFTER openai-whisper is installed and verified, so the meetings runtime is never left unverified
#     behind an optional dependency;
#   - BEFORE the shebang rewrite below, or `bin/yt-dlp`'s console-script shebang still points at the
#     staging path and is a dead "bad interpreter" the moment the venv is swapped into place;
#   - inside an `if !` (exempt from `set -e`), so one transient PyPI failure cannot abort the whole
#     meetings-runtime install.
# It is deliberately UNPINNED, unlike the exact `==` pins in setup-qwen-asr.sh and
# setup-local-summarizer.sh: yt-dlp's entire job is to track a moving target, so pinning it guarantees
# eventual breakage rather than preventing it.
# NOTE: yt-dlp is intentionally NOT added to venv_is_complete()/venv_works() — those decide whether a
# runtime is healthy, and requiring yt-dlp would make every already-working install look broken and
# trigger a rollback to a backup that also lacks it.
if ! "$staging_venv/bin/python" -m pip install --upgrade yt-dlp; then
  print -u2 "Note: yt-dlp install failed — importing audio from a link is unavailable (meetings unaffected)."
fi

# F545: never swap a working optional tool away. If the live install had one and the staging venv
# could not get it, stop here: the live venv has not been touched yet, the EXIT trap removes the
# staging venv, and the app reports this line — the script's last — as the reason, not "ready".
# Checked at the staging path, before the shebang rewrite below points bin/yt-dlp at the live one.
lost_tools=()
if (( live_has_mlx_whisper )) \
   && ! "$staging_venv/bin/python" -c "import mlx_whisper" >/dev/null 2>&1; then
  lost_tools+=("Quick Dictation (mlx-whisper)")
fi
if (( live_has_yt_dlp )) \
   && ! { [[ -x "$staging_venv/bin/yt-dlp" ]] && "$staging_venv/bin/yt-dlp" --version >/dev/null 2>&1; }; then
  lost_tools+=("import from a link (yt-dlp)")
fi
if (( ${#lost_tools} > 0 )); then
  print -u2 "Local Whisper was not updated because ${(j: and :)lost_tools} could not be reinstalled; the working installation was kept unchanged. Check your connection and try Repair or Update again."
  exit 1
fi

# A Python venv is NOT relocatable: its console-script shebangs (e.g. `venv/bin/whisper` — the exact
# executable the app invokes via LocalWhisperRuntime.managedExecutable) and its activate scripts embed
# the absolute path it was created at. The `--help` check above passed because it ran while the venv
# was still at the staging path; a bare `mv` to the live path would leave `bin/whisper` with a
# "bad interpreter" shebang. So rewrite that staging path to the LIVE path *before* the move, so the
# venv works the instant it lands. (`bin/python` is a relative symlink and survives the move on its
# own; only the text console scripts embed the absolute path.)
"$python_executable" - "$staging_venv" "$venv_target" <<'PY'
import os
import sys

old = os.fsencode(sys.argv[1])
new = os.fsencode(sys.argv[2])
bindir = os.path.join(sys.argv[1], "bin")
for name in os.listdir(bindir):
    path = os.path.join(bindir, name)
    if os.path.islink(path) or not os.path.isfile(path):
        continue
    with open(path, "rb") as handle:
        data = handle.read()
    # Only rewrite console-script shebangs (files that start with "#!"). That covers venv/bin/whisper
    # — the executable the app runs — while never editing a compiled launcher (a length-changing byte
    # replace would corrupt a Mach-O) or the sourced-only activate scripts, which the app never uses.
    if data.startswith(b"#!") and old in data:
        with open(path, "wb") as handle:
            handle.write(data.replace(old, new))
PY

# Atomically swap the relocated staging venv in, keeping the prior venv as a restore-on-failure
# backup. `mv` within one directory is an atomic rename, so the live path is never half-populated.
rm -rf "$backup_venv"                      # never move the live venv into a leftover same-PID backup
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
new_venv_swapped_in=1
# Re-verify at the LIVE path — the relocated shebangs must actually run — and roll back if not.
if ! "$venv_target/bin/whisper" --help >/dev/null 2>&1; then
  rm -rf "$venv_target"
  # This branch does its own rollback, and the trap must not remove what it restores — but only
  # from here: a Cancel during the removal above must still let the trap finish it and restore the
  # backup, rather than leave a half-deleted venv live (review probe P2).
  new_venv_swapped_in=0
  if [[ -e "$backup_venv" ]]; then
    mv "$backup_venv" "$venv_target"
    print -u2 "The relocated Local Whisper runtime failed verification; the previous runtime was restored."
  else
    print -u2 "The Local Whisper runtime failed verification and there was no previous runtime to restore."
  fi
  exit 1
fi
activation_complete=1
# F654: the new venv is live and verified; nothing is left to put back, only the old copy to delete.
# A Cancel or Quit from here on finishes that and exits 0, rather than reporting "cancelled" for an
# update that happened. (Children inherit the ignore, so the `rm` below completes too.)
trap '' HUP INT TERM
new_venv_swapped_in=0
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
