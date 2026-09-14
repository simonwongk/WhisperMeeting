#!/bin/zsh
set -euo pipefail

# Installs the optional local speaker-analysis runtime (F216/F219). Same skeleton as
# setup-qwen-asr.sh — cross-process lock, orphan reclaim, staged install, verify-before-swap, atomic
# activation with rollback — but there is no Python here and, since F216 moved the runtime from the
# sherpa-onnx CLI to FluidAudio, no native binary either. The payload is 21.6 MB of compiled Core ML
# bundles; the code that loads them is inside WhisperMeet.
#
# Every file downloaded is pinned by SHA-256 and hashed in the same loop iteration that fetched it,
# so a file cannot be added to the manifest and silently skip its check. The staged tree is then
# required to be EXACTLY the manifest — no extra files, no symlinks — and the models are actually
# loaded and run before anything is activated.

target_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime/Diarization}"
script_directory="${0:A:h}"
notices_source="$script_directory/THIRD-PARTY-NOTICES.txt"
# In the packaged app the script and the notices are siblings in Contents/Resources, which is what
# build-app.sh produces. In a source checkout the script lives in Scripts/ and the notices in
# Resources/, and AppModel's development fallback runs the checkout copy directly — without this the
# notices gate below would refuse every developer install of a perfectly complete tree.
if [[ ! -f "$notices_source" && -f "${script_directory:h}/Resources/THIRD-PARTY-NOTICES.txt" ]]; then
  notices_source="${script_directory:h}/Resources/THIRD-PARTY-NOTICES.txt"
fi

# The smoke test has to LOAD Core ML models, and nothing on a stock Mac can do that from a shell.
# The one program that can is the app this installer ships inside, so the script calls it back with
# a headless flag. In the bundle that is Contents/MacOS/WhisperMeet, one directory over from
# Contents/Resources; in a checkout it is the built executable, mirroring the notices fallback.
smoke_test_command="${script_directory:h}/MacOS/WhisperMeet"
if [[ ! -x "$smoke_test_command" ]]; then
  for development_build in "${script_directory:h}/.build/release/WhisperMeet" \
                           "${script_directory:h}/.build/debug/WhisperMeet"; do
    if [[ -x "$development_build" ]]; then
      smoke_test_command="$development_build"
      break
    fi
  done
fi

runtime_parent="${target_directory:h}"
staging_directory="$runtime_parent/.Diarization-install-$$"
backup_directory="$runtime_parent/.Diarization-backup-$$"
lock_file="$runtime_parent/.Diarization-install.lock"
activation_complete=0
lock_acquired=0

model_repo="FluidInference/speaker-diarization-coreml"
model_base_url="https://huggingface.co/${model_repo}/resolve/main"

# NOT the repository name. FluidAudio resolves <models parent>/<Repo.diarizer.folderName>, and
# `folderName` strips the `-coreml` suffix from the Hugging Face slug. Staging into a directory
# named after the repo fails with `DownloadError.modelMissing(repo: "speaker-diarization", …)` — an
# error that names the FOLDER it looked in rather than the repo it wanted, so it actively
# misdirects. Verified by execution during the F216 evaluation; do not "correct" this to the slug.
model_directory_name="speaker-diarization"

# The complete payload: four compiled Core ML bundles (each a DIRECTORY of five files, not a single
# file) plus the PLDA parameters. 21,599,417 B in total. Hashes were computed with `shasum -a 256`
# from two independent downloads of the repository and are reproduced in
# docs/DIARIZATION_RUNTIME_DECISION.md §1; a test compares the two tables.
model_manifest=(
  "Segmentation.mlmodelc/analytics/coremldata.bin 64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"
  "Segmentation.mlmodelc/coremldata.bin ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"
  "Segmentation.mlmodelc/metadata.json 88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"
  "Segmentation.mlmodelc/model.mil d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"
  "Segmentation.mlmodelc/weights/weight.bin c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"
  "FBank.mlmodelc/analytics/coremldata.bin 0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"
  "FBank.mlmodelc/coremldata.bin 57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"
  "FBank.mlmodelc/metadata.json 2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"
  "FBank.mlmodelc/model.mil 27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"
  "FBank.mlmodelc/weights/weight.bin 9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"
  "Embedding.mlmodelc/analytics/coremldata.bin 8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"
  "Embedding.mlmodelc/coremldata.bin 4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"
  "Embedding.mlmodelc/metadata.json 1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"
  "Embedding.mlmodelc/model.mil 22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"
  "Embedding.mlmodelc/weights/weight.bin 99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"
  "PldaRho.mlmodelc/analytics/coremldata.bin 8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"
  "PldaRho.mlmodelc/coremldata.bin 4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"
  "PldaRho.mlmodelc/metadata.json b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"
  "PldaRho.mlmodelc/model.mil 83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"
  "PldaRho.mlmodelc/weights/weight.bin 80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"
  "plda-parameters.json 38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"
)

