#!/usr/bin/env python3
"""Measure Quick Dictation's recognizer latency under the conditions the app actually produces,
through the PRODUCTION helpers (F890).

Like `dictation-ab.py`, this spawns the shipped `qwen_dictate_server.py` and `refine_server.py` with
the exact argv and environment `WarmWhisperDictationEngine` / `WarmRefineEngine` use, and speaks the
same newline-delimited JSON wire. Unlike it, it does not compare engines or words: it asks how long
ONE 3 s clip takes to come back while something else is going on, which is the question "dictation
got slow" needs answered before anything in the app is changed.

Conditions (each ASR point is one request on `clips/en1.wav`, ~3.1 s of speech):

    A   alone        the recognizer warm and alone — the baseline
    B1  loading      ASR while the refiner is loading its model
    C   resident     ASR with the refiner resident and idle (the steady state the app wants)
    D   refine       refine latency on a 30-word text, refiner resident and primed
    B2  kill-cycle   what the app does on a press mid-prewarm: SIGTERM the refiner (resident, then
                     3 s into a load), wait for its exit as `evict()` does, ASR at once
    F   aging        12 requests back to back on one helper, first vs last
    G   pressure     a process allocates HOG_GB (default 6) and keeps touching every page for
                     HOG_SECS (20) while the recognizer idles, without and then with the refiner
                     resident; vmmap's resident/swapped sizes for the helper before and after
    K   cpu          CPU_HOG_N (12) spinning processes for 25 s; ASR during them
    L   gpu          another MLX process runs a 4096×4096 matmul loop on the GPU for 25 s; ASR
                     during it (uses the Qwen venv's python)

Measured 2026-10-08 on an M3 Pro, 18 GB (F890's log entry has the table): every condition but L
stays within 0.3–0.8 s; L is 4.2–4.8 s. A busy GPU is the one thing that makes the recognizer slow.

Usage:
    Scripts/bench/dictation-latency.py --out /tmp/latency.json              # all conditions
    Scripts/bench/dictation-latency.py --conditions A,L --out /tmp/l.json   # a subset
    HOG_GB=9 HOG_SECS=45 Scripts/bench/dictation-latency.py --conditions A,G --out /tmp/g.json

Refuses to run while the app's own helpers are alive (they would share the GPU and memory with the
ones this script spawns, and the app's next dictation would pay for it). Requires the Qwen and
summarizer runtimes (Settings → Install…) and `Scripts/bench/generate_clips.sh` to have produced the
clips. Reads only the bench clips — never a user recording, meeting index, or transcript. G, K and L
load the machine on purpose; do not run them while someone is dictating.
"""
import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
CLIP = os.path.join(BENCH, "clips", "en1.wav")
SUPPORT = os.path.expanduser("~/Library/Application Support/WhisperMeet")

# Mirrors DictationController.makeEngine(for:) / WarmRefineEngine — keep in sync if those change.
ASR = dict(
    python=f"{SUPPORT}/Runtime/Qwen3ASR/venv/bin/python",
    args=[f"{SUPPORT}/Runtime/Qwen3ASR/qwen_dictate_server.py",
          "--model", f"{SUPPORT}/Runtime/Qwen3ASR/model"],
    env={"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
)
REFINE = dict(
    python=f"{SUPPORT}/Runtime/Summarizer/venv/bin/python",
    args=[f"{SUPPORT}/Runtime/Summarizer/refine_server.py",
          "--model", f"{SUPPORT}/Runtime/Summarizer/model"],
    # LocalSummarizer.makeEnvironment
    env={"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONUNBUFFERED": "1",
         "PATH": "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin")},
)
# DictationRefinePrompt.system(languageCode: nil), copied so this script stays stdlib-only.
SYSTEM_PROMPT = (
    'You clean up text that a person dictated by voice. Correct grammar, punctuation, '
    'capitalization, and obvious speech-to-text mistakes, and remove filler words such as '
    '"um", "uh", and "you know". Keep the speaker\'s wording, sentence order, and meaning '
    'exactly: do not rephrase, do not summarize, do not add content, and do not answer the '
    'text as if it were a question. Reply in the same language as the input; never translate. '
    'Reply with ONLY the corrected text — no quotation marks around it, no explanation, no markdown.'
)
TEXT_30 = ("um so I think we should move the launch to next week because the uh backend team "
           "still needs two more days to finish the migration and you know QA has not started")

