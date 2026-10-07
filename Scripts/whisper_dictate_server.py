# Scripts/whisper_dictate_server.py
"""Resident MLX-Whisper helper for WhisperMeet quick dictation.

Loads an Apple-Silicon MLX Whisper model once, then serves newline-delimited JSON
requests on stdin and writes newline-delimited JSON responses on stdout. Local-only;
no network at request time (model weights are cached under the app's support dir). The one
exception is the model's own first download, before it is loaded (F522): a start whose cache is
incomplete downloads it, resuming any partial file, and reports `{"downloading": true}` lines on
stdout while bytes arrive; every later start is offline.
Exits cleanly when stdin closes (the app terminates it to evict the model).

Meetings still use openai/whisper via LocalWhisperClient; this MLX path is dictation-only.
"""
import argparse
import contextlib
import errno
import hashlib
import http.client
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave


def model_fully_cached(hub_dir: str, mlx_repo: str) -> bool:
    """Whether the MLX model's required files are actually present in the local HF cache.

    huggingface_hub creates the `models--org--repo` directory tree at the START of a download
    (before any weights finish), so directory existence does NOT mean the model is usable. We
    check what `try_to_load_from_cache` checks (`file_download.py:1529-1559` in 1.24.0) — `refs/main`
    names a commit, and the files mlx_whisper needs, config.json and weights.safetensors, are real
    files in that commit's snapshot (`isfile` follows the symlink, so a link to a deleted blob is not
    a model) — but by reading the layout ourselves, not by asking the library. The ref is read
    unstripped, as the library reads it: a ref the library could not resolve is not a cache.

    Why not ask it (F522): importing `huggingface_hub` freezes `HF_HUB_OFFLINE` at that moment
    (`constants.py:202`), and this runs BEFORE the helper decides to set it. The helper used to
    import the library here and set the variable afterwards, which did nothing, so a fully cached
    helper still made network calls at every start — contradicting this module's "no network at
    request time". Nothing before that decision may import the library.
    """
    repo_cache = os.path.join(hub_dir, "models--" + mlx_repo.replace("/", "--"))
    try:
        with open(os.path.join(repo_cache, "refs", "main")) as handle:
            commit = handle.read()
    except OSError:
        return False
    if not commit or os.sep in commit or commit.startswith("."):
        return False
    snapshot = os.path.join(repo_cache, "snapshots", commit)
    return all(os.path.isfile(os.path.join(snapshot, name)) for name in DICTATION_MODEL_FILES)


def go_offline() -> None:
    """Forbid the network for the rest of this process.

    `HF_HUB_OFFLINE` is read when `huggingface_hub` is imported, so the environment variable only
    works if it is set first; if the library is already imported (the fallback downloader imports
    it), the module's own flag has to be set too."""
    os.environ["HF_HUB_OFFLINE"] = "1"
    constants = sys.modules.get("huggingface_hub.constants")
    if constants is not None:
        constants.HF_HUB_OFFLINE = True


# F522 — the first-run model download.
#
# The 1.6 GB weights used to be fetched inside `mlx_whisper.load_model`'s own `snapshot_download`,
# and two things made that fail on a slow or unreliable link. The helper deleted the whole model
# cache whenever it found the download unfinished, and the app gave the whole warm-up a flat 30
# minutes, so a link under ~7 Mbit/s could never finish. Neither is fixed by leaving the cache alone,
# because the installed huggingface_hub never resumes a partial file across processes: each attempt
# writes `blobs/<etag>.<random>.incomplete` (`file_download.py:1908` in 1.24.0), deletes it when the
# attempt raises (`:1946-1949`), and orphans it when the process is killed. So the helper downloads
# the two files itself, with HTTP `Range`, into a partial file named for the blob it will become,
# then lays them out exactly as the library would (blobs/, snapshots/<commit>/, refs/main) so that
# `model_fully_cached` and the library's offline load see an ordinary cache.
#
# While bytes arrive it prints `{"downloading": true}` (at most once a second) and closes with
# `{"downloading": false}`; the app reads the first as "the wait is now no-progress-for-N-seconds"
# rather than a flat budget. Only the resumable path is responsible for those reports being honest —
# they are printed as chunks are written, never from a timer.

