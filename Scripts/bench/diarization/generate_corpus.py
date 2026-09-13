#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
F217 - manifest-driven synthetic multi-speaker audio corpus generator.

Builds a stratified speaker-diarization benchmark corpus for WhisperMeet.

Design rule that everything else serves: GROUND TRUTH IS ARITHMETIC.
Every utterance is synthesized on its own with macOS `say`, converted to
16 kHz/mono/16-bit via afconvert, energy-trimmed, and then placed at a
sample position that this program chooses. Reference turn boundaries are
therefore computed, never estimated from the mixed signal.

Standard library only (Python 3.9 compatible). No numpy/scipy. No audioop.

External tools (all part of macOS):
  say                 text-to-speech
  /usr/bin/afconvert  format conversion (16 kHz mono LEI16 WAV)
  /usr/bin/afinfo     duration probe / format assertion
"""

import argparse
import hashlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from array import array

RATE = 16000
FRAME = 160                  # 10 ms analysis frame at 16 kHz
SAY = "say"
AFCONVERT = "/usr/bin/afconvert"
AFINFO = "/usr/bin/afinfo"

# Any utterance that trims to less than this is treated as a synthesis
# failure and aborts the run. This is the guard against the silent killer:
# an English-only voice handed Chinese text emits ~0.01 s of nothing, which
# would otherwise sail through and corrupt every downstream turn boundary.
MIN_UTTERANCE_SEC = 0.25


class GenError(Exception):
    pass


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------

def run(cmd):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise GenError(
            "command failed (%d): %s\nstderr: %s"
            % (proc.returncode, " ".join(cmd), proc.stderr.decode("utf-8", "replace"))
        )
    return proc.stdout.decode("utf-8", "replace")


def afinfo_text(path):
    return run([AFINFO, path])


def afinfo_duration(path):
    out = afinfo_text(path)
    m = re.search(r"estimated duration:\s*([0-9.]+)\s*sec", out)
    if not m:
        raise GenError("afinfo gave no duration for %s" % path)
    return float(m.group(1))


def assert_wav_format(path):
    """Hard assertion that a produced file really is 16 kHz mono 16-bit."""
    with wave.open(path, "rb") as w:
        ch, sw, fr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        nframes = w.getnframes()
    if (ch, sw, fr) != (1, 2, RATE):
        raise GenError(
            "%s is not 16 kHz mono 16-bit (got %d ch, %d-byte, %d Hz)"
            % (path, ch, sw, fr)
        )
    return nframes


# --------------------------------------------------------------------------
# wav i/o
# --------------------------------------------------------------------------

def read_wav_i16(path):
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2 or w.getframerate() != RATE:
            raise GenError("unexpected wav format in %s" % path)
        raw = w.readframes(w.getnframes())
    a = array("h")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    return a


def write_wav_i16(path, samples):
    """Write via the wave module (already 16 kHz mono 16-bit), then hand it
    to afconvert so the published artifact is afconvert-produced, exactly as
    the capture pipeline's files are."""
    a = samples
    if sys.byteorder == "big":
        a = array("h", samples)
        a.byteswap()
    tmp = path + ".raw.tmp.wav"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(a.tobytes())
    run([AFCONVERT, "-f", "WAVE", "-d", "LEI16@%d" % RATE, "-c", "1", tmp, path])
    os.remove(tmp)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# energy trim
# --------------------------------------------------------------------------

def frame_rms_series(samples):
    n = len(samples)
    nf = n // FRAME
    out = []
    for f in range(nf):
        base = f * FRAME
        acc = 0
        for i in range(base, base + FRAME):
            v = samples[i]
            acc += v * v
        out.append(math.sqrt(acc / float(FRAME)))
    return out


def energy_trim(samples, top_db=35.0, pad_ms=20.0, abs_floor=25.0):
    """Return (start, end) sample indices bounding the speech.

    A frame counts as speech when its RMS is within `top_db` of the clip's
    loudest frame AND above an absolute floor (so a clip that is pure dither
    does not 'find' speech in its own noise)."""
    n = len(samples)
    if n == 0:
        return (0, 0)
    rms = frame_rms_series(samples)
    if not rms:
        return (0, n)
    peak = max(rms)
    if peak <= 0.0:
        return (0, 0)
    thr = max(peak * (10.0 ** (-top_db / 20.0)), abs_floor)
    first = last = None
    for f, r in enumerate(rms):
        if r >= thr:
            if first is None:
                first = f
            last = f
    if first is None:
        return (0, 0)
    pad = int(round(pad_ms / 1000.0 * RATE))
    s = max(0, first * FRAME - pad)
    e = min(n, (last + 1) * FRAME + pad)
    return (s, e)


