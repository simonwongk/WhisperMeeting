# CLAUDE.md

WhisperMeet is a native macOS app (SwiftPM, no Xcode project) that records a meeting's microphone +
Mac system audio and produces an accurate **post-meeting** transcript by running an explicitly
selected local subprocess. OpenAI Whisper Large remains the default; Apple-silicon Macs can opt into
Qwen3-ASR 1.7B MLX 8-bit plus its forced aligner.

All rules for agents working in this repository live in `AGENTS.md`. Read it before doing anything.
This file is intentionally a pointer — do not add rules here.
