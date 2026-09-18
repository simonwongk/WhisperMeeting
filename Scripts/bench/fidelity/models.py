#!/usr/bin/env python3
"""Fetch and verify the F244 candidate models into the bench cache (never the checkout).

    python3 Scripts/bench/fidelity/models.py venv                 # create the bench venv (mlx-lm, huggingface_hub)
    python3 Scripts/bench/fidelity/models.py download gemma-4-e4b # pinned revision, SHA-256 recorded/checked
    python3 Scripts/bench/fidelity/models.py path gemma-4-e4b     # print the local model directory

Every model is pinned to a revision in `models.json`; the first verified download writes the weights'
SHA-256 back into that file, and every later download must match it. The design (2026-09-14) says
each download needs the user's go-ahead with its name, source and size; on 2026-09-17 the user
delegated that decision, and this script prints all three before it fetches anything.

The bench venv is separate from the app's Summarizer runtime on purpose: Gemma 4 needs mlx-lm
0.31.2 or newer, and the app's runtime is pinned to what the app ships. Nothing here touches
`~/Library/Application Support/WhisperMeet`.
"""
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "models.json")


def load():
    with open(MANIFEST, encoding="utf-8") as handle:
        return json.load(handle)


def save(manifest):
    with open(MANIFEST, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def cache_dir(manifest):
    return os.path.expanduser(manifest["cache"])


def venv_python(manifest):
    return os.path.join(cache_dir(manifest), "venv", "bin", "python3")


def ensure_venv(manifest):
    python = venv_python(manifest)
    if os.path.exists(python):
        return python
    root = os.path.join(cache_dir(manifest), "venv")
    os.makedirs(cache_dir(manifest), exist_ok=True)
    print(f"creating bench venv at {root}")
    # The same Homebrew interpreter the app's Summarizer runtime uses (setup-local-summarizer.sh):
    # the system python3 is 3.9 and mlx-lm 0.31 needs newer.
    interpreter = "/opt/homebrew/bin/python3.11"
    if not os.path.exists(interpreter):
        raise SystemExit(f"{interpreter} is missing; install python@3.11 with Homebrew, as the app's runtime does")
    subprocess.run([interpreter, "-m", "venv", root], check=True)
    subprocess.run([python, "-m", "pip", "install", "--quiet", "--upgrade", "pip"], check=True)
    subprocess.run([python, "-m", "pip", "install", "--quiet", "mlx-lm>=0.31.2", "huggingface_hub"], check=True)
    return python


def model_dir(manifest, name):
    return os.path.join(cache_dir(manifest), "models", name)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(manifest, name):
    entry = manifest["models"][name]
    target = model_dir(manifest, name)
    print(f"{name}: {entry['repo']} @ {entry['revision'][:12]} (~{entry['approx_gb']} GB, {entry['license']})")
    print(f"  -> {target}")
    python = ensure_venv(manifest)
    code = (
        "import sys; from huggingface_hub import snapshot_download; "
        "print(snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3]))"
    )
    subprocess.run([python, "-c", code, entry["repo"], entry["revision"], target], check=True)
    weights = os.path.join(target, "model.safetensors")
    if not os.path.exists(weights):
        raise SystemExit(f"{name}: no model.safetensors in {target}")
    digest = sha256_of(weights)
    if entry.get("weights_sha256") is None:
        entry["weights_sha256"] = digest
        save(manifest)
        print(f"  recorded weights sha256 {digest[:16]}… in models.json")
    elif entry["weights_sha256"] != digest:
        raise SystemExit(
            f"{name}: weights sha256 {digest[:16]}… does not match the pinned "
            f"{entry['weights_sha256'][:16]}…; refusing to benchmark different weights"
        )
    else:
        print(f"  weights sha256 verified {digest[:16]}…")
    return target


def main(argv):
    manifest = load()
    if len(argv) < 1 or argv[0] not in ("venv", "download", "path"):
        raise SystemExit(__doc__)
    if argv[0] == "venv":
        print(ensure_venv(manifest))
        return
    name = argv[1]
    if name not in manifest["models"]:
        raise SystemExit(f"unknown model {name!r}; known: {sorted(manifest['models'])}")
    if argv[0] == "path":
        print(model_dir(manifest, name))
        return
    download(manifest, name)


if __name__ == "__main__":
    main(sys.argv[1:])