def rms_of(samples, lo=None, hi=None):
    lo = 0 if lo is None else max(0, lo)
    hi = len(samples) if hi is None else min(len(samples), hi)
    if hi <= lo:
        return 0.0
    acc = 0
    for i in range(lo, hi):
        v = samples[i]
        acc += v * v
    return math.sqrt(acc / float(hi - lo))


# --------------------------------------------------------------------------
# TTS with on-disk cache
# --------------------------------------------------------------------------

class Synth(object):
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir
        os.makedirs(cache_dir, exist_ok=True)
        self.calls = 0
        self.hits = 0

    def _key(self, voice, text, rate_wpm):
        payload = json.dumps(
            {
                "v": voice,
                "t": text,
                "r": rate_wpm,
                "sr": RATE,
                "trim": [35.0, 20.0, 25.0],
                "ver": 2,
            },
            ensure_ascii=False,
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()[:32]

    def utterance(self, voice, text, rate_wpm=None):
        """Synthesize one utterance and return its energy-trimmed samples."""
        key = self._key(voice, text, rate_wpm)
        cached = os.path.join(self.cache_dir, "u_%s.wav" % key)
        if os.path.exists(cached):
            self.hits += 1
            return read_wav_i16(cached)

        self.calls += 1
        tmpd = tempfile.mkdtemp(prefix="f217say_")
        try:
            aiff = os.path.join(tmpd, "u.aiff")
            wav = os.path.join(tmpd, "u.wav")
            cmd = [SAY, "-v", voice]
            if rate_wpm:
                cmd += ["-r", str(int(rate_wpm))]
            cmd += ["-o", aiff, "--", text]
            run(cmd)
            run([AFCONVERT, "-f", "WAVE", "-d", "LEI16@%d" % RATE, "-c", "1", aiff, wav])
            samples = read_wav_i16(wav)
            s, e = energy_trim(samples)
            trimmed = samples[s:e]
            dur = len(trimmed) / float(RATE)
            if dur < MIN_UTTERANCE_SEC:
                raise GenError(
                    "voice %r produced only %.3f s of audio for %r.\n"
                    "This almost always means the voice cannot speak this "
                    "language. Fix the voice assignment in the manifest; do "
                    "NOT ship this fixture." % (voice, dur, text[:60])
                )
            write_wav_i16(cached, trimmed)
            return trimmed
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)


# --------------------------------------------------------------------------
# track buffer (32-bit accumulator so sample-level mixing cannot wrap)
# --------------------------------------------------------------------------

class Track(object):
    def __init__(self, name):
        self.name = name
        self.buf = array("i")
        self.watermark = 0      # every index >= watermark is still zero

    def __len__(self):
        return len(self.buf)

    def ensure(self, n):
        if n > len(self.buf):
            self.buf.extend(array("i", bytes(4 * (n - len(self.buf)))))

    def add(self, pos, clip, gain=1.0):
        """Mix `clip` in at sample offset `pos`. Genuine sample-level add."""
        if pos < 0:
            raise GenError("negative placement %d on track %s" % (pos, self.name))
        n = len(clip)
        if n == 0:
            return
        end = pos + n
        self.ensure(end)
        if gain != 1.0:
            clip = array("i", [int(round(s * gain)) for s in clip])
        buf = self.buf
        if pos >= self.watermark:
            # pristine region: bulk copy (C-level), no per-sample Python work
            buf[pos:end] = array("i", clip)
        else:
            for i in range(n):
                buf[pos + i] += clip[i]
        if end > self.watermark:
            self.watermark = end

    def add_track(self, other, offset):
        """Mix another track in, shifted by `offset` samples."""
        self.add_i32(offset, other.buf)

    def add_i32(self, pos, data):
        n = len(data)
        if n == 0:
            return
        end = pos + n
        self.ensure(end)
        buf = self.buf
        if pos >= self.watermark:
            buf[pos:end] = data
        else:
            for i in range(n):
                buf[pos + i] += data[i]
        if end > self.watermark:
            self.watermark = end

    def peak(self):
        if not self.buf:
            return 0
        return max(abs(min(self.buf)), abs(max(self.buf)))

    def to_i16(self):
        """Clamp to int16. If the mix would clip, apply one global gain
        instead of hard-clipping, and report it (clipping is distortion the
        benchmark did not ask for)."""
        pk = self.peak()
        applied = None
        if pk <= 32767:
            out = array("h", self.buf)
        else:
            g = 32767.0 * 0.98 / pk
            out = array("h", [int(v * g) for v in self.buf])
            applied = round(20.0 * math.log10(g), 3)
        return out, applied


