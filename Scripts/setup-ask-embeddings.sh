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

# `config.json` was fetched but never checked (F333), and it is not inert: `embed_local.py` reads
# `num_hidden_layers`, `num_attention_heads`, `hidden_size` and `layer_norm_eps` out of it to build
# the forward pass, so a wrong one produces vectors that are silently garbage — a failure with no
# symptom, because a cosine between two garbage vectors still sorts.
#
# Its architecture is checked rather than its bytes: a SHA would also fail on a whitespace change
# that cannot affect anything, and these are exactly the fields the reader depends on. The two
# equalities are the two numbers this repo already states (`embed_local.py`: "a 12-layer BERT
# encoder, 384 dimensions"); the other two are checked for presence and structural sanity rather
# than against a value nobody here has measured.
EMBEDDING_STAGE="$staging" "$summarizer_directory/venv/bin/python" - <<'CONFIGCHECK' || exit 1
import json, os, sys

with open(os.path.join(os.environ["EMBEDDING_STAGE"], "config.json"), encoding="utf-8") as handle:
    config = json.load(handle)

problems = []
if config.get("num_hidden_layers") != 12:
    problems.append("num_hidden_layers is %r, expected 12" % config.get("num_hidden_layers"))
if config.get("hidden_size") != 384:
    problems.append("hidden_size is %r, expected 384" % config.get("hidden_size"))
heads = config.get("num_attention_heads")
if not isinstance(heads, int) or heads <= 0 or 384 % heads:
    problems.append("num_attention_heads is %r, which does not divide hidden_size" % heads)
eps = config.get("layer_norm_eps", 1e-12)   # embed_local.py defaults it, so absence is fine
if not isinstance(eps, (int, float)) or not 0 < eps < 1e-3:
    problems.append("layer_norm_eps is %r, which is not a layer-norm epsilon" % eps)
if problems:
    print("config.json does not describe multilingual-e5-small:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    sys.exit(1)
CONFIGCHECK
rm -rf "$staging/.cache"

# Swap in whole: a reader never sees a half-installed model.
#
# And the previous model comes back if the swap fails (F333). `mv "$target" "$previous"` followed by
# a failing `mv "$staging" "$target"` used to leave NO model installed, with the EXIT trap removing
# only the staging directory — an upgrade that fails halfway took away what was already working.
previous="$summarizer_directory/.embedding-model-previous-$$"
restore_previous() {
  if [[ -d "$previous" && ! -d "$target" ]]; then mv "$previous" "$target"; fi
  rm -rf "$previous"
}
trap 'rm -rf "$staging"; restore_previous' EXIT
if [[ -d "$target" ]]; then mv "$target" "$previous"; fi
if ! mv "$staging" "$target"; then
  print -u2 "The search model could not be installed; the previous one is being put back."
  exit 1
fi
rm -rf "$previous"
print "Search model installed: $repository @ ${revision[1,12]}"
