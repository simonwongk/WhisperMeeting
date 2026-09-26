#!/bin/zsh
# Phase-0 benchmark clip generator (SYNTHETIC, reproducible).
# Produces 16 kHz mono WAV clips in the real dictation format via macOS `say` + `afconvert`,
# with EXACT references (the TTS input text is ground truth). Relative engine comparison
# (PyTorch turbo vs MLX fp16 vs MLX q8) is valid on these; absolute WER/CER and especially
# code-switch quality are best validated later with real-mic clips dropped into this same dir.
set -euo pipefail

BENCH_DIR="${0:A:h}"
DIR="$BENCH_DIR/clips"
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

# F589: English-dominant sentences with embedded Mandarin WORDS, spoken by two voices and spliced —
# unlike cs1-3 (one Mandarin voice reading mixed-script text), each language run here is read by the
# voice that actually speaks it, which is what a real code-switching speaker sounds like. `segs` is
# alternating voice-tag/text pairs; "en" -> $EN_VOICE, "zh" -> $ZH_VOICE. Segments are converted
# individually (same `say`+`afconvert` as `gen`) and spliced with 150 ms of silence between them by
# `splice_codeswitch.py`, which also refuses to silently join mismatched formats.
gen_encs() { # id text-if-single-voiced (unused, kept for symmetry) -- segs follow as "tag:text" args
  local id=$1; shift
  local -a wavs
  local i=1
  local pair tag text voice
  for pair in "$@"; do
    tag="${pair%%:*}"
    text="${pair#*:}"
    if [[ "$tag" == "en" ]]; then voice="$EN_VOICE"; else voice="$ZH_VOICE"; fi
    say -v "$voice" -o "$DIR/${id}_seg${i}.aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$DIR/${id}_seg${i}.aiff" "$DIR/${id}_seg${i}.wav"
    rm -f "$DIR/${id}_seg${i}.aiff"
    wavs+=("$DIR/${id}_seg${i}.wav")
    i=$((i + 1))
  done
  python3 "$BENCH_DIR/splice_codeswitch.py" "$DIR/$id.wav" 150 "${wavs[@]}"
  rm -f "${wavs[@]}"
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

# F589: English-dominant, Mandarin-word-embedded (6) — the direction the bench never covered before
# (cs1-3 above are Mandarin-dominant). Each clip is the two voices above, spliced; see `gen_encs`.
gen_encs encs1 \
  "en:Please send the" "zh:会议纪要" "en:to the whole team before" "zh:周五."
gen_encs encs2 \
  "en:The" "zh:客户" "en:wants the" "zh:报价" "en:by Tuesday."
gen_encs encs3 \
  "en:Let's book a" "zh:会议室" "en:for the" "zh:培训" "en:next week."
gen_encs encs4 \
  "en:I'll ping" "zh:王老师" "en:about the" "zh:作业" "en:tonight."
gen_encs encs5 \
  "en:Our" "zh:预算" "en:for Q4 is still under review."
gen_encs encs6 \
  "en:Can you" "zh:翻译" "en:this paragraph into English?"

# References (exact ground truth). lang: en | zh | cs | encs
# encs entries additionally carry "words": the embedded Mandarin words a code-switch dictation must
# not lose, in the order they appear — what `dictation-ab.py --words` diffs against the hypothesis.
cat > "$DIR/references.json" <<'JSON'
{
  "en1": {"lang": "en", "text": "Can you send me the quarterly report by Friday afternoon?"},
  "en2": {"lang": "en", "text": "Let's schedule the design review for next Tuesday at ten."},
  "en3": {"lang": "en", "text": "The build is failing on the release step, please take a look."},
  "en4": {"lang": "en", "text": "Remind me to follow up with the vendor about the invoice."},
  "zh1": {"lang": "zh", "text": "帮我把今天的会议纪要发给团队。"},
  "zh2": {"lang": "zh", "text": "这个季度的销售数据看起来很不错。"},
  "zh3": {"lang": "zh", "text": "请提醒我下午三点跟客户开会。"},
  "cs1": {"lang": "cs", "text": "我们的 deadline 是这个星期五。", "words": ["deadline"]},
  "cs2": {"lang": "cs", "text": "帮我 schedule 一个 meeting 明天下午。", "words": ["schedule", "meeting"]},
  "cs3": {"lang": "cs", "text": "这个 bug 已经 fix 了，可以 merge 了。", "words": ["bug", "fix", "merge"]},
  "encs1": {"lang": "encs", "text": "Please send the 会议纪要 to the whole team before 周五.",
            "words": ["会议纪要", "周五"]},
  "encs2": {"lang": "encs", "text": "The 客户 wants the 报价 by Tuesday.",
            "words": ["客户", "报价"]},
  "encs3": {"lang": "encs", "text": "Let's book a 会议室 for the 培训 next week.",
            "words": ["会议室", "培训"]},
  "encs4": {"lang": "encs", "text": "I'll ping 王老师 about the 作业 tonight.",
            "words": ["王老师", "作业"]},
  "encs5": {"lang": "encs", "text": "Our 预算 for Q4 is still under review.",
            "words": ["预算"]},
  "encs6": {"lang": "encs", "text": "Can you 翻译 this paragraph into English?",
            "words": ["翻译"]}
}
JSON

print "Generated $(ls "$DIR"/*.wav | wc -l | tr -d ' ') clips + references.json in $DIR"