# --------------------------------------------------------------------------
# non-speech signal synthesis (music fixture)
# --------------------------------------------------------------------------

_SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def note_hz(name):
    m = re.match(r"^([A-G])([#b]?)(-?\d+)$", name)
    if not m:
        raise GenError("bad note name %r" % name)
    semi = _SEMI[m.group(1)]
    if m.group(2) == "#":
        semi += 1
    elif m.group(2) == "b":
        semi -= 1
    octave = int(m.group(3))
    midi = (octave + 1) * 12 + semi
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def synth_music(spec, rnd):
    """Deterministic chord-sequence instrument tone. No speech whatsoever."""
    bpm = float(spec.get("bpm", 84))
    beats = float(spec.get("beats_per_chord", 4))
    chord_sec = 60.0 / bpm * beats
    amp = float(spec.get("amplitude", 0.22)) * 32767.0
    partials = spec.get("partials", [[1, 1.0], [2, 0.42], [3, 0.18], [4, 0.07]])
    attack = float(spec.get("attack", 0.06))
    release = float(spec.get("release", 0.45))
    n_chord = int(round(chord_sec * RATE))

    out = array("i")
    for chord in spec["progression"]:
        freqs = [note_hz(n) for n in chord]
        # tiny per-chord detune, seeded, so the tone is not sterile
        detune = [1.0 + (rnd.random() - 0.5) * 0.002 for _ in freqs]
        block = array("i", bytes(4 * n_chord))
        norm = amp / max(1.0, float(len(freqs)))
        for fi, f0 in enumerate(freqs):
            f = f0 * detune[fi]
            for k, kamp in partials:
                w = 2.0 * math.pi * f * k / RATE
                a = norm * kamp
                for i in range(n_chord):
                    t = i / float(RATE)
                    if t < attack:
                        env = t / attack
                    elif t > chord_sec - release:
                        env = max(0.0, (chord_sec - t) / release)
                    else:
                        env = 1.0
                    block[i] += int(a * env * math.sin(w * i))
        out.extend(block)
    return out


def synth_noise(n, rnd):
    """White noise, uniform. Seeded -> byte-identical across runs."""
    a = array("i", bytes(4 * n))
    for i in range(n):
        a[i] = int(round((rnd.random() * 2.0 - 1.0) * 10000.0))
    return a


# --------------------------------------------------------------------------
# turn algebra
# --------------------------------------------------------------------------

def merge_turns(segments, merge_gap):
    """Collapse consecutive same-speaker utterances into one reference turn.

    A 'turn' in the reference is a speaker-homogeneous stretch; two utterances
    by the same speaker separated by less than `merge_gap` are one turn (this
    is how a >30 s turn is built out of 1-3 sentence utterances)."""
    segs = sorted(segments, key=lambda s: (s["start"], s["end"]))
    turns = []
    for s in segs:
        if turns:
            cur = turns[-1]
            if cur["speaker"] == s["speaker"] and s["start"] - cur["end"] <= merge_gap + 1e-9:
                cur["end"] = max(cur["end"], s["end"])
                continue
        turns.append({"start": s["start"], "end": s["end"], "speaker": s["speaker"]})
    return turns


def overlap_intervals(turns):
    """Every stretch of time where two DIFFERENT speakers are both active."""
    raw = []
    for i in range(len(turns)):
        for j in range(i + 1, len(turns)):
            a, b = turns[i], turns[j]
            if a["speaker"] == b["speaker"]:
                continue
            lo = max(a["start"], b["start"])
            hi = min(a["end"], b["end"])
            if hi - lo > 1e-9:
                raw.append([lo, hi])
    raw.sort()
    merged = []
    for iv in raw:
        if merged and iv[0] <= merged[-1][1] + 1e-9:
            merged[-1][1] = max(merged[-1][1], iv[1])
        else:
            merged.append([iv[0], iv[1]])
    return merged


def r6(x):
    return round(float(x) + 0.0, 6)


# --------------------------------------------------------------------------
# layout engine
# --------------------------------------------------------------------------

def gap_value(spec, rnd):
    if spec is None:
        return 0.0
    if isinstance(spec, (int, float)):
        return float(spec)
    if "fixed" in spec:
        return float(spec["fixed"])
    return rnd.uniform(float(spec["min"]), float(spec["max"]))


