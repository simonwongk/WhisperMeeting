#!/usr/bin/env python3
"""A private, Terminal-only chat with WhisperMeet's installed Qwen3 model.

This deliberately has no persistence layer: chat turns live only in memory until
the process exits.  The launcher forces the model stack offline before mlx_lm is
imported, so this command can use only the snapshot that WhisperMeet installed.
"""

import argparse
import os
import sys


DEFAULT_RUNTIME = os.path.expanduser(
    "~/Library/Application Support/WhisperMeet/Runtime/Summarizer"
)


def offline_environment(environ: dict[str, str]) -> dict[str, str]:
    """Return an environment that prevents model libraries from contacting Hugging Face."""
    result = dict(environ)
    result["HF_HUB_OFFLINE"] = "1"
    result["TRANSFORMERS_OFFLINE"] = "1"
    return result


def missing_runtime_parts(runtime: str) -> list[str]:
    """Name the managed-runtime parts required to start chat, without creating anything."""
    python = os.path.join(runtime, "venv", "bin", "python")
    model = os.path.join(runtime, "model")
    missing = []
    if not os.path.isfile(python) or not os.access(python, os.X_OK):
        missing.append("venv/bin/python")
    if not os.path.isdir(model):
        missing.append("model")
    return missing


def append_exchange(
    history: list[dict[str, str]],
    user_text: str,
    assistant_text: str,
    *,
    max_turns: int,
) -> list[dict[str, str]]:
    """Add an exchange while retaining a bounded, role-correct in-memory context."""
    exchange = [
        {"role": "user", "content": user_text},
        {"role": "assistant", "content": assistant_text},
    ]
    return (history + exchange)[-max_turns * 2 :]


def apply_chat_template(tokenizer, history: list[dict[str, str]]):
    """Build a Qwen chat prompt without asking the model to emit a reasoning trace."""
    try:
        return tokenizer.apply_chat_template(
            history, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        # Keep the launcher usable with older locally installed tokenizer builds.
        return tokenizer.apply_chat_template(history, add_generation_prompt=True)


def generate_reply(model, tokenizer, history, *, max_tokens: int) -> str:
    """Generate and display one reply.  Nothing is written beyond the terminal."""
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    prompt = apply_chat_template(tokenizer, history)
    pieces = []
    for response in stream_generate(
        model,
        tokenizer,
        prompt,
        max_tokens=max_tokens,
        sampler=make_sampler(temp=0.6),
    ):
        text = response.text
        pieces.append(text)
        print(text, end="", flush=True)
    print()
    return "".join(pieces).strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Chat privately with WhisperMeet's installed local Qwen model."
    )
    parser.add_argument(
        "--runtime",
        default=DEFAULT_RUNTIME,
        help="WhisperMeet Summarizer runtime (default: %(default)s)",
    )
    parser.add_argument(
        "--max-turns",
        type=int,
        default=6,
        help="conversation turns kept in memory (default: %(default)s)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=512,
        help="maximum tokens per answer (default: %(default)s)",
    )
    arguments = parser.parse_args()
    if arguments.max_turns < 1:
        parser.error("--max-turns must be at least 1")
    if arguments.max_tokens < 1:
        parser.error("--max-tokens must be at least 1")
    return arguments


def main() -> int:
    arguments = parse_args()
    runtime = os.path.abspath(os.path.expanduser(arguments.runtime))
    missing = missing_runtime_parts(runtime)
    if missing:
        print(
            "Local Qwen is not installed completely. Missing: " + ", ".join(missing)
            + ". Open WhisperMeet → Settings → Install Local Model.",
            file=sys.stderr,
        )
        return 2

    # This must precede mlx_lm imports, whose dependency stack can otherwise check remote hubs.
    os.environ.update(offline_environment(os.environ))
    from mlx_lm import load

    model, tokenizer = load(os.path.join(runtime, "model"))
    print("Local Qwen chat — offline; conversations are not saved. Type /exit to leave.")
    history = []
    while True:
        try:
            user_text = input("\nYou> ").strip()
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            print("\nUse /exit to leave.")
            continue
        if user_text.lower() in {"/exit", "/quit"}:
            return 0
        if not user_text:
            continue

        print("Qwen> ", end="", flush=True)
        try:
            reply = generate_reply(
                model, tokenizer, history + [{"role": "user", "content": user_text}],
                max_tokens=arguments.max_tokens,
            )
        except KeyboardInterrupt:
            print("\nGeneration stopped.")
            continue
        except Exception as error:  # noqa: BLE001 - preserve an interactive session after one failed turn.
            print(f"\nLocal Qwen could not answer: {type(error).__name__}: {error}", file=sys.stderr)
            continue
        history = append_exchange(
            history, user_text, reply, max_turns=arguments.max_turns
        )


if __name__ == "__main__":
    raise SystemExit(main())