HOG = """
import sys, time
gb = float(sys.argv[1]); secs = float(sys.argv[2])
buf = bytearray(int(gb * (1 << 30)))
end = time.monotonic() + secs
while time.monotonic() < end:
    for i in range(0, len(buf), 16384):
        buf[i] = (buf[i] + 1) & 255
"""
CPU_SPIN = "import time,sys\nend=time.monotonic()+float(sys.argv[1])\nx=0\nwhile time.monotonic()<end:\n    x=(x*31+7)%1000003\n"
GPU_SPIN = """
import time, sys
import mlx.core as mx
end = time.monotonic() + float(sys.argv[1])
a = mx.random.normal((4096, 4096)); b = mx.random.normal((4096, 4096))
while time.monotonic() < end:
    c = a @ b
    mx.eval(c)
"""


class Helper:
    """One resident helper, driven exactly as the Swift engine drives it."""

    def __init__(self, name, spec, stderr_path):
        self.name = name
        self.spec = spec
        self.stderr_path = stderr_path
        self.proc = None
        self.started = None

    def spawn(self):
        env = dict(os.environ)
        env.update(self.spec["env"])
        self.started = time.monotonic()
        self.proc = subprocess.Popen(
            [self.spec["python"], *self.spec["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(self.stderr_path, "ab"), env=env, text=True, bufsize=1)
        return self

    def wait_ready(self):
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"{self.name} exited before ready (rc={self.proc.poll()})")
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("ready"):
                return time.monotonic() - self.started
            if obj.get("error"):
                raise RuntimeError(f"{self.name}: {obj['error']}")

    def request(self, payload):
        t0 = time.monotonic()
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        dt = time.monotonic() - t0
        if not line:
            raise RuntimeError(f"{self.name} closed stdout (rc={self.proc.poll()})")
        return dt, json.loads(line)

    def terminate_and_wait(self):
        """What requestHelperTermination + evict() do: close stdin, SIGTERM, SIGKILL after 5 s."""
        t0 = time.monotonic()
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
            how = "sigterm"
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            how = "sigkill-after-5s"
        return time.monotonic() - t0, how


def vm():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    stats = {}
    for line in out.splitlines()[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            stats[key.strip()] = int(value.strip().rstrip("."))
    return {"free_pages": stats.get("Pages free", 0), "pageouts": stats.get("Pageouts", 0),
            "swapins": stats.get("Swapins", 0)}


def swapped(pid):
    """vmmap --summary's TOTAL line: virtual, resident, dirty, swapped sizes for one process."""
    out = subprocess.run(["vmmap", "--summary", str(pid)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("TOTAL"):
            fields = line.split()
            return {"resident": fields[2], "swapped": fields[4]}
    return {}


def pressure(gb, secs):
    t0 = time.monotonic()
    subprocess.run([sys.executable, "-c", HOG, str(gb), str(secs)], check=True)
    return round(time.monotonic() - t0, 1)


def start_cpu_hog(count, secs):
    return [subprocess.Popen([sys.executable, "-c", CPU_SPIN, str(secs)]) for _ in range(count)]


def start_gpu_hog(secs):
    return [subprocess.Popen([ASR["python"], "-c", GPU_SPIN, str(secs)], stderr=subprocess.DEVNULL)]


def asr(helper):
    dt, response = helper.request({"wavPath": CLIP, "language": None, "initialPrompt": None})
    assert response.get("error") is None, response
    return round(dt, 3)


def refine(helper, text=TEXT_30):
    dt, response = helper.request({"text": text, "systemPrompt": SYSTEM_PROMPT, "maxTokens": 256})
    assert response.get("error") is None, response
    return round(dt, 3), response.get("text", "")


def timed_points(helper, count, t0):
    points = []
    for _ in range(count):
        points.append((round(time.monotonic() - t0, 1), asr(helper)))
    return points


def app_helpers_alive():
    pattern = "WhisperMeet/Runtime/.*(qwen_dictate_server|whisper_dictate_server|refine_server)"
    return subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="write the JSON results here")
    parser.add_argument("--conditions", default="A,B1,C,D,B2,F,G,K,L",
                        help="comma-separated subset of A,B1,C,D,B2,F,G,K,L")
    args = parser.parse_args()
    want = set(args.conditions.split(","))
    if app_helpers_alive():
        sys.exit("the app's dictation helpers are running; wait for its idle eviction (5 min) first")
    if not os.path.exists(CLIP):
        sys.exit(f"{CLIP} is missing — run Scripts/bench/generate_clips.sh")

    results = {
        "host": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                               capture_output=True, text=True).stdout.strip(),
        "vm_start": vm(), "conditions": {},
    }
    logdir = os.path.dirname(os.path.abspath(args.out))

    def note(condition, **fields):
        fields["vm"] = vm()
        results["conditions"][condition] = fields
        print(f"[{condition}] {json.dumps(fields)}", flush=True)

    asr_h = Helper("asr", ASR, os.path.join(logdir, "asr-helper.stderr")).spawn()
    results["asr_load_s"] = round(asr_h.wait_ready(), 2)
    print(f"asr ready in {results['asr_load_s']}s", flush=True)
    asr(asr_h)  # one warm request, discarded

    if "A" in want:
        note("A_alone", asr_s=[asr(asr_h) for _ in range(3)])

    ref_h = None

    def resident_refiner():
        helper = Helper("refine", REFINE, os.path.join(logdir, "refine-helper.stderr")).spawn()
        load = helper.wait_ready()
        prime, _ = helper.request({"text": "ready", "systemPrompt": SYSTEM_PROMPT, "maxTokens": 8})
        results.setdefault("refine_loads_s", []).append(round(load, 2))
        results.setdefault("refine_primes_s", []).append(round(prime, 2))
        return helper

    if want & {"B1", "C", "D", "B2"}:
        ref_h = Helper("refine", REFINE, os.path.join(logdir, "refine-helper.stderr")).spawn()
        if "B1" in want:
            note("B1_asr_while_refiner_loading", points=timed_points(asr_h, 4, time.monotonic()))
        results.setdefault("refine_loads_s", []).append(round(ref_h.wait_ready(), 2))
        prime, _ = ref_h.request({"text": "ready", "systemPrompt": SYSTEM_PROMPT, "maxTokens": 8})
        results.setdefault("refine_primes_s", []).append(round(prime, 2))

    if "C" in want:
        note("C_asr_refiner_resident", asr_s=[asr(asr_h) for _ in range(3)])

    if "D" in want:
        outputs = [refine(ref_h) for _ in range(3)]
        note("D_refine_resident", refine_s=[o[0] for o in outputs], sample=outputs[0][1])

    if "B2" in want:
        cycles = []
        exit_s, how = ref_h.terminate_and_wait()
        cycles.append({"kind": "resident", "exit_wait_s": round(exit_s, 2), "how": how,
                       "asr_after": asr(asr_h)})
        for _ in range(2):
            ref_h = Helper("refine", REFINE, os.path.join(logdir, "refine-helper.stderr")).spawn()
            time.sleep(3.0)  # the user presses again ~3 s after the paste
            exit_s, how = ref_h.terminate_and_wait()
            cycles.append({"kind": "mid-load-3s", "exit_wait_s": round(exit_s, 2), "how": how,
                           "asr_after": asr(asr_h)})
        note("B2_kill_cycle", cycles=cycles)
        ref_h = None

    if "G" in want:
        gb = float(os.environ.get("HOG_GB", "6"))
        secs = float(os.environ.get("HOG_SECS", "20"))
        if ref_h is not None:
            ref_h.terminate_and_wait()
            ref_h = None
        runs = {}
        asr(asr_h)
        before = swapped(asr_h.proc.pid)
        hog_s = pressure(gb, secs)
        runs["no_refiner"] = {"hog_s": hog_s, "helper_before": before,
                              "helper_after": swapped(asr_h.proc.pid),
                              "asr_after": [asr(asr_h) for _ in range(3)]}
        ref_h = resident_refiner()
        asr(asr_h)
        before = swapped(asr_h.proc.pid)
        hog_s = pressure(gb, secs)
        runs["refiner_resident"] = {"hog_s": hog_s, "helper_before": before,
                                    "helper_after": swapped(asr_h.proc.pid),
                                    "asr_after": [asr(asr_h) for _ in range(3)],
                                    "refine_after": refine(ref_h)[0]}
        note("G_idle_under_pressure", hog_gb=gb, hog_secs=secs, runs=runs)

    if "K" in want:
        count = int(os.environ.get("CPU_HOG_N", "12"))
        t0 = time.monotonic()
        hogs = start_cpu_hog(count, 25)
        time.sleep(2)
        points = timed_points(asr_h, 4, t0)
        for hog in hogs:
            hog.wait()
        note("K_cpu_contention", procs=count, points=points, after=[asr(asr_h) for _ in range(2)])

    if "L" in want:
        t0 = time.monotonic()
        hogs = start_gpu_hog(25)
        time.sleep(3)
        points = timed_points(asr_h, 4, t0)
        for hog in hogs:
            hog.wait()
        note("L_gpu_contention", points=points, after=[asr(asr_h) for _ in range(2)])

    if "F" in want:
        series = [asr(asr_h) for _ in range(12)]
        note("F_aging", series=series, first=series[0], last=series[-1],
             median=statistics.median(series))

    if ref_h is not None:
        ref_h.terminate_and_wait()
    asr_h.terminate_and_wait()
    results["vm_end"] = vm()
    with open(args.out, "w") as handle:
        json.dump(results, handle, indent=2)
    print("written", args.out)


if __name__ == "__main__":
    main()
