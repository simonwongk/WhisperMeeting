#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

destination="${1:-/Applications/WhisperMeet.app}"
destination_parent="${destination:h}"
staging_root=""
backup=""
cleanup_staging=true
install_verified=false

cleanup() {
  local exit_status=$?
  trap - EXIT
  if [[ "$install_verified" != true && -n "$backup" && -e "$backup" ]]; then
    if [[ -e "$destination" ]] && ! rm -rf "$destination"; then
      cleanup_staging=false
      print -u2 "Update cleanup could not remove the unverified replacement. The previous app is preserved at $backup."
    elif ! mv "$backup" "$destination"; then
      cleanup_staging=false
      print -u2 "Update cleanup could not restore the previous app. It is preserved at $backup."
    fi
  fi
  if [[ "$cleanup_staging" == true && -n "$staging_root" && -d "$staging_root" ]]; then
    rm -rf "$staging_root"
  fi
  return $exit_status
}
trap cleanup EXIT

if pgrep -x WhisperMeet >/dev/null 2>&1; then
  print -u2 "WhisperMeet is running. Stop or cancel any recording, quit the app, then run this installer again."
  exit 2
fi

Scripts/build-app.sh >/dev/null
app_path="$PWD/.build/WhisperMeet.app"

# Recheck immediately before touching the installed bundle. The app may have launched while the
# release build was running, and replacing it during capture would violate the recording-first rule.
if pgrep -x WhisperMeet >/dev/null 2>&1; then
  print -u2 "WhisperMeet started while the update was being prepared. Quit it and try again."
  exit 2
fi

staging_root="$(mktemp -d "${destination_parent}/.WhisperMeet.update.XXXXXX")"
staged_app="$staging_root/WhisperMeet.app"
backup="$staging_root/WhisperMeet.previous.app"
ditto "$app_path" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if pgrep -x WhisperMeet >/dev/null 2>&1; then
  print -u2 "WhisperMeet started before installation. Quit it and try again."
  exit 2
fi

if [[ -e "$destination" ]]; then
  mv "$destination" "$backup"
fi
if ! mv "$staged_app" "$destination"; then
  if [[ -e "$backup" ]]; then
    if ! mv "$backup" "$destination"; then
      cleanup_staging=false
      print -u2 "Installation and automatic rollback both failed. The previous app is preserved at $backup."
      exit 1
    fi
  fi
  print -u2 "Installation failed; the previous WhisperMeet app was restored."
  exit 1
fi
if ! codesign --verify --deep --strict "$destination"; then
  if ! rm -rf "$destination"; then
    cleanup_staging=false
    print -u2 "The replacement failed verification and could not be removed. The previous app is preserved at $backup."
    exit 1
  fi
  if [[ -e "$backup" ]]; then
    if ! mv "$backup" "$destination"; then
      cleanup_staging=false
      print -u2 "The replacement failed verification and automatic rollback failed. The previous app is preserved at $backup."
      exit 1
    fi
  fi
  print -u2 "The installed app failed signature verification; the previous app was restored."
  exit 1
fi
install_verified=true

print "Installed WhisperMeet at $destination"
print "If capture permission appears stale, toggle WhisperMeet off and on in Screen & System Audio Recording, then reopen it."
