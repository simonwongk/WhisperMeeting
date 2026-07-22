# Scripts/whisper_dictate_server.py
"""Resident Whisper helper for WhisperMeet quick dictation.

Loads the model once, then serves newline-delimited JSON requests on stdin and
writes newline-delimited JSON responses on stdout. Local-only; no network.
Exits cleanly when stdin closes (the app terminates it to evict the model).
"""
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="turbo")
    parser.add_argument("--model-dir", required=True)
    args = parser.parse_args()

    import whisper  # imported after arg parse so --help is instant
    model = whisper.load_model(args.model, download_root=args.model_dir)

    # Signal readiness only after the model is resident.
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result = model.transcribe(
                request["wavPath"],
                task="transcribe",
                language=request.get("language"),
                initial_prompt=request.get("initialPrompt"),
                fp16=False,
            )
            response = {"text": result.get("text", ""), "language": result.get("language")}
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