def voice_for(fixture, speaker, item):
    spk = fixture["speakers"].get(speaker)
    if spk is None:
        raise GenError("fixture %s: unknown speaker %r" % (fixture["id"], speaker))
    # A code-switching speaker may declare one voice per language, but the
    # manifest is expected to use a single bilingual voice so that the
    # speaker's timbre stays constant across the language switch.
    if "voices_by_lang" in spk:
        lang = item.get("lang")
        if lang not in spk["voices_by_lang"]:
            raise GenError(
                "fixture %s: speaker %s has no voice for lang %r"
                % (fixture["id"], speaker, lang)
            )
        return spk["voices_by_lang"][lang], spk.get("rate")
    return spk["voice"], spk.get("rate")


def build_speech(fixture, synth, rnd):
    """Lay out utterances on one or more tracks and return
    (tracks, track_offsets_sec, segments, mix_len_samples)."""
    layout = fixture["layout"]
    kind = layout.get("kind", "sequential")
    script = fixture.get("script", [])

    if kind == "two_track":
        offsets = {}
        for tname, tspec in layout["tracks"].items():
            offsets[tname] = float(tspec.get("offset", 0.0))
        default_track = layout.get("default_track", "mic")
    else:
        offsets = {"main": 0.0}
        default_track = "main"

    max_off = max(offsets.values()) if offsets else 0.0
    lead_in = float(layout.get("lead_in", 0.5))
    if lead_in < max_off - 1e-9:
        raise GenError(
            "fixture %s: lead_in %.3f must be >= the largest track offset %.3f"
            % (fixture["id"], lead_in, max_off)
        )

    tracks = dict((name, Track(name)) for name in offsets)
    off_samples = dict((k, int(round(v * RATE))) for k, v in offsets.items())

    segments = []
    bleed = layout.get("bleed")
    repeat_until = layout.get("repeat_until")
    merge_gap = float(layout.get("merge_same_speaker_gap", 0.5))

    cursor = lead_in          # absolute time of the next utterance start
    prev_end = None
    idx = 0
    placed = 0
    max_abs_end = 0.0

    while True:
        if repeat_until is None:
            if idx >= len(script):
                break
            item = script[idx]
        else:
            if not script:
                break
            item = script[idx % len(script)]

        speaker = item["speaker"]
        voice, rate_wpm = voice_for(fixture, speaker, item)
        clip = synth.utterance(voice, item["text"], item.get("rate", rate_wpm))
        dur = len(clip) / float(RATE)

        if placed == 0:
            start_t = lead_in
        else:
            g = item["gap"] if "gap" in item else gap_value(layout.get("gap"), rnd)
            start_t = prev_end + float(g)
        if start_t < max_off - 1e-9:
            raise GenError(
                "fixture %s: utterance %d would start at %.3f s, before the "
                "largest track offset %.3f s" % (fixture["id"], idx, start_t, max_off)
            )

        if repeat_until is not None and placed > 0:
            if start_t + dur > float(repeat_until):
                break

        tname = item.get("track", default_track)
        if tname not in tracks:
            raise GenError("fixture %s: unknown track %r" % (fixture["id"], tname))

        # Absolute mixed-timeline position, quantized to a sample. The truth
        # is derived from this integer, so it is exact by construction.
        abs_pos = int(round(start_t * RATE))
        local_pos = abs_pos - off_samples[tname]
        if local_pos < 0:
            raise GenError("fixture %s: negative local position" % fixture["id"])
        tracks[tname].add(local_pos, clip)

        seg_start = abs_pos / float(RATE)
        seg_end = (abs_pos + len(clip)) / float(RATE)
        segments.append(
            {
                "start": seg_start,
                "end": seg_end,
                "speaker": speaker,
                "text": item["text"],
                "voice": voice,
                "track": tname,
                "lang": item.get("lang"),
            }
        )
        max_abs_end = max(max_abs_end, seg_end)

        if bleed and tname == bleed.get("from"):
            to = bleed["to"]
            gain = 10.0 ** (float(bleed.get("gain_db", -18.0)) / 20.0)
            delay = float(bleed.get("delay", 0.0))
            b_abs = abs_pos + int(round(delay * RATE))
            b_local = b_abs - off_samples[to]
            if b_local >= 0:
                tracks[to].add(b_local, clip, gain=gain)
                max_abs_end = max(max_abs_end, (b_abs + len(clip)) / float(RATE))

        prev_end = seg_end
        idx += 1
        placed += 1
        if repeat_until is not None and placed > 100000:
            raise GenError("runaway repeat in fixture %s" % fixture["id"])

    tail = float(layout.get("tail", 0.5))
    total = max_abs_end + tail
    if repeat_until is not None:
        total = float(layout.get("pad_to", repeat_until))
        if total < max_abs_end:
            raise GenError("fixture %s: pad_to is shorter than the content" % fixture["id"])
    total_samples = int(round(total * RATE))
    return tracks, offsets, off_samples, segments, total_samples, merge_gap


