#!/bin/zsh
set -euo pipefail

# Installs the optional local speaker-analysis runtime (F216/F219). Same skeleton as
# setup-qwen-asr.sh — cross-process lock, orphan reclaim, staged install, verify-before-swap, atomic
# activation with rollback — but there is no Python here: the runtime is two prebuilt binaries and
# two model files, so there is no Homebrew dependency, no venv, and no pip.
#
# Everything downloaded is pinned by SHA-256 and verified twice: once on the archive, once on each
# extracted payload file. An archive that hashes correctly but unpacks wrong never activates.

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
runtime_parent="${target_directory:h}"
staging_directory="$runtime_parent/.Diarization-install-$$"
backup_directory="$runtime_parent/.Diarization-backup-$$"
lock_file="$runtime_parent/.Diarization-install.lock"
activation_complete=0
lock_acquired=0

sherpa_version="1.13.8"
sherpa_asset="sherpa-onnx-v${sherpa_version}-osx-arm64-shared-no-tts.tar.bz2"
sherpa_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${sherpa_version}/${sherpa_asset}"
sherpa_sha256="91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a"
diarizer_sha256="e1170a93308867d8e343ac22a00b46b1d8e786c763c32a17caff07cf934ff66f"
onnxruntime_sha256="3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b"

segmentation_asset="sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
segmentation_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/${segmentation_asset}"
segmentation_asset_sha256="24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
segmentation_model_sha256="220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"
segmentation_license_sha256="14d7016ad68e7394d6e6b78d96cc2ae431c905287b89674cfdf021e79e62b8ba"

# "recongition" is upstream's own typo in the release tag. Correcting it yields a 404. Do not "fix".
embedding_asset="3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
embedding_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/${embedding_asset}"
embedding_sha256="aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"

# Not tuning knobs. 0.40 was derived by sweeping seven thresholds over the 18-fixture F217 corpus:
# 0.3-0.6 form a flat plateau, 0.7 falls off a cliff, and 0.40 has the best displayed-label
# precision in the plateau. The axis is asymmetric — too low over-splits, which the overlay rule
# safely abstains on; too high merges two speakers into one cluster, which it cannot detect. Both
# values are recorded in the MANIFEST and in every result's sidecar, so a result produced under a
# different pin stays identifiable.
cluster_threshold="0.40"
num_threads="4"

