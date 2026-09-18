#!/bin/zsh
# Installs the search-by-meaning model for Ask Meetings (F316): intfloat/multilingual-e5-small
# (MIT, ~490 MB), pinned to a revision and verified by SHA-256, into the existing local-model
# runtime. It adds no Python packages: embed_local.py runs it with the `mlx` and `tokenizers` the
# summarizer runtime already has, and only three files are fetched.
#
#   setup-ask-embeddings.sh [runtime directory]     default: ~/Library/Application Support/WhisperMeet/Runtime
set -euo pipefail

runtime_directory="${1:-${HOME}/Library/Application Support/WhisperMeet/Runtime}"
summarizer_directory="$runtime_directory/Summarizer"
target="$summarizer_directory/embedding-model"
repository="intfloat/multilingual-e5-small"
revision="614241f622f53c4eeff9890bdc4f31cfecc418b3"
model_sha256="1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477"
tokenizer_sha256="0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"

if [[ ! -x "$summarizer_directory/venv/bin/python" ]]; then
  print -u2 "Install the local summary model first: search by meaning runs in the same runtime."
  exit 1
fi

staging="$summarizer_directory/.embedding-model-staging-$$"
rm -rf "$staging"
trap 'rm -rf "$staging"' EXIT

EMBEDDING_STAGE="$staging" EMBEDDING_REPOSITORY="$repository" EMBEDDING_REVISION="$revision" \
"$summarizer_directory/venv/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ["EMBEDDING_REPOSITORY"],
    revision=os.environ["EMBEDDING_REVISION"],
    local_dir=os.environ["EMBEDDING_STAGE"],
    allow_patterns=["config.json", "tokenizer.json", "model.safetensors"],
)
PY

actual_model="$(shasum -a 256 "$staging/model.safetensors" | awk '{ print $1 }')"
actual_tokenizer="$(shasum -a 256 "$staging/tokenizer.json" | awk '{ print $1 }')"
if [[ "$actual_model" != "$model_sha256" || "$actual_tokenizer" != "$tokenizer_sha256" ]]; then
  print -u2 "The search model failed verification; nothing was installed."
  exit 1
fi
rm -rf "$staging/.cache"

# Swap in whole: a reader never sees a half-installed model.
previous="$summarizer_directory/.embedding-model-previous-$$"
if [[ -d "$target" ]]; then mv "$target" "$previous"; fi
mv "$staging" "$target"
rm -rf "$previous"
print "Search model installed: $repository @ ${revision[1,12]}"