def build_fixture(fixture, synth, out_dir):
    fid = fixture["id"]
    seed = int(fixture["seed"])
    rnd = random.Random(seed)
    layout = fixture.get("layout", {})
    kind = layout.get("kind", "sequential")
    processing = []

    if kind == "music":
        mix = Track("mix")
        data = synth_music(fixture["music"], rnd)
        mix.add_i32(0, data)
        lead = int(round(float(layout.get("lead_in", 0.0)) * RATE))
        if lead:
            shifted = Track("mix")
            shifted.add_i32(lead, data)
            mix = shifted
        total_samples = len(mix.buf) + int(round(float(layout.get("tail", 0.0)) * RATE))
        mix.ensure(total_samples)
        segments = []
        merge_gap = 0.0
        offsets = {}
        processing.append({"op": "music", "chords": len(fixture["music"]["progression"])})
    else:
        tracks, offsets, off_samples, segments, total_samples, merge_gap = build_speech(
            fixture, synth, rnd
        )
        mix = Track("mix")
        for tname in sorted(tracks.keys()):
            mix.add_i32(off_samples[tname], tracks[tname].buf)
            if offsets.get(tname):
                processing.append(
                    {"op": "track_offset", "track": tname, "seconds": offsets[tname]}
                )
        if layout.get("bleed"):
            b = layout["bleed"]
            processing.append(
                {
                    "op": "bleed",
                    "from": b["from"],
                    "to": b["to"],
                    "gain_db": b.get("gain_db", -18.0),
                    "delay": b.get("delay", 0.0),
                }
            )
        mix.ensure(total_samples)

    turns = merge_turns(segments, merge_gap)

    # ---- post processing ------------------------------------------------
    for op in fixture.get("post", []):
        if op["op"] == "noise":
            snr_db = float(op["snr_db"])
            # Reference level is the speech itself, measured only where
            # speech is actually present.
            acc = 0
            cnt = 0
            for t in turns:
                lo = int(round(t["start"] * RATE))
                hi = int(round(t["end"] * RATE))
                for i in range(lo, min(hi, len(mix.buf))):
                    v = mix.buf[i]
                    acc += v * v
                    cnt += 1
            speech_rms = math.sqrt(acc / float(cnt)) if cnt else 0.0
            n = max(total_samples, len(mix.buf))
            noise = synth_noise(n, rnd)
            noise_rms = rms_of(noise)
            if noise_rms <= 0 or speech_rms <= 0:
                raise GenError("fixture %s: cannot scale noise" % fid)
            k = speech_rms / (noise_rms * (10.0 ** (snr_db / 20.0)))
            buf = mix.buf
            mix.ensure(n)
            for i in range(n):
                buf[i] += int(round(noise[i] * k))
            mix.watermark = max(mix.watermark, n)
            processing.append(
                {
                    "op": "noise",
                    "snr_db": snr_db,
                    "speech_rms": round(speech_rms, 3),
                    "noise_rms": round(noise_rms * k, 3),
                }
            )
        elif op["op"] == "gain":
            g = 10.0 ** (float(op["db"]) / 20.0)
            buf = mix.buf
            for i in range(len(buf)):
                buf[i] = int(round(buf[i] * g))
            processing.append({"op": "gain", "db": op["db"]})
        else:
            raise GenError("fixture %s: unknown post op %r" % (fid, op["op"]))

    # trim/pad the accumulator to the exact declared length
    if len(mix.buf) > total_samples:
        del mix.buf[total_samples:]
    mix.ensure(total_samples)

    samples, limiter_db = mix.to_i16()
    if limiter_db is not None:
        processing.append({"op": "limiter_gain", "db": limiter_db})

    wav_path = os.path.join(out_dir, "%s.wav" % fid)
    write_wav_i16(wav_path, samples)

    # read the real artifact back: duration reported is the file's own
    nframes = assert_wav_format(wav_path)
    duration = nframes / float(RATE)

    voices = []
    for s in segments:
        if s["voice"] not in voices:
            voices.append(s["voice"])

    ovl = overlap_intervals(turns)
    truth = {
        "id": fid,
        "stratum": fixture["stratum"],
        "wav": "%s.wav" % fid,
        "rate": RATE,
        "duration": r6(duration),
        "seed": seed,
        "voices": voices,
        "sha256": sha256_file(wav_path),
        "turns": [
            {"start": r6(t["start"]), "end": r6(t["end"]), "speaker": t["speaker"]}
            for t in turns
        ],
        "overlap_intervals": [[r6(a), r6(b)] for a, b in ovl],
        # --- extras (not required, but they make the corpus reusable) ---
        "generator_version": fixture["_generator_version"],
        "description": fixture.get("description", ""),
        "speakers": dict(
            (k, {"voice": v.get("voice"), "voices_by_lang": v.get("voices_by_lang")})
            for k, v in fixture.get("speakers", {}).items()
        ),
        "track_offsets": offsets,
        "merge_same_speaker_gap": merge_gap,
        "utterances": [
            {
                "start": r6(s["start"]),
                "end": r6(s["end"]),
                "speaker": s["speaker"],
                "voice": s["voice"],
                "track": s["track"],
                "lang": s["lang"],
                "text": s["text"],
            }
            for s in segments
        ],
        "processing": processing,
    }

    run_checks(fixture, truth)

    truth_path = os.path.join(out_dir, "%s.truth.json" % fid)
    with open(truth_path, "w", encoding="utf-8") as fh:
        json.dump(truth, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")
    return truth, wav_path


# --------------------------------------------------------------------------
# post-generation assertions
# --------------------------------------------------------------------------

def run_checks(fixture, truth):
    fid = truth["id"]
    checks = fixture.get("checks", {})
    turns = truth["turns"]
    fails = []

    # universal invariants -------------------------------------------------
    dur = truth["duration"]
    last = 0.0
    for t in turns:
        if t["end"] <= t["start"]:
            fails.append("turn %r is empty or inverted" % t)
        if t["start"] < -1e-9 or t["end"] > dur + 1e-6:
            fails.append("turn %r falls outside [0, %.6f]" % (t, dur))
        if t["start"] < last - 1e-9:
            fails.append("turns are not sorted by start time")
        last = t["start"]
    for s in truth["utterances"]:
        if s["end"] - s["start"] < MIN_UTTERANCE_SEC:
            fails.append("utterance %.3f-%.3f is degenerately short" % (s["start"], s["end"]))
        covered = any(
            t["speaker"] == s["speaker"]
            and t["start"] <= s["start"] + 1e-6
            and t["end"] >= s["end"] - 1e-6
            for t in turns
        )
        if not covered:
            fails.append("utterance %.3f-%.3f/%s is not covered by any turn"
                         % (s["start"], s["end"], s["speaker"]))

    ovl_total = sum(b - a for a, b in truth["overlap_intervals"])

    # declared expectations ------------------------------------------------
    if "expect_zero_turns" in checks and checks["expect_zero_turns"]:
        if turns:
            fails.append("expected zero turns, got %d" % len(turns))
    if "expect_turn_count" in checks and len(turns) != checks["expect_turn_count"]:
        fails.append("expected %d turns, got %d" % (checks["expect_turn_count"], len(turns)))
    if "expect_speaker_count" in checks:
        n = len(set(t["speaker"] for t in turns))
        if n != checks["expect_speaker_count"]:
            fails.append("expected %d speakers, got %d" % (checks["expect_speaker_count"], n))
    if "expect_overlap_interval_count" in checks:
        n = len(truth["overlap_intervals"])
        if n != checks["expect_overlap_interval_count"]:
            fails.append("expected %d disjoint overlap regions, got %d"
                         % (checks["expect_overlap_interval_count"], n))
    if "expect_overlap_seconds" in checks:
        lo, hi = checks["expect_overlap_seconds"]
        if not (lo - 1e-6 <= ovl_total <= hi + 1e-6):
            fails.append("overlap total %.3f s outside [%s, %s]" % (ovl_total, lo, hi))
    if "expect_duration_seconds" in checks:
        lo, hi = checks["expect_duration_seconds"]
        if not (lo - 1e-6 <= dur <= hi + 1e-6):
            fails.append("duration %.3f s outside [%s, %s]" % (dur, lo, hi))
    if "expect_min_turn_seconds" in checks:
        m = checks["expect_min_turn_seconds"]
        for t in turns:
            if t["end"] - t["start"] < m - 1e-6:
                fails.append("turn %.3f-%.3f shorter than required %.1f s"
                             % (t["start"], t["end"], m))
    if "expect_max_turn_seconds" in checks:
        m = checks["expect_max_turn_seconds"]
        for t in turns:
            if t["end"] - t["start"] > m + 1e-6:
                fails.append("turn %.3f-%.3f longer than allowed %.1f s"
                             % (t["start"], t["end"], m))
    if "expect_min_gap_seconds" in checks:
        m = checks["expect_min_gap_seconds"]
        for i in range(1, len(turns)):
            g = turns[i]["start"] - turns[i - 1]["end"]
            if g < m - 1e-6:
                fails.append("gap %.3f s before turn %d is under %.1f s" % (g, i, m))

    if fails:
        raise GenError("fixture %s failed its own checks:\n  - %s" % (fid, "\n  - ".join(fails)))


# --------------------------------------------------------------------------
# manifest / lock
# --------------------------------------------------------------------------

def load_manifest(path):
    with open(path, "r", encoding="utf-8") as fh:
        man = json.load(fh)
    if "generator_version" not in man or "fixtures" not in man:
        raise GenError("manifest needs generator_version and fixtures")
    seen = set()
    for f in man["fixtures"]:
        if f["id"] in seen:
            raise GenError("duplicate fixture id %r" % f["id"])
        seen.add(f["id"])
        f["_generator_version"] = man["generator_version"]
    return man


def lock_path(out_dir):
    return os.path.join(out_dir, "manifest.lock.json")


def load_lock(out_dir):
    p = lock_path(out_dir)
    if not os.path.exists(p):
        return None
    with open(p, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_lock(out_dir, man, entries):
    lock = {
        "generator_version": man["generator_version"],
        "rate": RATE,
        "fixtures": entries,
    }
    with open(lock_path(out_dir), "w", encoding="utf-8") as fh:
        json.dump(lock, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")


def lock_entry(truth, wav_path):
    return {
        "id": truth["id"],
        "stratum": truth["stratum"],
        "sha256": truth["sha256"],
        "bytes": os.path.getsize(wav_path),
        "duration": truth["duration"],
        "seed": truth["seed"],
        "turns": len(truth["turns"]),
        "speakers": len(set(t["speaker"] for t in truth["turns"])),
    }


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_list(man, out_dir):
    lock = load_lock(out_dir) or {}
    locked = dict((e["id"], e) for e in lock.get("fixtures", []))
    hdr = ("ID", "STRATUM", "SEED", "SPK", "UTT", "LAYOUT", "DURATION")
    rows = []
    for f in man["fixtures"]:
        lay = f.get("layout", {})
        kind = lay.get("kind", "sequential")
        if lay.get("repeat_until"):
            kind += "/repeat"
        nspk = len(f.get("speakers", {}))
        nutt = len(f.get("script", []))
        e = locked.get(f["id"])
        dur = "%.2fs" % e["duration"] if e else "-"
        rows.append((f["id"], f["stratum"], str(f["seed"]), str(nspk), str(nutt), kind, dur))
    widths = [max(len(hdr[i]), max([len(r[i]) for r in rows] or [0])) for i in range(7)]
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(hdr))
    print(line)
    print("  ".join("-" * widths[i] for i in range(7)))
    for r in rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(7)))
    print("\n%d fixtures, %d strata" % (
        len(man["fixtures"]), len(set(f["stratum"] for f in man["fixtures"]))))
    return 0