if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" != "1"
      && ( "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ) ]]; then
  print -u2 "Speaker analysis currently requires an Apple-silicon Mac."
  exit 1
fi
# Recovery-only mode reclaims an interrupted install and copies nothing, so it must not require the
# bundled notices — otherwise a build missing that file would make the launch reclaim exit before it
# runs, stranding the orphaned runtime (the failure mode F33 closed for Qwen).
if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" != "1" ]]; then
  if [[ ! -f "$notices_source" ]]; then
    print -u2 "The bundled third-party notices are missing; the runtime is not shippable without them."
    exit 1
  fi
fi

mkdir -p "$runtime_parent"

runtime_is_complete() {
  candidate="$1"
  [[ -x "$candidate/bin/sherpa-onnx-offline-speaker-diarization"
    && -f "$candidate/lib/libonnxruntime.dylib"
    && -f "$candidate/models/segmentation/model.onnx"
    && -f "$candidate/models/segmentation/LICENSE"
    && -f "$candidate/models/embedding/campplus_zh_en.onnx"
    && -f "$candidate/THIRD-PARTY-NOTICES.txt"
    && -f "$candidate/MANIFEST" ]]
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

available_kib="$(df -Pk "$runtime_parent" | awk 'NR == 2 { print $4 }')"
if [[ -z "$available_kib" || "$available_kib" -lt 524288 ]]; then
  print -u2 "Speaker analysis needs at least 512 MB of available storage to install safely."
  exit 1
fi

mkdir -p "$staging_directory/download"

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

# No credentials, no .netrc, no token environment variable is read. These are public release assets.
download() {
  url="$1"
  destination="$2"
  if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$destination" "$url"; then
    print -u2 "Could not download the speaker-analysis files. Check your connection and try again."
    exit 1
  fi
}

download "$sherpa_url" "$staging_directory/download/$sherpa_asset"
verify_sha256 "$staging_directory/download/$sherpa_asset" "$sherpa_sha256" "runtime archive"
download "$segmentation_url" "$staging_directory/download/$segmentation_asset"
verify_sha256 "$staging_directory/download/$segmentation_asset" "$segmentation_asset_sha256" "segmentation archive"
download "$embedding_url" "$staging_directory/download/$embedding_asset"
verify_sha256 "$staging_directory/download/$embedding_asset" "$embedding_sha256" "embedding model"

tar -xjf "$staging_directory/download/$sherpa_asset" -C "$staging_directory/download"
tar -xjf "$staging_directory/download/$segmentation_asset" -C "$staging_directory/download"

sherpa_extracted="$staging_directory/download/sherpa-onnx-v${sherpa_version}-osx-arm64-shared-no-tts"
segmentation_extracted="$staging_directory/download/sherpa-onnx-pyannote-segmentation-3-0"

mkdir -p "$staging_directory/bin" "$staging_directory/lib"
mkdir -p "$staging_directory/models/segmentation" "$staging_directory/models/embedding"

# Keep exactly two files from a 29-binary tarball. This is a licence and attack-surface requirement,
# not tidiness: the discarded set includes the websocket servers, which do carry socket symbols.
cp "$sherpa_extracted/bin/sherpa-onnx-offline-speaker-diarization" "$staging_directory/bin/"
cp "$sherpa_extracted/lib/libonnxruntime.dylib" "$staging_directory/lib/"
chmod 755 "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization"

# model.int8.onnx is deliberately not copied: it measured far worse than fp32 and no single
# clustering threshold works across clips for it, so its 4.5 MB saving costs correctness.
cp "$segmentation_extracted/model.onnx" "$staging_directory/models/segmentation/"
cp "$segmentation_extracted/LICENSE" "$staging_directory/models/segmentation/"
if [[ -f "$segmentation_extracted/README.md" ]]; then
  cp "$segmentation_extracted/README.md" "$staging_directory/models/segmentation/"
fi
cp "$staging_directory/download/$embedding_asset" "$staging_directory/models/embedding/campplus_zh_en.onnx"

rm -rf "$staging_directory/download"

# Verify the payload itself, not just the archives it arrived in.
verify_sha256 "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" "$diarizer_sha256" "runtime binary"
verify_sha256 "$staging_directory/lib/libonnxruntime.dylib" "$onnxruntime_sha256" "inference library"
verify_sha256 "$staging_directory/models/segmentation/model.onnx" "$segmentation_model_sha256" "segmentation model"
verify_sha256 "$staging_directory/models/segmentation/LICENSE" "$segmentation_license_sha256" "segmentation licence"
verify_sha256 "$staging_directory/models/embedding/campplus_zh_en.onnx" "$embedding_sha256" "embedding model"

# Licence gate. The default sherpa-onnx distributions statically link espeak-ng (GPL-3.0-or-later);
# the -no-tts build does not. Match the symbol form, not the word: a case-insensitive search for the
# bare word matches this build's own `OfflineSpeakerDiarization` symbols ("…lin|eSpeak|er…") and
# would refuse every clean install.
if nm -a "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" 2>/dev/null \
     | grep -qE '_espeak[A-Za-z_0-9]*'; then
  print -u2 "The speaker-analysis runtime failed its licence check; nothing was changed."
  exit 1
fi

# Offline gate. Analysis must have no path to the network at all, so the binary we activate must
# export no socket symbols and link no networking framework.
if nm -u "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" 2>/dev/null \
     | grep -qE '_socket$|_bind$|_listen$|_connect$'; then
  print -u2 "The speaker-analysis runtime failed its offline check; nothing was changed."
  exit 1
fi
if otool -L "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" 2>/dev/null \
     | grep -qE 'libcurl|CFNetwork|Network\.framework|libssl|libcrypto'; then
  print -u2 "The speaker-analysis runtime failed its offline check; nothing was changed."
  exit 1
fi

cp "$notices_source" "$staging_directory/THIRD-PARTY-NOTICES.txt"
chmod 644 "$staging_directory/THIRD-PARTY-NOTICES.txt"

{
  print "sherpa_onnx_version=$sherpa_version"
  print "runtime_asset=$sherpa_asset"
  print "runtime_asset_sha256=$sherpa_sha256"
  print "diarization_binary_sha256=$diarizer_sha256"
  print "onnxruntime_dylib_sha256=$onnxruntime_sha256"
  print "segmentation_asset_sha256=$segmentation_asset_sha256"
  print "segmentation_model_sha256=$segmentation_model_sha256"
  print "embedding_model_sha256=$embedding_sha256"
  print "cluster_threshold=$cluster_threshold"
  print "num_threads=$num_threads"
} > "$staging_directory/MANIFEST"
chmod 644 "$staging_directory/MANIFEST"

# Smoke test the real pipeline, not --help. A one-second silent 16 kHz mono WAV is built here rather
# than taken from the upstream release, whose bundled .wav files carry no licence statement at all.
# Correct behaviour on silence is exit 0 with no segment lines.
smoke_wav="$staging_directory/.smoke.wav"
printf 'RIFF\x24\x7d\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x00\x7d\x00\x00' > "$smoke_wav"
dd if=/dev/zero bs=32000 count=1 >> "$smoke_wav" 2>/dev/null

smoke_output="$staging_directory/.smoke.out"
if ! "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization" \
      --print-args=false \
      --clustering.cluster-threshold="$cluster_threshold" \
      --segmentation.num-threads="$num_threads" \
      --embedding.num-threads="$num_threads" \
      --segmentation.pyannote-model="$staging_directory/models/segmentation/model.onnx" \
      --embedding.model="$staging_directory/models/embedding/campplus_zh_en.onnx" \
      "$smoke_wav" > "$smoke_output" 2>/dev/null; then
  print -u2 "The speaker-analysis runtime did not run on this Mac; nothing was changed."
  exit 1
fi
if grep -qE '^[0-9]+\.[0-9]+ *-- *[0-9]+\.[0-9]+ +speaker_' "$smoke_output"; then
  print -u2 "The speaker-analysis runtime reported speech in silence; nothing was changed."
  exit 1
fi
rm -f "$smoke_wav" "$smoke_output"

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