DICTATION_MODEL_FILES = ("config.json", "weights.safetensors")
DOWNLOAD_REPORT_INTERVAL_SECONDS = 1.0
DOWNLOAD_CHUNK_BYTES = 1 << 20
DOWNLOAD_RETRIES = 5
DOWNLOAD_REQUEST_TIMEOUT_SECONDS = 60
DOWNLOAD_USER_AGENT = "WhisperMeet-dictation-model-download"
_SAFE_BLOB_NAME = re.compile(r"^[0-9A-Za-z._-]+$")
_SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
_TRANSIENT_ERRORS = (urllib.error.URLError, http.client.HTTPException, socket.timeout, ConnectionError, OSError)


class ModelDownloadError(Exception):
    """The download ran and failed. Partial bytes are kept for the next attempt to resume — unless
    they were found corrupt, in which case they were discarded — so never start over for this."""


class ResumableDownloadUnavailable(Exception):
    """The resumable path could not even start (metadata unusable). Nothing on disk was changed, so
    the library's own downloader is a safe fallback."""


def emit_download_report(active) -> None:
    sys.stdout.write(json.dumps({"downloading": bool(active)}) + "\n")
    sys.stdout.flush()


class DownloadHeartbeat:
    """Reports that bytes are arriving, at most once per `interval`. Called per chunk written."""

    def __init__(self, emit=emit_download_report, clock=time.monotonic,
                 interval=DOWNLOAD_REPORT_INTERVAL_SECONDS):
        self._emit = emit
        self._clock = clock
        self._interval = interval
        self._last = None

    def tick(self) -> None:
        now = self._clock()
        if self._last is None or now - self._last >= self._interval:
            self._last = now
            self._emit(True)


def offline_requested() -> bool:
    """`HF_HUB_OFFLINE` as the library reads it: the caller has forbidden the network."""
    return os.environ.get("HF_HUB_OFFLINE", "").upper() in ("1", "ON", "YES", "TRUE")


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """The Hub answers a `resolve/` HEAD for a large file with a 302 whose headers carry the commit,
    checksum and size. Following it would discard exactly what the HEAD is for."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _normalize_etag(value):
    if not value:
        return None
    value = value.strip()
    if value.startswith("W/"):
        value = value[2:]
    return value.strip('"')


def _int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _resolve_url(endpoint, repo, revision, filename):
    return "%s/%s/resolve/%s/%s" % (
        endpoint, repo, urllib.parse.quote(revision, safe=""), urllib.parse.quote(filename)
    )


def _head(url, timeout):
    """(status, headers) of one HEAD, redirects NOT followed. An error status is a result here."""
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": DOWNLOAD_USER_AGENT, "Accept-Encoding": "identity"}
    )
    try:
        response = urllib.request.build_opener(_NoRedirects).open(request, timeout=timeout)
        return response.status, response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.headers


def _file_metadata(endpoint, repo, revision, filename, timeout):
    """(commit, etag, size) the Hub reports for one file, read the way the library reads it
    (`get_hf_file_metadata`, `file_download.py:1563-1634` in 1.24.0): same-host redirects are
    followed, and the response the chain ENDS on is the one read — a different host's redirect
    (the CDN a large file lives on) is where it stops, because that response is the one carrying
    the checksum and size; the linked ETag (the sha256 of an LFS/Xet file) is preferred to the plain
    one, and the linked size to Content-Length.

    The same-host hop is not optional. Against the live Hub `config.json` answers `resolve/` with a
    307 to a relative path whose own Content-Length is the REDIRECT body's (276, where the file is
    268): read as the size, every download of the real model was a size mismatch."""
    url = _resolve_url(endpoint, repo, revision, filename)
    start = url
    commit_seen = None
    try:
        for _hop in range(6):
            status, headers = _head(url, timeout)
            commit_seen = headers.get("X-Repo-Commit") or commit_seen
            location = headers.get("Location")
            if 300 <= status < 400 and location:
                target = urllib.parse.urljoin(url, location)
                if urllib.parse.urlsplit(target).netloc == urllib.parse.urlsplit(url).netloc:
                    url = target
                    continue
            break
        else:
            raise ResumableDownloadUnavailable("too many redirects for %s" % start)
    except _TRANSIENT_ERRORS as error:
        raise ResumableDownloadUnavailable("%s: %s" % (start, error))
    if status in (401, 403, 404):
        raise ModelDownloadError("%s/%s is not available from the model hub (HTTP %d)" % (repo, filename, status))
    if status >= 400:
        raise ResumableDownloadUnavailable("HTTP %d for %s" % (status, start))
    commit = commit_seen
    etag = _normalize_etag(headers.get("X-Linked-ETag") or headers.get("ETag"))
    size = _int_or_none(headers.get("X-Linked-Size") or headers.get("Content-Length"))
    if not commit or not etag or size is None or not _SAFE_BLOB_NAME.match(etag) \
            or not re.match(r"^[0-9a-f]{40}$", commit):
        raise ResumableDownloadUnavailable("unusable metadata for %s" % start)
    return commit, etag, size


def _stream_once(url, part_path, have, timeout, chunk_size, heartbeat):
    """One request for the rest of the file, appended to `part_path`. Raises on any transport error;
    the caller decides from the file's size whether it made progress."""
    headers = {"User-Agent": DOWNLOAD_USER_AGENT, "Accept-Encoding": "identity"}
    if have:
        headers["Range"] = "bytes=%d-" % have
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if have and response.status != 206:
            have = 0  # the server ignored Range and is sending the whole file: start the file over
        elif have:
            match = re.match(r"^bytes (\d+)-", response.headers.get("Content-Range") or "")
            if not match or int(match.group(1)) != have:
                have = 0
                os.remove(part_path)
                raise OSError("the server resumed at a different offset than requested")
        with open(part_path, "ab" if have else "wb") as out:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    return
                out.write(chunk)
                heartbeat.tick()