def cmd_verify(man, out_dir):
    lock = load_lock(out_dir)
    if lock is None:
        print("VERIFY FAIL: no manifest.lock.json in %s" % out_dir)
        return 2
    problems = []
    if lock.get("generator_version") != man["generator_version"]:
        problems.append(
            "generator_version drift: lock=%s manifest=%s"
            % (lock.get("generator_version"), man["generator_version"])
        )
    locked = dict((e["id"], e) for e in lock.get("fixtures", []))
    man_ids = [f["id"] for f in man["fixtures"]]
    for fid in man_ids:
        if fid not in locked:
            problems.append("%s: in manifest but absent from lock" % fid)
    for fid in locked:
        if fid not in man_ids:
            problems.append("%s: in lock but absent from manifest" % fid)

    checked = 0
    for fid in man_ids:
        e = locked.get(fid)
        if e is None:
            continue
        wav = os.path.join(out_dir, "%s.wav" % fid)
        truth_p = os.path.join(out_dir, "%s.truth.json" % fid)
        if not os.path.exists(wav):
            problems.append("%s: %s.wav missing" % (fid, fid))
            continue
        if not os.path.exists(truth_p):
            problems.append("%s: %s.truth.json missing" % (fid, fid))
            continue
        digest = sha256_file(wav)
        size = os.path.getsize(wav)
        if digest != e["sha256"]:
            problems.append("%s: sha256 drift (lock %s, file %s)"
                            % (fid, e["sha256"][:12], digest[:12]))
        if size != e["bytes"]:
            problems.append("%s: size drift (lock %d, file %d)" % (fid, e["bytes"], size))
        try:
            nframes = assert_wav_format(wav)
        except GenError as exc:
            problems.append("%s: %s" % (fid, exc))
            continue
        dur = nframes / float(RATE)
        if abs(dur - e["duration"]) > 1e-6:
            problems.append("%s: duration drift (lock %.6f, file %.6f)"
                            % (fid, e["duration"], dur))
        with open(truth_p, "r", encoding="utf-8") as fh:
            truth = json.load(fh)
        if truth["sha256"] != digest:
            problems.append("%s: truth sha256 does not match the wav" % fid)
        if abs(truth["duration"] - dur) > 1e-6:
            problems.append("%s: truth duration %.6f != wav duration %.6f"
                            % (fid, truth["duration"], dur))
        if truth["rate"] != RATE:
            problems.append("%s: truth rate %s" % (fid, truth["rate"]))
        for t in truth["turns"]:
            if t["start"] < -1e-9 or t["end"] > dur + 1e-6 or t["end"] <= t["start"]:
                problems.append("%s: bad turn %r against duration %.6f" % (fid, t, dur))
        recomputed = overlap_intervals(truth["turns"])
        recomputed = [[r6(a), r6(b)] for a, b in recomputed]
        if recomputed != [[r6(a), r6(b)] for a, b in truth["overlap_intervals"]]:
            problems.append("%s: overlap_intervals disagree with turns" % fid)
        checked += 1

    if problems:
        print("VERIFY FAIL (%d problem(s)):" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1
    print("VERIFY OK: %d fixtures, hashes/sizes/durations/turns all match the lock." % checked)
    return 0


def cmd_generate(man, out_dir, only, cache_dir, keep_lock_for_missing=True):
    os.makedirs(out_dir, exist_ok=True)
    synth = Synth(cache_dir)
    fixtures = man["fixtures"]
    if only:
        fixtures = [f for f in fixtures if f["id"] in only]
        missing = set(only) - set(f["id"] for f in fixtures)
        if missing:
            raise GenError("no such fixture(s): %s" % ", ".join(sorted(missing)))

    prev = load_lock(out_dir)
    entries = dict((e["id"], e) for e in (prev or {}).get("fixtures", [])) if only else {}

    for f in fixtures:
        sys.stdout.write("  %-22s " % f["id"])
        sys.stdout.flush()
        truth, wav = build_fixture(f, synth, out_dir)
        entries[f["id"]] = lock_entry(truth, wav)
        nspk = len(set(t["speaker"] for t in truth["turns"]))
        ovl = sum(b - a for a, b in truth["overlap_intervals"])
        print(
            "ok  %8.2fs  turns=%-4d spk=%-2d overlap=%5.2fs  %s"
            % (truth["duration"], len(truth["turns"]), nspk, ovl, truth["sha256"][:12])
        )

    order = [f["id"] for f in man["fixtures"] if f["id"] in entries]
    write_lock(out_dir, man, [entries[i] for i in order])
    print("\ntts: %d synthesized, %d from cache" % (synth.calls, synth.hits))
    print("lock: %s (%d fixtures)" % (lock_path(out_dir), len(order)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="F217 synthetic multi-speaker diarization corpus generator"
    )
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--manifest", default=os.path.join(here, "manifest.json"))
    ap.add_argument("--out", default=None, help="output directory")
    ap.add_argument("--only", action="append", default=None, help="fixture id (repeatable)")
    ap.add_argument("--verify", action="store_true", help="check hashes against the lock")
    ap.add_argument("--list", action="store_true", dest="do_list")
    ap.add_argument("--cache-dir", default=None, help="TTS cache (default <out>/.cache/tts)")
    args = ap.parse_args(argv)

    try:
        man = load_manifest(args.manifest)
    except GenError as exc:
        print("manifest error: %s" % exc, file=sys.stderr)
        return 2

    out_dir = args.out or os.path.join(here, "out")
    if args.do_list:
        return cmd_list(man, out_dir)
    if args.verify:
        return cmd_verify(man, out_dir)

    cache_dir = args.cache_dir or os.path.join(out_dir, ".cache", "tts")
    try:
        return cmd_generate(man, out_dir, args.only, cache_dir)
    except GenError as exc:
        print("\nGENERATION FAILED: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