# Recorded in the MANIFEST so a result produced under a different pin stays identifiable. This is
# FluidAudio's community preset, NOT the 0.40 the F217 corpus derived for sherpa-onnx: sherpa's
# threshold is a cosine distance and FluidAudio's is a Euclidean distance in PLDA space, and the two
# are not comparable (old maps to new via sqrt(2 - 2*old)). Re-deriving it on annotated audio is
# F225; the value itself lives in FluidAudioDiarizationRuntime.clusterThreshold, which is what the
# app actually reads.
cluster_threshold="0.6"
runtime_id="fluidaudio-offline-diarizer"
runtime_version="0.15.7"

if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" != "1"
      && ( "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ) ]]; then
  print -u2 "Speaker analysis currently requires an Apple-silicon Mac."
  exit 1
fi
# Recovery-only mode reclaims an interrupted install and copies nothing, so it must not require the
# bundled notices or a built app to call back into — otherwise a build missing either would make the
# launch reclaim exit before it runs, stranding the orphaned runtime (the failure mode F33 closed
# for Qwen).
if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" != "1" ]]; then
  if [[ ! -f "$notices_source" ]]; then
    print -u2 "The bundled third-party notices are missing; the runtime is not shippable without them."
    exit 1
  fi
  # Checked here rather than at the smoke test itself so the refusal costs nothing: finding out
  # after 21.6 MB has been downloaded that nothing can verify it is a worse way to say the same no.
  if [[ ! -x "$smoke_test_command" ]]; then
    print -u2 "The speaker-analysis models cannot be verified on this Mac; nothing was changed."
    exit 1
  fi
fi

mkdir -p "$runtime_parent"

# The completeness predicate, used by the reclaim logic and by the final check before activation.
# It requires exactly the files `FluidAudioDiarizationRuntime.requiredModelFiles` requires, and a
# test compares the two lists mechanically: a subset on either side is how a tree this script would
# refuse gets reported to the app as healthy.
runtime_is_complete() {
  candidate="$1"
  [[ -f "$candidate/THIRD-PARTY-NOTICES.txt" && -f "$candidate/MANIFEST" ]] || return 1
  for manifest_entry in "${model_manifest[@]}"; do
    [[ -f "$candidate/models/$model_directory_name/${manifest_entry%% *}" ]] || return 1
  done
  return 0
}

# The Core ML replacement for the sherpa era's espeak (GPL-3.0) and socket symbol gates. Those read
# a native executable's symbol table; a `.mlmodelc` bundle is data and has none. What still applies
# is the question those gates really asked — "is the payload exactly what we pinned?" — so the
# staged tree must contain every manifest file, nothing else, and nothing that is not a plain file.
# A symlink in particular is a path out of the staged tree and into anything on the machine.
staged_models_match_manifest() {
  candidate="$1"
  [[ -d "$candidate" ]] || return 1
  if [[ -n "$(find "$candidate" ! -type d ! -type f -print -quit 2>/dev/null)" ]]; then
    return 1
  fi
  staged_files="$(cd "$candidate" && find . -type f -print | sed 's|^\./||' | sort)"
  pinned_files="$(print -l -- "${model_manifest[@]%% *}" | sort)"
  [[ "$staged_files" == "$pinned_files" ]]
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
  print -u2 "Another speaker-analysis installation is already running."
  exit 1
fi
lock_acquired=1

# Reclaim only installer-owned artifacts while holding the cross-process lock.
if [[ ! -e "$target_directory" ]]; then
  for orphaned_backup in "$runtime_parent"/.Diarization-backup-*(N); do
    if runtime_is_complete "$orphaned_backup"; then
      mv "$orphaned_backup" "$target_directory"
      print -u2 "Restored the previous speaker-analysis runtime after an interrupted installation."
      break
    fi
  done
fi
if runtime_is_complete "$target_directory"; then
  for orphaned_backup in "$runtime_parent"/.Diarization-backup-*(N); do
    rm -rf "$orphaned_backup"
  done
else
  for orphaned_backup in "$runtime_parent"/.Diarization-backup-*(N); do
    if ! runtime_is_complete "$orphaned_backup"; then
      rm -rf "$orphaned_backup"
    fi
  done
fi
for abandoned_staging in "$runtime_parent"/.Diarization-install-*(N); do
  rm -rf "$abandoned_staging"
done

if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" == "1" ]]; then
  exit 0
fi

# 21.6 MB of models, staged alongside an existing runtime of the same size during the swap. 128 MiB
# is the old sherpa-era 512 MiB reduced to match a payload that shrank by two thirds — refusing a
# user with 300 MB free would be a refusal for a reason that no longer exists.
available_kib="$(df -Pk "$runtime_parent" | awk 'NR == 2 { print $4 }')"
if [[ -z "$available_kib" || "$available_kib" -lt 131072 ]]; then
  print -u2 "Speaker analysis needs at least 128 MB of available storage to install safely."
  exit 1
fi

staged_models="$staging_directory/models/$model_directory_name"
mkdir -p "$staged_models"

verify_sha256() {
  file_path="$1"
  expected="$2"
  description="$3"
  actual="$(shasum -a 256 "$file_path" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Speaker-analysis $description verification failed; the existing runtime was not changed."
    exit 1
  fi
}

# No credentials, no .netrc, no token environment variable is read. The Hugging Face repository is
# ungated and every file below was fetched anonymously during the F216 evaluation.
download() {
  url="$1"
  destination="$2"
  if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$destination" "$url"; then
    print -u2 "Could not download the speaker-analysis files. Check your connection and try again."
    exit 1
  fi
}

# Fetch and hash in the same iteration. Two separate lists — one to download, one to verify — is how
# a file ends up installed without ever being checked; there is only one list here.
for entry in "${model_manifest[@]}"; do
  relative_path="${entry%% *}"
  expected_sha256="${entry##* }"
  destination="$staged_models/$relative_path"
  mkdir -p "${destination:h}"
  download "$model_base_url/$relative_path" "$destination"
  verify_sha256 "$destination" "$expected_sha256" "$relative_path"
done

if ! staged_models_match_manifest "$staged_models"; then
  print -u2 "The speaker-analysis download failed its completeness check; nothing was changed."
  exit 1
fi

cp "$notices_source" "$staging_directory/THIRD-PARTY-NOTICES.txt"
chmod 644 "$staging_directory/THIRD-PARTY-NOTICES.txt"

{
  print "model_repo=$model_repo"
  print "model_directory=$model_directory_name"
  print "runtime_id=$runtime_id"
  print "runtime_version=$runtime_version"
  print "cluster_threshold=$cluster_threshold"
  for entry in "${model_manifest[@]}"; do
    print "sha256 ${entry##* } models/$model_directory_name/${entry%% *}"
  done
} > "$staging_directory/MANIFEST"
chmod 644 "$staging_directory/MANIFEST"

# Smoke test the real pipeline, not a file count. A staged tree can hash perfectly and still be
# unusable: the Core ML bundles have to compile for THIS Mac's OS and Neural Engine, which nothing
# before this line has asked them to do. The app is called back headlessly, loads all four models
# through `OfflineDiarizerModels.load` — never `prepareModels()`, which deletes the staged models on
# any load failure — and runs the pipeline over one second of generated silence.
#
# Silence is deliberately the input: it needs no fixture whose licence we would have to establish
# (every .wav in the old model releases carried no licence statement at all), and a correct run over
# it ends in "no speech detected", which is a result and not an error. What it does not exercise is
# clustering, since there is nothing to cluster — the model *load* is what covers all four bundles.
smoke_output="$staging_directory/.smoke.out"
if ! "$smoke_test_command" --diarization-smoke-test "$staging_directory/models" \
      > "$smoke_output" 2>&1; then
  print -u2 "The speaker-analysis runtime failed its smoke test; nothing was changed."
  sed 's/^/  /' "$smoke_output" >&2
  exit 1
fi
rm -f "$smoke_output"

if ! runtime_is_complete "$staging_directory"; then
  print -u2 "The staged speaker-analysis runtime is incomplete; nothing was changed."
  exit 1
fi

if [[ -e "$target_directory" ]]; then
  mv "$target_directory" "$backup_directory"
fi
if ! mv "$staging_directory" "$target_directory"; then
  if [[ -e "$backup_directory" ]]; then
    mv "$backup_directory" "$target_directory"
  fi
  print -u2 "The new speaker-analysis runtime could not be activated; the previous runtime was restored."
  exit 1
fi
activation_complete=1
if [[ -e "$backup_directory" ]]; then
  if ! rm -rf "$backup_directory"; then
    print -u2 "Speaker analysis was activated, but its prior-runtime backup could not be removed."
  fi
fi
rm -f "$lock_file"
lock_acquired=0
trap - EXIT HUP INT TERM

print "Speaker analysis is ready at $target_directory"