def _sha256_of(path, chunk_size, heartbeat):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)
            heartbeat.tick()


def _fetch_blob(url, blob_path, etag, size, retries, sleep, chunk_size, timeout, heartbeat):
    """Bring `blob_path` into existence as exactly the advertised file, resuming `<blob>.part`."""
    part_path = blob_path + ".part"
    failures = 0  # consecutive failed attempts that did not get past `best`
    # The most bytes this call has ever held. Progress is measured against it, never against the
    # file as the last attempt found it: an attempt that deletes the partial file (a 416) and a next
    # one that rewrites the same bytes would otherwise each look like progress, reset the budget,
    # and retry forever — which the first run against the live Hub did.
    best = os.path.getsize(part_path) if os.path.exists(part_path) else 0
    while True:
        have = os.path.getsize(part_path) if os.path.exists(part_path) else 0
        if have > size:
            os.remove(part_path)
            have = 0
        if have < size:
            problem = None
            try:
                _stream_once(url, part_path, have, timeout, chunk_size, heartbeat)
            except urllib.error.HTTPError as error:
                if error.code in (401, 403, 404):
                    raise ModelDownloadError("HTTP %d downloading %s" % (error.code, url))
                if error.code == 416 and os.path.exists(part_path):
                    os.remove(part_path)  # the partial file no longer matches the source
                problem = error
            except _TRANSIENT_ERRORS as error:
                if getattr(error, "errno", None) == errno.ENOSPC:
                    # Retrying a full disk five times with back-off only delays the one message
                    # that helps; the partial file stays, and a later attempt resumes it.
                    raise ModelDownloadError("there is not enough free disk space for the dictation model; "
                                             "free some space and try again")
                problem = error
            now = os.path.getsize(part_path) if os.path.exists(part_path) else 0
            if now < size:
                if now > best:
                    best, failures = now, 0
                else:
                    failures += 1
                if failures > retries:
                    raise ModelDownloadError(
                        "the model download stopped at %d of %d bytes: %s" % (now, size, problem or "short read")
                    )
                sleep(1 if failures == 0 else min(2 ** failures, 10))
                continue
        break
    # A file that is the wrong size, or hashes wrong, is not evidence of anything: keeping it would
    # resume from bytes that may be corrupt, so it goes and the next attempt starts clean. The hub
    # advertises an LFS/Xet file's sha256 as its ETag; a plain git file's ETag is a sha1 that only its
    # size can vouch for.
    if os.path.getsize(part_path) != size or (
        _SHA256_HEX.match(etag) and _sha256_of(part_path, chunk_size, heartbeat) != etag
    ):
        os.remove(part_path)
        raise ModelDownloadError("the downloaded model did not match its published size and checksum and was discarded")
    os.replace(part_path, blob_path)


