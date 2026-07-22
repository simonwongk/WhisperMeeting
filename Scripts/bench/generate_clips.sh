#!/bin/zsh
# Phase-0 benchmark clip generator (SYNTHETIC, reproducible).
# Produces 16 kHz mono WAV clips in the real dictation format via macOS `say` + `afconvert`,
# with EXACT references (the TTS input text is ground truth). Relative engine comparison
# (PyTorch turbo vs MLX fp16 vs MLX q8) is valid on these; absolute WER/CER and especially
# code-switch quality are best validated later with real-mic clips dropped into this same dir.
set -euo pipefail

DIR="${0:A:h}/clips"
mkdir -p "$DIR"

# Pick an available English and Mandarin voice (fall back across common names).
pick_voice() {
  for v in "$@"; do
    if say -v "$v" -o "$DIR/.voicetest.aiff" "test" >/dev/null 2>&1; then
      rm -f "$DIR/.voicetest.aiff"; print -r -- "$v"; return 0
    fi
  done
  return 1
}
EN_VOICE="$(pick_voice Samantha Alex Daniel Fred || true)"
ZH_VOICE="$(pick_voice Tingting Meijia Sinji || true)"
if [[ -z "$EN_VOICE" || -z "$ZH_VOICE" ]]; then
  print -u2 "Could not find an English ($EN_VOICE) and/or Mandarin ($ZH_VOICE) voice. Run: say -v '?'"
  exit 1
fi
print "Using EN voice: $EN_VOICE   ZH/code-switch voice: $ZH_VOICE"

gen() { # id voice text
  local id=$1 voice=$2 text=$3
  say -v "$voice" -o "$DIR/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$DIR/$id.aiff" "$DIR/$id.wav"
  rm -f "$DIR/$id.aiff"
}

# English (4)
gen en1 "$EN_VOICE" "Can you send me the quarterly report by Friday afternoon?"
gen en2 "$EN_VOICE" "Let's schedule the design review for next Tuesday at ten."
gen en3 "$EN_VOICE" "The build is failing on the release step, please take a look."
gen en4 "$EN_VOICE" "Remind me to follow up with the vendor about the invoice."
# Mandarin (3)
gen zh1 "$ZH_VOICE" "帮我把今天的会议纪要发给团队。"
gen zh2 "$ZH_VOICE" "这个季度的销售数据看起来很不错。"
gen zh3 "$ZH_VOICE" "请提醒我下午三点跟客户开会。"
# Code-switch EN<->中文 (3) — the weak spot for TTS; validate with real recordings.
gen cs1 "$ZH_VOICE" "我们的 deadline 是这个星期五。"
gen cs2 "$ZH_VOICE" "帮我 schedule 一个 meeting 明天下午。"
gen cs3 "$ZH_VOICE" "这个 bug 已经 fix 了，可以 merge 了。"

# References (exact ground truth). lang: en | zh | cs
cat > "$DIR/references.json" <<'JSON'
{
  "en1": {"lang": "en", "text": "Can you send me the quarterly report by Friday afternoon?"},
  "en2": {"lang": "en", "text": "Let's schedule the design review for next Tuesday at ten."},
  "en3": {"lang": "en", "text": "The build is failing on the release step, please take a look."},
  "en4": {"lang": "en", "text": "Remind me to follow up with the vendor about the invoice."},
  "zh1": {"lang": "zh", "text": "帮我把今天的会议纪要发给团队。"},
  "zh2": {"lang": "zh", "text": "这个季度的销售数据看起来很不错。"},
  "zh3": {"lang": "zh", "text": "请提醒我下午三点跟客户开会。"},
  "cs1": {"lang": "cs", "text": "我们的 deadline 是这个星期五。"},
  "cs2": {"lang": "cs", "text": "帮我 schedule 一个 meeting 明天下午。"},
  "cs3": {"lang": "cs", "text": "这个 bug 已经 fix 了，可以 merge 了。"}
}
JSON

print "Generated $(ls "$DIR"/*.wav | wc -l | tr -d ' ') clips + references.json in $DIR"