def _link_snapshot_file(repo_cache, commit, filename, etag):
    blob_path = os.path.join(repo_cache, "blobs", etag)
    link = os.path.join(repo_cache, "snapshots", commit, filename)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    target = os.path.relpath(blob_path, os.path.dirname(link))
    if os.path.islink(link) and os.readlink(link) == target and os.path.exists(link):
        return
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(target, link)


def _write_ref(repo_cache, revision, commit):
    refs = os.path.join(repo_cache, "refs")
    os.makedirs(refs, exist_ok=True)
    temporary = os.path.join(refs, ".%s.%d.tmp" % (revision, os.getpid()))
    with open(temporary, "w") as handle:
        handle.write(commit)
    os.replace(temporary, os.path.join(refs, revision))


def ensure_dictation_model(mlx_repo, hub_dir, endpoint=None, heartbeat=None, retries=DOWNLOAD_RETRIES,
                           sleep=time.sleep, chunk_size=DOWNLOAD_CHUNK_BYTES,
                           timeout=DOWNLOAD_REQUEST_TIMEOUT_SECONDS, files=DICTATION_MODEL_FILES):
    """Complete the model's hub cache, resuming whatever an earlier attempt left. Every file is
    resolved at one commit; `refs/main` is written last, so an unfinished model is never advertised.

    Raises `ModelDownloadError` when the transfer fails (partial bytes stay), and
    `ResumableDownloadUnavailable` when it could not begin (nothing was touched)."""
    endpoint = (endpoint or os.environ.get("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
    heartbeat = heartbeat or DownloadHeartbeat()
    repo_cache = os.path.join(hub_dir, "models--" + mlx_repo.replace("/", "--"))

    commit, first_etag, first_size = _file_metadata(endpoint, mlx_repo, "main", files[0], timeout)
    metadata = {files[0]: (first_etag, first_size)}
    for name in files[1:]:
        _, etag, size = _file_metadata(endpoint, mlx_repo, commit, name, timeout)
        metadata[name] = (etag, size)

    blobs = os.path.join(repo_cache, "blobs")
    os.makedirs(blobs, exist_ok=True)
    wanted_parts = set(etag + ".part" for etag, _ in metadata.values())
    for leftover in os.listdir(blobs):
        # The library never reuses its own `.incomplete` files, and a `.part` for an etag the hub no
        # longer serves cannot be resumed; either can be 1.6 GB. Completed blobs are never touched.
        if leftover.endswith(".incomplete") or (leftover.endswith(".part") and leftover not in wanted_parts):
            try:
                os.remove(os.path.join(blobs, leftover))
            except OSError:
                pass

    for name in files:
        etag, size = metadata[name]
        blob_path = os.path.join(blobs, etag)
        if not (os.path.isfile(blob_path) and os.path.getsize(blob_path) == size):
            _fetch_blob(_resolve_url(endpoint, mlx_repo, commit, name), blob_path, etag, size,
                        retries, sleep, chunk_size, timeout, heartbeat)
        _link_snapshot_file(repo_cache, commit, name, etag)
    _write_ref(repo_cache, "main", commit)


def hub_snapshot_download(mlx_repo, hub_dir, heartbeat):
    """The library's own downloader, used only when the resumable path could not begin. It cannot
    resume, but it reports progress through the same heartbeat so the app does not stop it early."""
    from huggingface_hub import snapshot_download
    from tqdm.auto import tqdm as base_tqdm

    class _Reporting(base_tqdm):
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = True
            kwargs.pop("name", None)
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            heartbeat.tick()
            return super().update(n)

    snapshot_download(
        repo_id=mlx_repo,
        cache_dir=hub_dir,
        allow_patterns=list(DICTATION_MODEL_FILES),
        tqdm_class=_Reporting,
    )


def download_dictation_model(mlx_repo, hub_dir, emit=emit_download_report, fallback=hub_snapshot_download,
                             **options):
    """The first-run download, bracketed by the reports the app reads. The closing report is always
    sent, so a failure cannot leave the app waiting in "no progress for N seconds" mode."""
    heartbeat = DownloadHeartbeat(emit)
    emit(True)
    try:
        try:
            ensure_dictation_model(mlx_repo, hub_dir, heartbeat=heartbeat, **options)
        except ResumableDownloadUnavailable as unavailable:
            sys.stderr.write("resumable model download unavailable (%s); using the library's\n" % unavailable)
            fallback(mlx_repo, hub_dir, heartbeat)
    finally:
        emit(False)


# WhisperMeet's capture format, from DictationCaptureLimits.sampleRate / WAVWriter: 16-bit PCM,
# mono, 16 kHz. Kept as a named constant so the fast path below and the app stay tied together.
DICTATION_SAMPLE_RATE = 16_000


def conforming_pcm16_frames(path: str, sample_rate: int = DICTATION_SAMPLE_RATE):
    """Raw little-endian int16 frames when `path` is ALREADY mono/16-bit/`sample_rate` PCM, else None.

    `mlx_whisper.load_audio` forks an `ffmpeg` process per request to down-mix and resample
    (site-packages/mlx_whisper/audio.py:41-59) — 27.6 ms median for a 3.1 s clip on an M-series Mac.
    Quick Dictation's own recorder writes exactly the target format, so that work is pure overhead
    on every single dictation. Returning None (never raising) keeps this a strict fast path: any
    clip that is not already conforming — an imported file, a future format change, a truncated
    write — falls through to the real decoder, which also owns the error message for a bad clip.
    """
    try:
        with contextlib.closing(wave.open(path, "rb")) as handle:
            if (
                handle.getnchannels(),
                handle.getsampwidth(),
                handle.getframerate(),
            ) != (1, 2, sample_rate):
                return None
            return handle.readframes(handle.getnframes())
    except Exception:
        return None


# F210: the temperature-fallback ladder `mlx_whisper.transcribe` applies, replicated so the
# single-window path below behaves identically. Read from the installed 0.4.3
# (`transcribe.py:67-70`, `:207-245`) rather than assumed.
#
# **Not pinned by a test (F490).** This comment used to claim
# `test_the_ladder_matches_the_installed_transcribe` "pins" these constants "so a runtime upgrade
# that changes them fails a test" — false: that test compares these constants with itself (a
# literal copy of the same four numbers) and never imports mlx_whisper, so it passes identically
# whether mlx-whisper is 0.4.3, a later release that moves the ladder, or not installed at all.
# What actually keeps the fast path honest is EXPECTED_MLX_WHISPER_VERSION below: a version
# mismatch declines the fast path in `transcribe_single_window` rather than silently diverging
# from `mlx_whisper.transcribe`'s real behaviour.
FALLBACK_TEMPERATURES = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
COMPRESSION_RATIO_THRESHOLD = 2.4
LOGPROB_THRESHOLD = -1.0
NO_SPEECH_THRESHOLD = 0.6

# The mlx-whisper version FALLBACK_TEMPERATURES and the thresholds above were derived from
# (F490). setup-local-whisper.sh pins this exact version; `transcribe_single_window` also checks
# it at runtime, so a fallback/dev install that resolved a different mlx-whisper — or a future pin
# bump nobody re-derived the ladder against — declines the fast path instead of reusing a replica
# of internals that may no longer match.
EXPECTED_MLX_WHISPER_VERSION = "0.4.3"


def installed_mlx_whisper_version():
    """The installed mlx-whisper's version string, or None if it cannot be determined.

    `importlib.metadata` rather than `mlx_whisper.__version__`: mlx_whisper does not export the
    latter as of 0.4.3, and the installed-package metadata is what actually determines behaviour
    regardless of what any module attribute says.
    """
    try:
        from importlib.metadata import PackageNotFoundError, version
        try:
            return version("mlx-whisper")
        except PackageNotFoundError:
            return None
    except Exception:  # pragma: no cover - defensive; never worth failing a dictation over
        return None


def needs_temperature_fallback(compression_ratio, avg_logprob, no_speech_prob) -> bool:
    """Whether to retry at a higher temperature — `transcribe.py:226-241`, in order.

    The `no_speech` clause comes LAST and sets the flag back to False, so a silent window is
    accepted rather than retried six times. Order is load-bearing and the reason this is a
    function: written as a single boolean expression it reads as an `and`, which it is not.
    """
    needs = False
    if compression_ratio > COMPRESSION_RATIO_THRESHOLD:
        needs = True                     # too repetitive
    if avg_logprob < LOGPROB_THRESHOLD:
        needs = True                     # average log probability too low
    if no_speech_prob > NO_SPEECH_THRESHOLD:
        needs = False                    # silence
    return needs


def skips_window_as_silence(no_speech_prob, avg_logprob) -> bool:
    """Whether `transcribe` drops this window's text as no speech — `transcribe.py:301-315` (F449).

    Runs AFTER the ladder, on the result the ladder settled on. A window is skipped when
    `no_speech_prob > NO_SPEECH_THRESHOLD`, unless `avg_logprob > LOGPROB_THRESHOLD` says the decode
    was confident anyway; both comparisons are strict, as upstream's are. A clip whose only window
    is skipped comes back from `transcribe` as empty text, which the app shows as "Didn't catch
    that" instead of pasting anything. F210's single-window path replicated the ladder and not
    this check, so for any window the rule skips it returned the decoder's guess instead of "".

    What this restores is parity, not a silence detector. Measured against the installed
    large-v3-turbo on seventeen synthetic silence and noise clips (the F449 log entry), that model
    reported a no_speech_prob of 0.000000 on every one, so the rule — upstream's as much as this
    copy — skipped none of them and both paths returned "Thank you." for digital silence.
    """
    should_skip = no_speech_prob > NO_SPEECH_THRESHOLD
    if avg_logprob > LOGPROB_THRESHOLD:
        should_skip = False
    return should_skip


def transcribe_single_window(mlx_whisper, mlx, audio, mlx_repo, language, initial_prompt):
    """One encoder pass, shared by language ID and every decode attempt (F210).

    With `language=None` — the app's default, so this is every Automatic dictation —
    `mlx_whisper.transcribe` computes the mel once and then calls
    `model.detect_language(mel_segment)` (`transcribe.py:173`), whose encoder pass is thrown away
    before the decode loop encodes the same segment again. **Measured on this Mac against the
    installed 0.4.3:** 1303 ms for `transcribe(language=None)` against 678 ms for
    `transcribe(language="en")`, with `detect_language` alone accounting for 623 ms. Roughly half
    the warm request time for a typical 3-second clip.

    The saving comes from `DecodingTask._get_audio_features` (`decoding.py:537-548`), which skips
    the encoder when handed something already shaped `(n_audio_ctx, n_audio_state)`. So the encoder
    runs once here and `model.decode` reuses its output — for the language ID it performs
    internally (`decoding.py:630`), and for each temperature in the ladder.

    **Returns None rather than raising for anything it cannot handle**, so the caller falls back to
    `transcribe`. Same principle as the raw-frames audio fast path below it: a fast path that cannot
    be taken must never fail a dictation.

    Single-window only. Dictation clips are seconds long, but a longer clip needs `transcribe`'s
    seek loop, conditioning between windows and segment assembly, none of which is replicated here.

    **Declines (returns None) on any mlx-whisper other than EXPECTED_MLX_WHISPER_VERSION (F490).**
    The ladder and thresholds above were read from that installed version's source, not derived
    generically — a different version may have moved them, and this fast path would then silently
    diverge from what `mlx_whisper.transcribe` (called below on any None) actually does.
    """
    if installed_mlx_whisper_version() != EXPECTED_MLX_WHISPER_VERSION:
        return None
    try:
        from mlx_whisper.audio import (
            N_FRAMES,
            N_SAMPLES,
            log_mel_spectrogram,
            pad_or_trim,
        )
        from mlx_whisper.decoding import DecodingOptions
        from mlx_whisper.transcribe import ModelHolder
    except Exception:
        return None

    try:
        model = ModelHolder.get_model(mlx_repo, mlx.float16)
        if language is None and not model.is_multilingual:
            # `transcribe.py:164-165` forces English for a non-multilingual model instead of
            # detecting. Nothing here would be wrong, but there is no pass to save either.
            language = "en"

        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        content_frames = mel.shape[-2] - N_FRAMES
        if content_frames <= 0 or content_frames > N_FRAMES:
            return None

        # EXACTLY `transcribe.py`'s slice (`:264-267`): the content frames, then zero-padded to a
        # full window. NOT `pad_or_trim(mel, N_FRAMES)`, which keeps the appended silence that
        # `padding=N_SAMPLES` added and decodes to different text — verified, and it is what made
        # the first version of this change produce "会议记要" where transcribe produces "会议纪要".
        # `transcribe`'s own language detection at `:172` uses that other segment, which is an
        # inconsistency upstream rather than here; detecting from the decode segment is what makes
        # one pass possible, and it agreed with transcribe on all ten bench clips.
        segment = mel[0:min(N_FRAMES, content_frames)]
        segment = pad_or_trim(segment, N_FRAMES, axis=-2).astype(mlx.float16)
        features = model.encoder(segment[None])

        result = None
        for temperature in FALLBACK_TEMPERATURES:
            decoded = model.decode(
                features,
                DecodingOptions(
                    task="transcribe",          # never translate
                    language=language,          # None means detect, for free, from `features`
                    temperature=temperature,
                    # A string, which `_get_initial_tokens` encodes as
                    # `tokenizer.encode(" " + prompt.strip())` (`decoding.py:494-498`) — byte for
                    # byte what `transcribe.py:258` does with `initial_prompt`.
                    prompt=initial_prompt,
                    fp16=True,
                ),
            )
            result = decoded[0] if isinstance(decoded, list) else decoded
            if not needs_temperature_fallback(
                result.compression_ratio, result.avg_logprob, result.no_speech_prob
            ):
                break
        if result is None:
            return None
        text = result.text.strip()
        if skips_window_as_silence(result.no_speech_prob, result.avg_logprob):
            # F449: what `transcribe` returns for a clip whose one window it skipped. The language
            # and the score are still reported — the score is the reason the text is empty.
            text = ""
        return {
            "text": text,
            "language": result.language,
            "noSpeechProb": result.no_speech_prob,
        }
    except Exception:
        return None


def prewarm(transcribe, audio, mlx_repo: str) -> None:
    """One throwaway decode so the model and its Metal kernels are resident before readiness.

    `temperature=0.0` is load-bearing. Whisper's default is a six-temperature fallback ladder that
    re-decodes the clip whenever the result trips its compression-ratio / logprob thresholds — which
    pure digital silence always does — so the default paid five extra full decodes for a transcript
    that is discarded. Measured on the installed runtime with the model already resident:
    2631 ms default vs 1276 ms greedy, i.e. ~1.35 s off every helper start.

    This is still the exact request code path (same task, same model), so it loads the model into
    mlx_whisper's ModelHolder cache and compiles the kernels a real request will use. Only the
    fallback ladder — which no request reaches unless its own decode is poor — is skipped.

    verbose MUST be None, not False. Whisper documents False as "minimal details", and the code
    guards its prints with `if verbose is not None` — so False still writes "Detected language: X"
    to STDOUT, which is this protocol's wire. Only None is silent.
    """
    transcribe(
        audio,
        path_or_hf_repo=mlx_repo,
        task="transcribe",
        temperature=0.0,
        verbose=None,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mlx-repo", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--model-dir", required=True)
    # Legacy openai-whisper arg: accepted but ignored so older callers don't crash.
    parser.add_argument("--model", default=None)
    args = parser.parse_args()

    # Cache MLX/HF model weights under the app's local support dir (stays 100% local).
    # Must be set BEFORE importing mlx_whisper / huggingface_hub.
    hf_home = os.path.join(args.model_dir, "hf")
    os.makedirs(hf_home, exist_ok=True)
    os.environ["HF_HOME"] = hf_home

    # Once the model is cached locally, forbid ALL network access — huggingface_hub otherwise
    # issues a metadata/HEAD request to huggingface.co on every start even when fully cached.
    # The meeting path never phones home once its model exists; match that. On the very first
    # run the model isn't cached yet, so we allow that one-time download, after which every
    # subsequent start is fully offline (and works air-gapped).
    hub_dir = os.path.join(hf_home, "hub")
    if offline_requested():
        # The caller has already forbidden the network (HF_HUB_OFFLINE): there is nothing to
        # download and nothing to decide, and the cache is left exactly as it is.
        pass
    elif model_fully_cached(hub_dir, args.mlx_repo):
        go_offline()
    else:
        # No cache, or an unfinished one — a download that was interrupted (kill, quit/disable
        # mid-download, network drop, disk-full). Forcing HF_HUB_OFFLINE here would wedge dictation
        # permanently, since offline mode blocks the very HTTP the partial cache needs to finish.
        # Complete it here, with the network allowed, before the model is loaded. F522: the old
        # answer was to delete the whole cache and let mlx_whisper download from zero; this keeps
        # every finished file and resumes the partial one (see `ensure_dictation_model`), and tells
        # the app while bytes are arriving so it does not stop a slow download on a flat timer.
        try:
            download_dictation_model(args.mlx_repo, hub_dir)
        except Exception as error:
            # `downloadFailed` is what tells the app this is the model's download and not "this helper
            # cannot run here" (F827): the first is retried (the partial file resumes), the second
            # falls back to the batch engine.
            sys.stdout.write(json.dumps({
                "error": "model download failed: " + str(error),
                "downloadFailed": True,
            }) + "\n")
            sys.stdout.flush()
            return 1
        if model_fully_cached(hub_dir, args.mlx_repo):
            go_offline()

    import mlx.core as mx
    import mlx_whisper  # imported after arg parse so --help is instant
    # numpy is a hard dependency of mlx_whisper in the installed runtime, but importing it
    # unconditionally would make this helper unstartable wherever it is absent. It powers only an
    # optional fast path, so treat it as optional: without it every clip takes the normal decoder.
    try:
        import numpy as np
    except Exception:  # pragma: no cover - exercised by the no-numpy helper protocol test
        np = None

    # Pre-warm: run one throwaway transcribe on a short silent buffer. This is the exact
    # request code path, so it loads the model into mlx_whisper's ModelHolder cache (fp16
    # by default, matching real requests) and compiles the MLX kernels. Only after this
    # returns is {"ready": true} genuinely resident.
    #
    # verbose MUST be None, not False. Whisper documents False as "minimal details", and the
    # code guards its prints with `if verbose is not None` — so False still writes
    # "Detected language: X" to STDOUT, which is this protocol's wire. Only None is silent.
    try:
        prewarm(
            mlx_whisper.transcribe,
            mx.zeros(1600, dtype=mx.float32),  # 0.1s of silence at 16 kHz
            args.mlx_repo,
        )
    except Exception as error:  # pragma: no cover - warm failure is fatal to the helper
        sys.stdout.write(json.dumps({"error": "warm-up failed: " + str(error)}) + "\n")
        sys.stdout.flush()
        return 1

    # Signal readiness only after the model is resident.
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            # Hand the model samples directly when the clip is already in its target format,
            # skipping load_audio's per-request ffmpeg fork. The conversion mirrors load_audio's
            # own line exactly (int16 -> float32 / 32768.0), so samples stay byte-identical.
            wav_path = request["wavPath"]
            audio = wav_path
            frames = conforming_pcm16_frames(wav_path) if np is not None else None
            if frames:
                try:
                    audio = (
                        mx.array(np.frombuffer(frames, np.int16))
                        .flatten()
                        .astype(mx.float32) / 32768.0
                    )
                except Exception:
                    # A fast path that cannot be taken must never fail a dictation: fall back to
                    # the decoder, which is also the one that owns errors for an unreadable clip.
                    audio = wav_path
            # F210: one encoder pass instead of two on the Automatic path, which is the default
            # and therefore every dictation. Returns None for anything it will not handle — a long
            # clip, a runtime whose internals moved — and the full `transcribe` below then runs
            # exactly as before.
            response = transcribe_single_window(
                mlx_whisper,
                mx,
                audio,
                args.mlx_repo,
                request.get("language"),
                request.get("initialPrompt"),
            )
            if response is None:
                result = mlx_whisper.transcribe(
                    audio,
                    path_or_hf_repo=args.mlx_repo,
                    task="transcribe",  # never translate
                    language=request.get("language"),
                    initial_prompt=request.get("initialPrompt"),
                    verbose=None,  # see the warm-up call: False is NOT silent, it prints to stdout
                )
                # Report the lowest per-segment no_speech_prob (the most speech-like segment). The
                # app uses it to tell a real dictation from a silence-driven prompt echo; taking the
                # min biases toward keeping — a clip is only "silence" if EVERY segment looks like
                # silence. The single-window path has exactly one window, so its own
                # `no_speech_prob` is already that minimum.
                segments = result.get("segments") or []
                probs = [
                    s.get("no_speech_prob")
                    for s in segments
                    if s.get("no_speech_prob") is not None
                ]
                response = {
                    "text": result.get("text", "").strip(),
                    "language": result.get("language"),
                    "noSpeechProb": min(probs) if probs else None,
                }
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
