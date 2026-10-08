#!/usr/bin/env python3
"""F522 — the first Quick Dictation model download restarts from zero after any interruption.

Run: python3 Scripts/tests/test_dictation_model_download.py

`whisper_dictate_server.py` used to `shutil.rmtree` the whole model cache whenever it found the
download unfinished, and the installed `huggingface_hub` (1.24.0, the version measured) would not
have resumed it anyway: each attempt writes to a fresh `blobs/<etag>.<random>.incomplete`
(`file_download.py:1908`) that is deleted when the attempt raises (`:1946-1949`) and orphaned when it
is killed, and nothing ever seeds a later attempt from it. So the helper now downloads the two files
itself, with HTTP `Range`, into a partial file named for the blob it will become.

These tests run the helper's real downloader against a local HTTP server that behaves like the Hub
for the paths involved: `resolve/` HEAD/GET, `config.json`'s relative same-host redirect, and the
LFS-style redirect to another host's CDN path that honours `Range` (the shapes were read off the live
Hub; the first version of this fake modelled them wrongly and the tests passed regardless, see F522's
log entry). No network, no `huggingface_hub`, no installed runtime: plain system python3, so the
routine gate runs them everywhere.
"""

import hashlib
import http.server
import importlib.util
import json
import os
import shutil
import tempfile
import threading
import unittest

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "whisper_dictate_server.py")
_spec = importlib.util.spec_from_file_location("whisper_dictate_server", _SCRIPT)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)

REPO = "mlx-community/whisper-large-v3-turbo"
COMMIT = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
CONFIG = b'{"n_mels": 128}\n'
CONFIG_ETAG = hashlib.sha1(CONFIG).hexdigest()  # git blob ids are sha1: the Hub's ETag cannot vouch for content
CONFIG_SHA256 = hashlib.sha256(CONFIG).hexdigest()
WEIGHTS = bytes((i * 31 + 7) % 251 for i in range(300_000))
WEIGHTS_SHA256 = hashlib.sha256(WEIGHTS).hexdigest()  # what the Hub advertises as X-Linked-ETag for LFS/Xet
# F830: what the helper is pinned to for these tests, in place of F483's real pin (whose hashes are the
# real 1.6 GB model's). Installed as the helper's pin table in `DownloaderTestCase.setUp`.
PIN = {"revision": COMMIT, "sha256": {"config.json": CONFIG_SHA256, "weights.safetensors": WEIGHTS_SHA256}}


class FakeHub:
    """The paths the downloader talks to, with the shapes the real Hub has (read off the live Hub
    for these two files, 2026-10-06): `config.json` answers `resolve/` with a 307 to a RELATIVE
    `/api/resolve-cache/...` whose own `Content-Length` is the redirect body's (276, not the file's
    268) and which carries no `X-Linked-Size` — the real size is on the 200 behind it;
    `weights.safetensors` answers with a 302 to an ABSOLUTE CDN URL whose headers carry the commit,
    the sha256 and the size, and the CDN path honours `Range`."""

    def __init__(self):
        hub = self
        self.weights = WEIGHTS
        self.config = CONFIG            # F830: the bytes served for config.json, under CONFIG_ETAG regardless
        self.main_commit = COMMIT       # F830: the commit `main` resolves to; a commit revision resolves to itself
        self.revisions = []             # F830: the revision of every resolve/ request
        self.advertised_extra = 0       # bytes the Hub claims the weights have beyond the ones it serves
        self.advertised_sha = WEIGHTS_SHA256
        self.ignore_range = False       # answer a Range request with the whole file and a 200
        self.drop_after = []            # bytes to send before cutting the connection, one per request
        self.served = 0                 # weight bytes put on the wire, across every request
        self.ranges = []                # Range header of every weights request that reached the CDN
        self.requests = []              # (method, path)
        self.fail_head_with = None      # status for every HEAD to resolve/, to model a Hub that stays down
        self.fail_heads = []            # F828: statuses for the next HEADs to resolve/ only, one each
        self.unusable_metadata = False  # F828: answer with no X-Repo-Commit, which the downloader cannot use
        # F829: how the CDN answers the next Range requests, one entry each — 416, "wrong-offset" (a
        # 206 that resumes at byte 0), or "portal" (a 200 whose body is not the file at all).
        self.range_replies = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _resolve(self, head):
                hub.requests.append((self.command, self.path))
                failing = hub.fail_heads.pop(0) if head and hub.fail_heads else hub.fail_head_with if head else None
                if failing is not None:
                    self.send_response(failing)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                revision = self.path.split("/resolve/", 1)[1].split("/", 1)[0] if "/resolve/" in self.path else None
                hub.revisions.append(revision)
                commit = None if hub.unusable_metadata else (hub.main_commit if revision == "main" else revision)
                name = self.path.split("?")[0].rsplit("/", 1)[-1]
                if name == "config.json":
                    redirect_body = b"x" * 276
                    self.send_response(307)
                    self.send_header(
                        "Location",
                        "/api/resolve-cache/models/mlx-community/whisper-large-v3-turbo/%s/config.json?etag=1" % COMMIT,
                    )
                    if commit:
                        self.send_header("X-Repo-Commit", commit)
                    self.send_header("X-Linked-ETag", '"%s"' % CONFIG_ETAG)
                    self.send_header("Content-Length", str(len(redirect_body)))
                    self.end_headers()
                    if not head:
                        self.wfile.write(redirect_body)
                elif name == "weights.safetensors":
                    self.send_response(302)
                    # `localhost`, not 127.0.0.1: a different host from the endpoint, as the real CDN is
                    self.send_header("Location", "http://localhost:%d/cdn/weights" % hub.port)
                    if commit:
                        self.send_header("X-Repo-Commit", commit)
                    self.send_header("X-Linked-ETag", '"%s"' % hub.advertised_sha)
                    self.send_header("X-Linked-Size", str(len(hub.weights) + hub.advertised_extra))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            def _small_file(self, head):
                hub.requests.append((self.command, self.path))
                self.send_response(200)
                self.send_header("ETag", '"%s"' % CONFIG_ETAG)
                if not hub.unusable_metadata:
                    self.send_header("X-Repo-Commit", COMMIT)
                self.send_header("Content-Length", str(len(hub.config)))
                self.end_headers()
                if not head:
                    self.wfile.write(hub.config)

            def do_HEAD(self):
                if self.path.startswith("/api/resolve-cache/"):
                    self._small_file(head=True)
                elif self.path.startswith("/cdn/"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(hub.weights)))
                    self.end_headers()
                else:
                    self._resolve(head=True)

            def do_GET(self):
                if self.path.startswith("/api/resolve-cache/"):
                    self._small_file(head=False)
                    return
                if not self.path.startswith("/cdn/"):
                    self._resolve(head=False)
                    return
                hub.requests.append((self.command, self.path))
                range_header = self.headers.get("Range")
                hub.ranges.append(range_header)
                scripted = hub.range_replies.pop(0) if range_header and hub.range_replies else None
                if scripted == 416:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % len(hub.weights))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if scripted == "portal":
                    page = b"<html>sign in to the network</html>" * 8000  # 280 000 bytes, not the file
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(page)))
                    self.end_headers()
                    self.wfile.write(page)
                    return
                if scripted == "wrong-offset":
                    self.send_response(206)
                    self.send_header("Content-Length", str(len(hub.weights)))
                    self.send_header("Content-Range", "bytes 0-%d/%d" % (len(hub.weights) - 1, len(hub.weights)))
                    self.end_headers()
                    self.wfile.write(hub.weights)
                    hub.served += len(hub.weights)
                    return
                start = 0
                status = 200
                if range_header and not hub.ignore_range:
                    start = int(range_header.split("=")[1].split("-")[0])
                    status = 206
                if start >= len(hub.weights):
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % len(hub.weights))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                body = hub.weights[start:]
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                if status == 206:
                    self.send_header(
                        "Content-Range", "bytes %d-%d/%d" % (start, len(hub.weights) - 1, len(hub.weights))
                    )
                self.end_headers()
                limit = hub.drop_after.pop(0) if hub.drop_after else None
                if limit is not None:
                    self.wfile.write(body[:limit])
                    hub.served += min(limit, len(body))
                    self.wfile.flush()
                    self.close_connection = True
                    return
                self.wfile.write(body)
                hub.served += len(body)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.endpoint = "http://127.0.0.1:%d" % self.port
        # A short poll interval: `shutdown()` waits one out, and 0.5 s a test is most of the runtime.
        threading.Thread(target=lambda: self.httpd.serve_forever(poll_interval=0.01), daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class Killed(BaseException):
    """The helper process dying. The downloader sleeps after every failed attempt, so a sleep that
    raises this ends the run there, with whatever partial file the attempt left — the honest model
    of a kill, quit or crash, which `retries=0` is not (an attempt that brought bytes in never
    counts against the retry budget)."""


def die(_seconds):
    raise Killed()


# How a test's attempt ends when it made no progress: with `retries=0` the downloader gives up at once
# (ModelDownloadError); an attempt that brought bytes in sleeps first, and `die` ends it there.
FAILED_ATTEMPT = (Killed, server.ModelDownloadError)


class Beats:
    """Records every tick the downloader makes, so a test can say bytes were flowing."""

    def __init__(self):
        self.count = 0

    def tick(self, *_position):
        self.count += 1


class DownloaderTestCase(unittest.TestCase):
    def setUp(self):
        self.hub = FakeHub()
        self.addCleanup(self.hub.close)
        saved_pins = getattr(server, "PINNED_DICTATION_MODELS", None)
        server.PINNED_DICTATION_MODELS = {REPO: PIN}
        self.addCleanup(setattr, server, "PINNED_DICTATION_MODELS", saved_pins)
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f522-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.hub_dir = os.path.join(self.tmp, "hf", "hub")
        self.repo_cache = os.path.join(self.hub_dir, "models--" + REPO.replace("/", "--"))
        self.beats = Beats()

    def bounded_sleep(self, _seconds):
        """Every retry sleeps first, so counting them bounds a retry loop that never ends — which a
        test must report as a failure, not hang the suite on."""
        self.sleeps_taken = getattr(self, "sleeps_taken", 0) + 1
        if self.sleeps_taken > 200:
            raise AssertionError("the downloader is retrying forever")

    def download(self, **overrides):
        options = dict(
            endpoint=self.hub.endpoint,
            heartbeat=self.beats,
            retries=0,
            sleep=self.bounded_sleep,
            chunk_size=16 * 1024,
        )
        options.update(overrides)
        return server.ensure_dictation_model(REPO, self.hub_dir, **options)

    def blobs(self):
        directory = os.path.join(self.repo_cache, "blobs")
        return sorted(os.listdir(directory)) if os.path.isdir(directory) else []

    def read(self, *parts):
        with open(os.path.join(self.repo_cache, *parts), "rb") as handle:
            return handle.read()

    def weights_part(self):
        return os.path.join(self.repo_cache, "blobs", WEIGHTS_SHA256 + ".part")

    def interrupt_after(self, received):
        """A first attempt that is cut after `received` weight bytes, and a process that then dies:
        the partial file the next attempt is meant to resume."""
        self.hub.drop_after = [received]
        with self.assertRaises(Killed):
            self.download(sleep=die)
        self.assertEqual(os.path.getsize(self.weights_part()), received)

    def library(self, calls, weights=WEIGHTS):
        """A stand-in for `hub_snapshot_download` that lays the files out as the library does (blobs
        named by etag, relative links in the snapshot), ignoring any `.part`. Asked for a commit, the
        library writes no `refs/` at all (F483 measured it), so neither does this."""

        def fallback(repo, hub_dir, heartbeat, revision=None):
            calls.append(repo)
            self.fallback_revisions = getattr(self, "fallback_revisions", []) + [revision]
            blobs = os.path.join(self.repo_cache, "blobs")
            snapshot = os.path.join(self.repo_cache, "snapshots", COMMIT)
            os.makedirs(blobs, exist_ok=True)
            os.makedirs(snapshot, exist_ok=True)
            for name, etag, data in (("config.json", CONFIG_ETAG, CONFIG),
                                     ("weights.safetensors", WEIGHTS_SHA256, weights)):
                with open(os.path.join(blobs, etag), "wb") as handle:
                    handle.write(data)
                link = os.path.join(snapshot, name)
                if not os.path.lexists(link):
                    os.symlink(os.path.join("..", "..", "blobs", etag), link)

        return fallback


class ResumeTests(DownloaderTestCase):
    def test_a_full_download_lands_in_the_hub_cache_layout(self):
        """What `try_to_load_from_cache` and `snapshot_download` read offline: blobs named by etag,
        a relative symlink per file under snapshots/<commit>/, and refs/main naming the commit."""
        self.download()

        self.assertEqual(self.read("blobs", WEIGHTS_SHA256), WEIGHTS)
        link = os.path.join(self.repo_cache, "snapshots", COMMIT, "weights.safetensors")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.readlink(link), os.path.join("..", "..", "blobs", WEIGHTS_SHA256))
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)
        self.assertEqual(self.read("snapshots", COMMIT, "config.json"), CONFIG)
        self.assertEqual(self.read("refs", "main").decode(), COMMIT)
        self.assertEqual(self.blobs(), sorted([WEIGHTS_SHA256, CONFIG_ETAG]))  # no partial file left

    def test_an_interrupted_download_resumes_from_the_bytes_already_on_disk(self):
        """The F522 scenario. Attempt one is cut after 120 000 bytes and the process dies. Attempt
        two must ask for `bytes=120000-` and be sent only the rest — not start again, which is what
        a fresh `snapshot_download` does."""
        self.hub.drop_after = [120_000]
        with self.assertRaises(Killed):
            self.download(sleep=die)
        partial = [name for name in self.blobs() if name.endswith(".part")]
        self.assertEqual(len(partial), 1, "the partial file must survive the failure")
        self.assertEqual(os.path.getsize(os.path.join(self.repo_cache, "blobs", partial[0])), 120_000)
        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")),
                         "an unfinished model must not be advertised")

        self.download()

        self.assertEqual(self.hub.ranges[-1], "bytes=120000-")
        self.assertEqual(self.hub.served, len(WEIGHTS), "the second attempt was sent bytes it already had")
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)
        self.assertEqual([n for n in self.blobs() if n.endswith(".part")], [])

    def test_a_dropped_connection_is_resumed_inside_one_attempt(self):
        self.hub.drop_after = [50_000, 90_000]
        self.download(retries=3)

        self.assertEqual(self.hub.ranges, [None, "bytes=50000-", "bytes=140000-"])
        self.assertEqual(self.hub.served, len(WEIGHTS))
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_run_of_failures_with_no_bytes_gives_up_after_the_retry_budget(self):
        self.hub.drop_after = [0, 0, 0, 0, 0]
        sleeps = []
        with self.assertRaises(server.ModelDownloadError):
            self.download(retries=2, sleep=sleeps.append)
        self.assertEqual(len(self.hub.ranges), 3)  # the first try and two retries
        self.assertEqual(len(sleeps), 2)

    def test_a_small_file_behind_a_relative_redirect_is_sized_by_the_response_it_lands_on(self):
        """Found by running the helper against the live Hub: `config.json`'s `resolve/` answer is a 307
        to a same-host path, and ITS Content-Length (276) is the redirect body's. Taking it as the
        file's size made every download of the real model a size mismatch, forever. The library
        follows relative redirects for exactly this reason; so does the downloader."""
        self.download()

        self.assertEqual(os.path.getsize(os.path.join(self.repo_cache, "blobs", CONFIG_ETAG)), len(CONFIG))
        self.assertEqual(self.read("snapshots", COMMIT, "config.json"), CONFIG)
        followed = [path for method, path in self.hub.requests if path.startswith("/api/resolve-cache/")]
        self.assertTrue(followed, "the relative redirect was never followed")

    def test_a_hub_that_overstates_the_size_ends_the_retries_instead_of_looping(self):
        """The same live run found the loop itself. The Hub claims 10 bytes more than it serves and
        answers a Range past the end with 416; the downloader then removed the partial file, and the
        next attempt rewrote the whole file — which, measured against the file it had just removed,
        looked like progress, and reset the retry budget, every time. Progress is measured against
        the most bytes ever held, so a rewrite of what was already there is not progress. (Since F829
        a 416 no longer removes the partial at all; it is a failed attempt, and the budget ends it.)"""
        self.hub.advertised_extra = 10

        with self.assertRaises(server.ModelDownloadError):
            self.download(retries=1)

    def test_a_full_disk_stops_at_once_with_a_message_that_helps_and_keeps_the_partial_file(self):
        import errno

        real_stream = server._stream_once
        attempts = []

        def full_disk_after_some_bytes(url, part_path, have, *_rest):
            attempts.append(have)
            with open(part_path, "ab") as handle:
                handle.write(b"x" * 1000)
            raise OSError(errno.ENOSPC, "No space left on device")

        server._stream_once = full_disk_after_some_bytes
        self.addCleanup(setattr, server, "_stream_once", real_stream)
        sleeps = []
        with self.assertRaises(server.ModelDownloadError) as caught:
            self.download(retries=5, sleep=sleeps.append)

        self.assertEqual(attempts, [0], "a full disk is not retried")
        self.assertEqual(sleeps, [])
        self.assertIn("free disk space", str(caught.exception))
        self.assertEqual(len([n for n in self.blobs() if n.endswith(".part")]), 1)

    def test_a_server_that_ignores_range_restarts_the_file_cleanly(self):
        self.hub.drop_after = [70_000]
        with self.assertRaises(Killed):
            self.download(sleep=die)
        self.hub.ignore_range = True

        self.download()

        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_download_that_is_not_the_advertised_file_is_never_published(self):
        """The Hub's X-Linked-ETag is the file's sha256. Bytes that do not hash to it — a corrupt
        transfer, or a partial file whose source changed — must not become the model, and must not
        be kept for the next attempt to resume from."""
        self.hub.weights = WEIGHTS[:-1] + b"\x00"  # same length, wrong bytes
        with self.assertRaises(server.ModelDownloadError):
            self.download()

        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")))
        self.assertNotIn(WEIGHTS_SHA256, self.blobs())
        self.assertEqual([n for n in self.blobs() if n.endswith(".part")], [])

    def test_the_ref_is_written_last_so_a_half_populated_snapshot_is_never_advertised(self):
        self.hub.drop_after = [10_000]
        with self.assertRaises(Killed):
            self.download(sleep=die)
        # config.json finished before the weights failed, and is kept
        self.assertEqual(self.read("snapshots", COMMIT, "config.json"), CONFIG)
        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")))

    def test_files_already_in_the_cache_are_not_fetched_again(self):
        self.download()
        requests_before = len(self.hub.requests)
        served_before = self.hub.served
        self.download()

        self.assertEqual(self.hub.served, served_before)
        self.assertTrue(all(method == "HEAD" for method, _path in self.hub.requests[requests_before:]),
                        "an intact file should cost a metadata check and nothing else")

    def test_a_stale_partial_file_and_the_librarys_orphans_are_cleared_before_a_download(self):
        """Leaving the whole cache alone (instead of deleting it) must not leak: a partial for an
        etag the Hub no longer serves, and the `.incomplete` files the library orphans when it is
        killed (it never reuses them), can each be 1.6 GB."""
        blobs = os.path.join(self.repo_cache, "blobs")
        os.makedirs(blobs)
        stale_part = os.path.join(blobs, "0" * 64 + ".part")
        orphan = os.path.join(blobs, WEIGHTS_SHA256 + ".408d0ef8.incomplete")
        keeper = os.path.join(blobs, "1" * 40)  # a completed blob of some other revision
        for path in (stale_part, orphan, keeper):
            with open(path, "wb") as handle:
                handle.write(b"x" * 1000)

        self.download()

        self.assertFalse(os.path.exists(stale_part))
        self.assertFalse(os.path.exists(orphan))
        self.assertTrue(os.path.exists(keeper), "a completed blob is never deleted by a download")

    def test_progress_is_reported_while_bytes_arrive(self):
        self.download()
        self.assertGreater(self.beats.count, 5)

    def test_a_missing_repository_is_an_error_not_a_reason_to_fall_back(self):
        with self.assertRaises(server.ModelDownloadError):
            server.ensure_dictation_model(
                REPO, self.hub_dir, endpoint=self.hub.endpoint, heartbeat=self.beats, retries=0,
                sleep=lambda _s: None, files=("missing.bin",),
            )

    def test_an_unusable_metadata_path_means_unavailable_and_changes_nothing(self):
        self.hub.unusable_metadata = True  # a 5xx was "unusable" too until F828; it is now retried
        with self.assertRaises(server.ResumableDownloadUnavailable):
            self.download()
        self.assertFalse(os.path.exists(self.repo_cache))


class BadResponseTests(DownloaderTestCase):
    """F829 — one misbehaving response must not cost the partial file. The review of F522 showed a
    200 reply to a `Range` request cutting a 200 000-byte partial to 0 bytes before a single new byte
    had arrived (P3), and one 416 deleting it outright (P4); a 206 that resumed at the wrong offset
    deleted it too. Each is now a failed attempt like a dropped connection: the bytes on disk stay,
    and the next attempt resumes them. Only bytes shown to be wrong — the final size or sha256 check —
    are discarded."""

    def test_a_whole_file_reply_to_a_resume_request_never_shortens_the_partial(self):
        self.interrupt_after(200_000)
        self.hub.ignore_range = True

        self.hub.drop_after = [0]  # the 200 arrives, then the connection drops before any byte
        with self.assertRaises(FAILED_ATTEMPT):
            self.download(sleep=die)
        self.assertEqual(os.path.getsize(self.weights_part()), 200_000,
                         "a 200 to a Range request emptied the partial before any new byte arrived (P3)")

        self.hub.drop_after = [150_000]  # cut while it is still resending bytes already on disk
        with self.assertRaises(FAILED_ATTEMPT):
            self.download(sleep=die)
        self.assertEqual(os.path.getsize(self.weights_part()), 200_000)

        self.download()  # a whole-file reply that runs to the end completes it

        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_416_to_a_resume_request_keeps_the_partial(self):
        self.interrupt_after(120_000)
        self.hub.range_replies = [416]

        with self.assertRaises(FAILED_ATTEMPT):
            self.download(sleep=die)

        self.assertTrue(os.path.exists(self.weights_part()), "one 416 deleted the partial file (P4)")
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)
        self.download()
        self.assertEqual(self.hub.ranges[-1], "bytes=120000-", "the next attempt resumes the same bytes")
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_resume_at_the_wrong_offset_keeps_the_partial(self):
        self.interrupt_after(120_000)
        self.hub.range_replies = ["wrong-offset"]

        with self.assertRaises(FAILED_ATTEMPT):
            self.download(sleep=die)

        self.assertTrue(os.path.exists(self.weights_part()), "a 206 at another offset deleted the partial file")
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)
        self.download()
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_whole_reply_that_is_not_the_file_is_refused_before_it_touches_the_partial(self):
        """A captive portal answers anything with its own page and a 200. Its length is not the
        file's, so it is refused as a failed attempt; appended after the bytes on disk, it would have
        failed the final checksum and cost the whole partial."""
        self.interrupt_after(120_000)
        self.hub.range_replies = ["portal"]

        with self.assertRaises(FAILED_ATTEMPT):
            self.download(sleep=die)

        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)
        self.download()
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_server_that_keeps_answering_416_ends_in_an_error_with_the_partial_kept(self):
        """Never deleting on a 416 must not become retrying forever: it is a failed attempt, so the
        retry budget ends it, and the partial is still there for the next start."""
        self.interrupt_after(120_000)
        self.hub.range_replies = [416] * 10

        with self.assertRaises(server.ModelDownloadError):
            self.download(retries=2)

        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)


class MetadataFailureTests(DownloaderTestCase):
    """F828 — a network error or a 5xx on the metadata request used to mean "the resumable path is
    unavailable", which sent the download to the library's `snapshot_download`: from zero, ignoring
    the partial file, and — when it completed — leaving that same-name `.part` (up to 1.6 GB) beside
    the finished blob for good, since a cached helper never runs the resumable path's cleanup again
    and F626 keeps the folder on a Repair. A metadata failure is now retried with back-off like a
    transfer failure and then reported as a failed download, partial kept; the library is used only
    for metadata it cannot read. And a `.part` beside its published blob is removed, on either path."""

    def orchestrate(self, calls, **overrides):
        options = dict(emit=lambda *_args: None, fallback=self.library(calls), endpoint=self.hub.endpoint,
                       retries=3, sleep=self.bounded_sleep, chunk_size=16 * 1024)
        options.update(overrides)
        return server.download_dictation_model(REPO, self.hub_dir, **options)

    def test_a_metadata_request_that_fails_once_is_retried_and_the_partial_resumed(self):
        """The reviewer's suggested probe: a HEAD that 503s once."""
        self.interrupt_after(120_000)
        self.hub.fail_heads = [503]
        calls = []

        self.orchestrate(calls)

        self.assertEqual(calls, [], "one 503 sent the download to the library, from zero")
        self.assertEqual(self.hub.ranges[-1], "bytes=120000-")
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_hub_that_stays_unreachable_ends_in_a_failed_download_with_the_partial_kept(self):
        self.interrupt_after(120_000)
        self.hub.fail_head_with = 500
        calls = []
        sleeps = []

        with self.assertRaises(server.ModelDownloadError):
            self.orchestrate(calls, retries=2, sleep=sleeps.append)

        self.assertEqual(calls, [], "the library would have started from zero beside the partial")
        self.assertEqual(len(sleeps), 2, "the first request and two retries, with back-off between")
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)

    def test_a_network_error_on_the_metadata_request_is_retried_not_sent_to_the_library(self):
        self.interrupt_after(120_000)
        closed = FakeHub()
        endpoint = closed.endpoint
        closed.close()  # nothing listens there now: every connection is refused
        calls = []
        sleeps = []

        with self.assertRaises(server.ModelDownloadError):
            self.orchestrate(calls, endpoint=endpoint, retries=1, sleep=sleeps.append)

        self.assertEqual(calls, [])
        self.assertEqual(len(sleeps), 1)
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)

    def test_a_part_beside_its_published_blob_is_removed(self):
        """Probe P1: a `.part` beside a complete blob of the same etag survived a whole pass."""
        self.download()
        leftover = self.weights_part()
        with open(leftover, "wb") as handle:
            handle.write(b"x" * 1000)

        self.download()

        self.assertFalse(os.path.exists(leftover), "a .part beside its finished blob was kept")
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_after_the_librarys_download_completes_no_part_is_left_beside_its_blob(self):
        """The other half of P1: the library completes the model and ignores the `.part`; nothing
        afterwards would ever remove it, because the next start finds the model cached."""
        self.interrupt_after(120_000)
        orphan = os.path.join(self.repo_cache, "blobs", WEIGHTS_SHA256 + ".408d0ef8.incomplete")
        with open(orphan, "wb") as handle:
            handle.write(b"x" * 1000)  # an earlier library attempt that was killed
        self.hub.unusable_metadata = True
        calls = []

        self.orchestrate(calls)

        self.assertEqual(calls, [REPO])
        self.assertEqual([name for name in self.blobs() if name.endswith((".part", ".incomplete"))], [])
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_library_download_that_fails_the_pin_keeps_the_resumable_partial(self):
        """Review mutant M8 (round 2): the library's bad blob is discarded BEFORE the sweep that
        removes a `.part` beside its blob, so the resumable partial survives a library download that
        fails verification. Swapping the two calls passed every test until this one."""
        self.interrupt_after(120_000)
        self.hub.unusable_metadata = True

        with self.assertRaises(server.ModelDownloadError):
            self.orchestrate([], fallback=self.library([], weights=WEIGHTS[:-1] + b"\x00"))

        self.assertTrue(os.path.exists(self.weights_part()), "a library download that failed the pin cost the partial")
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)

    def test_a_failed_library_download_keeps_the_partial_for_a_later_resume(self):
        self.interrupt_after(120_000)
        self.hub.unusable_metadata = True

        def failing(*_args):
            raise OSError("the library could not download either")

        with self.assertRaises(OSError):
            self.orchestrate([], fallback=failing)

        self.assertEqual(os.path.getsize(self.weights_part()), 120_000)


class PinTests(DownloaderTestCase):
    """F830 — the helper's own download resolved `main` and trusted the hash the Hub advertised, while
    the installer pinned F483's revision and hashes: a Mac whose first download was the helper's got
    whatever `main` held that day. The helper now downloads only the pinned revision, checks every
    file against the pinned sha256 (config.json included, which the Hub vouches for with a git sha1
    only), and writes that revision as `refs/main` — on its own path and on the library fallback."""

    def test_the_pinned_revision_is_requested_and_written_as_main_even_when_main_has_moved(self):
        self.hub.main_commit = "e" * 40  # upstream `main` has moved past the pin

        self.download()

        self.assertEqual(set(self.hub.revisions), {COMMIT}, "a request resolved something other than the pin")
        self.assertEqual(self.read("refs", "main").decode(), COMMIT)
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)
        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "snapshots", "e" * 40)))

    def test_weights_the_hub_says_do_not_hash_to_the_pin_are_refused_before_any_byte_is_fetched(self):
        self.hub.advertised_sha = "0" * 64

        with self.assertRaises(server.ModelDownloadError):
            self.download()

        self.assertEqual([path for method, path in self.hub.requests if path.startswith("/cdn/") and method == "GET"], [],
                         "1.6 GB was fetched for a file that cannot be the pinned one")
        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")))

    def test_a_config_that_does_not_hash_to_the_pin_is_discarded_not_published(self):
        """config.json's ETag is a git sha1, so the size was all that vouched for it: same-size bytes
        that are not the pinned file were published."""
        self.hub.config = CONFIG.replace(b"128", b"129")  # same length, not the pinned file

        with self.assertRaises(server.ModelDownloadError):
            self.download()

        self.assertNotIn(CONFIG_ETAG, self.blobs())
        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")))

    def test_a_blob_already_on_disk_that_does_not_hash_to_the_pin_is_replaced(self):
        blobs = os.path.join(self.repo_cache, "blobs")
        os.makedirs(blobs)
        with open(os.path.join(blobs, CONFIG_ETAG), "wb") as handle:
            handle.write(CONFIG.replace(b"128", b"129"))  # the right size, the wrong bytes

        self.download()

        self.assertEqual(self.read("snapshots", COMMIT, "config.json"), CONFIG)

    def test_a_blob_that_hashes_to_its_pin_is_kept_whatever_size_the_hub_advertises(self):
        """Review probe P2 (round 2). A pass that is not fully cached — here `refs/main` is missing, as
        after a kill between the last link and the ref — met a Hub whose weights carry the pinned
        sha256 but a size one byte off. The existing-blob check compared the Hub's size before it
        hashed, so the verified 1.6 GB blob was deleted, and the re-fetch then failed (a 416): a pass
        that only needed to write a ref cost the model. The pin decides, and nothing else."""
        self.download()
        blob = os.path.join(self.repo_cache, "blobs", WEIGHTS_SHA256)
        before = os.stat(blob)
        os.remove(os.path.join(self.repo_cache, "refs", "main"))
        self.hub.advertised_extra = 1
        fetched_before = len([1 for method, path in self.hub.requests if method == "GET" and path.startswith("/cdn/")])

        try:
            self.download()
        except server.ModelDownloadError as error:
            self.fail("a pass that needed only its ref failed (%s); the verified blob is %s"
                      % (error, "still there" if os.path.exists(blob) else "gone"))

        after = os.stat(blob)
        self.assertEqual((after.st_ino, after.st_size), (before.st_ino, before.st_size),
                         "a blob that verifies against its pin was deleted on the Hub's word")
        fetched_after = len([1 for method, path in self.hub.requests if method == "GET" and path.startswith("/cdn/")])
        self.assertEqual(fetched_after, fetched_before, "a verified blob was fetched again")
        self.assertEqual(self.read("refs", "main").decode(), COMMIT)

    def test_a_repository_with_no_pin_is_not_downloaded(self):
        with self.assertRaises(server.ModelDownloadError):
            server.ensure_dictation_model("someone/else", self.hub_dir, endpoint=self.hub.endpoint,
                                          heartbeat=self.beats, retries=0, sleep=self.bounded_sleep)
        self.assertEqual(self.hub.requests, [])

    def test_the_librarys_download_is_asked_for_the_pin_verified_and_given_the_main_ref(self):
        self.hub.unusable_metadata = True
        calls = []

        server.download_dictation_model(REPO, self.hub_dir, emit=lambda *_args: None,
                                        fallback=self.library(calls),
                                        endpoint=self.hub.endpoint, retries=0, sleep=self.bounded_sleep)

        self.assertEqual(getattr(self, "fallback_revisions", None), [COMMIT])
        self.assertEqual(self.read("refs", "main").decode(), COMMIT,
                         "a pinned library download leaves no ref, so the offline load could not find it")

    def test_a_library_download_that_does_not_hash_to_the_pin_is_discarded(self):
        self.hub.unusable_metadata = True
        wrong = WEIGHTS[:-1] + b"\x00"

        with self.assertRaises(server.ModelDownloadError):
            server.download_dictation_model(REPO, self.hub_dir, emit=lambda *_args: None,
                                            fallback=self.library([], weights=wrong),
                                            endpoint=self.hub.endpoint, retries=0, sleep=self.bounded_sleep)

        self.assertFalse(os.path.exists(os.path.join(self.repo_cache, "refs", "main")))
        self.assertNotIn(WEIGHTS_SHA256, self.blobs(), "bytes that are not the pinned file were kept as its blob")


class PinSourceTests(unittest.TestCase):
    """F830 — the helper's pin is F483's pin, read from both files rather than restated: the
    installer's `dictation_*` assignments and the helper's table must agree, and the repository the
    app asks the helper for must be one it has a pin for."""

    @staticmethod
    def installer_assignment(name):
        import re

        path = os.path.join(os.path.dirname(__file__), "..", "setup-local-whisper.sh")
        with open(path, encoding="utf-8") as handle:
            found = re.findall(r'^%s="([^"]+)"$' % name, handle.read(), flags=re.MULTILINE)
        if len(found) != 1:
            raise AssertionError("expected one %s= in setup-local-whisper.sh, found %d" % (name, len(found)))
        return found[0]

    def test_the_helpers_pin_is_the_installers_pin(self):
        repository = self.installer_assignment("dictation_repository")
        expected = {repository: {
            "revision": self.installer_assignment("dictation_revision"),
            "sha256": {
                "config.json": self.installer_assignment("dictation_config_sha256"),
                "weights.safetensors": self.installer_assignment("dictation_weights_sha256"),
            },
        }}
        self.assertEqual(server.PINNED_DICTATION_MODELS, expected)

    def test_the_repository_the_app_asks_for_has_a_pin(self):
        import re

        path = os.path.join(os.path.dirname(__file__), "..", "..", "Sources", "WhisperCore",
                            "WarmWhisperDictationEngine.swift")
        with open(path, encoding="utf-8") as handle:
            defaults = set(re.findall(r'mlxRepo: String = "([^"]+)"', handle.read()))
        self.assertTrue(defaults, "could not find the engine's default mlxRepo")
        self.assertEqual(defaults - set(server.PINNED_DICTATION_MODELS), set())


# F826: where the dictation model's download lock lives, as both the helper and
# `setup-local-whisper.sh` must agree — `LockTests.test_the_lock_is_where_the_installer_probes_it`
# checks each of them against it.
LOCK_RELATIVE_PATH = os.path.join(".locks", "models--mlx-community--whisper-large-v3-turbo",
                                  "whispermeet-dictation-download.lock")

# A second process holding a flock on a path until its stdin closes. Plain `fcntl`, the same
# primitive as the helper's and lockf(1)'s (BSD `flock(2)`).
_HOLD_PLAIN = """
import fcntl, os, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
print("held", flush=True)
sys.stdin.read()
"""

# The same, through the helper's own lock: a second helper downloading the same model.
_HOLD_AS_HELPER = """
import importlib.util, sys
spec = importlib.util.spec_from_file_location("helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
with helper.download_lock(sys.argv[2], sys.argv[3], wait=0):
    print("held", flush=True)
    sys.stdin.read()
"""


class LockTests(DownloaderTestCase):
    """F826 — two helper processes on one model directory (two copies of the app) appended to the
    same `.part` with nothing between them, and a Repair during the download moved the helper's
    `.part` away and deleted it. The download now runs under a lock outside the model's directory:
    a second helper waits briefly, then says why it cannot download and touches nothing, and the
    installer leaves a model alone while the lock is held (`HelperDownloadLockTests` in
    `test_f626_f627_dictation_cache_pin.py`)."""

    def setUp(self):
        super().setUp()
        saved_wait = getattr(server, "DOWNLOAD_LOCK_WAIT_SECONDS", None)
        server.DOWNLOAD_LOCK_WAIT_SECONDS = 0
        self.addCleanup(setattr, server, "DOWNLOAD_LOCK_WAIT_SECONDS", saved_wait)
        self.lock_path = os.path.join(self.hub_dir, LOCK_RELATIVE_PATH)

    def hold(self, program, *args):
        """Start a second process that holds the lock, and wait until it says it does."""
        import subprocess
        import sys

        holder = subprocess.Popen([sys.executable, "-c", program] + list(args),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def release():
            holder.stdin.close()
            holder.wait(timeout=30)

        self.addCleanup(release)
        self.assertEqual(holder.stdout.readline().strip(), "held", "the second process never took the lock")
        return holder

    def orchestrate(self, reports):
        return server.download_dictation_model(
            REPO, self.hub_dir, emit=lambda *report: reports.append(report[0]), fallback=self.library([]),
            endpoint=self.hub.endpoint, retries=0, sleep=self.bounded_sleep, chunk_size=16 * 1024,
        )

    def test_another_process_holding_the_download_lock_stops_this_download_before_it_touches_anything(self):
        self.interrupt_after(120_000)
        requests_before = len(self.hub.requests)
        self.hold(_HOLD_PLAIN, self.lock_path)
        reports = []

        with self.assertRaises(server.ModelDownloadError) as caught:
            self.orchestrate(reports)

        self.assertIn("another WhisperMeet process", str(caught.exception))
        self.assertEqual(len(self.hub.requests), requests_before, "a second writer reached the Hub")
        self.assertEqual(os.path.getsize(self.weights_part()), 120_000, "a second writer touched the partial")
        self.assertEqual(reports, [], "a download that never started was reported")

    def test_a_second_helper_cannot_download_while_the_first_holds_the_model(self):
        """Both sides the helper's own code, in two processes."""
        self.hold(_HOLD_AS_HELPER, os.path.abspath(server.__file__), self.hub_dir, REPO)

        with self.assertRaises(server.ModelDownloadError):
            self.orchestrate([])

        self.assertEqual(self.hub.requests, [])

    def test_once_the_lock_is_free_the_download_runs(self):
        holder = self.hold(_HOLD_PLAIN, self.lock_path)
        holder.stdin.close()
        holder.wait(timeout=30)

        self.orchestrate([])

        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_start_that_finds_the_model_finished_by_the_time_it_holds_the_lock_downloads_nothing(self):
        """What a helper that waited for another one finds: the model is there."""
        self.download()
        requests_before = len(self.hub.requests)
        reports = []

        self.orchestrate(reports)

        self.assertEqual(len(self.hub.requests), requests_before)
        self.assertEqual(reports, [])

    def test_the_lock_is_where_the_installer_probes_it(self):
        self.assertEqual(server.download_lock_path(self.hub_dir, REPO), self.lock_path)
        installer = os.path.join(os.path.dirname(__file__), "..", "setup-local-whisper.sh")
        with open(installer, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn('"$hub_directory/.locks/$dictation_repo_directory_name/whispermeet-dictation-download.lock"',
                      source)


class OrchestrationTests(DownloaderTestCase):
    def test_the_library_downloader_is_only_the_fallback_for_an_unavailable_resumable_path(self):
        self.hub.unusable_metadata = True
        calls = []
        reports = []
        server.download_dictation_model(
            REPO, self.hub_dir, emit=lambda *report: reports.append(report[0]), fallback=self.library(calls),
            endpoint=self.hub.endpoint, retries=0, sleep=lambda _s: None,
        )
        self.assertEqual(calls, [REPO])
        self.assertEqual(reports[0], True)
        self.assertEqual(reports[-1], False, "the report always closes, so the app leaves stall mode")

    def test_a_failed_transfer_is_not_retried_by_restarting_it_in_the_library(self):
        self.hub.drop_after = [0] * 10  # every attempt is cut before a byte arrives
        calls = []
        reports = []
        with self.assertRaises(server.ModelDownloadError):
            server.download_dictation_model(
                REPO, self.hub_dir, emit=lambda *report: reports.append(report[0]),
                fallback=lambda *args: calls.append(args),
                endpoint=self.hub.endpoint, retries=1, sleep=lambda _s: None,
            )
        self.assertEqual(calls, [], "falling back would download from zero and lose the partial file")
        self.assertEqual(reports[-1], False)


class ProgressFigureTests(DownloaderTestCase):
    """F859 — the reports said "downloading" and nothing more, so the app could not say how far the
    1.6 GB download had got, though the downloader knew. A report now carries the bytes on disk and
    the whole model's size, counted across both files so the figure never goes backwards."""

    def counted(self, **overrides):
        emitted = []
        beat = server.DownloadHeartbeat(lambda *report: emitted.append(report), interval=0)  # every tick
        self.download(heartbeat=beat, **overrides)
        return [report[1] for report in emitted if len(report) == 2]

    def test_reports_count_the_bytes_of_the_whole_model(self):
        counted = self.counted()

        total = len(CONFIG) + len(WEIGHTS)
        self.assertTrue(counted, "no report carried a figure")
        self.assertEqual(set(t for _done, t in counted), {total})
        done = [d for d, _t in counted]
        self.assertEqual(done, sorted(done), "a figure went backwards")
        self.assertEqual(done[-1], total)

    def test_a_resumed_download_counts_the_bytes_already_on_disk(self):
        self.interrupt_after(120_000)

        counted = self.counted()

        # The config blob already on disk is re-hashed first (F830), which reports its own 16 bytes;
        # after it, the weights' figure starts at the bytes already on disk, never below them.
        self.assertTrue(counted)
        resumed_from = len(CONFIG) + 120_000
        self.assertEqual([d for d, _t in counted if len(CONFIG) < d < resumed_from], [],
                         "the resume counted the weights from zero")
        self.assertEqual(counted[-1][0], len(CONFIG) + len(WEIGHTS))

    def test_the_librarys_download_reports_no_figure(self):
        """The fallback's progress is the library's own, which this code does not count."""
        self.hub.unusable_metadata = True
        reports = []
        stand_in = self.library([])

        def ticking_library(repo, hub_dir, heartbeat, revision=None):
            heartbeat.tick()
            stand_in(repo, hub_dir, heartbeat, revision)

        server.download_dictation_model(REPO, self.hub_dir, emit=lambda *report: reports.append(report),
                                        fallback=ticking_library, endpoint=self.hub.endpoint, retries=0,
                                        sleep=self.bounded_sleep)

        self.assertIn((True,), reports)
        self.assertTrue(all(len(report) == 1 for report in reports), reports)


class HeartbeatTests(unittest.TestCase):
    def test_reports_are_throttled_to_one_a_second(self):
        now = [100.0]
        emitted = []
        beat = server.DownloadHeartbeat(emitted.append, clock=lambda: now[0], interval=1.0)
        for step in range(30):  # 3 seconds of chunks arriving every 100 ms
            now[0] = 100.0 + step * 0.1
            beat.tick()
        self.assertEqual(len(emitted), 3)
        self.assertTrue(all(value is True for value in emitted))

    def test_the_first_chunk_reports_immediately(self):
        emitted = []
        server.DownloadHeartbeat(emitted.append, clock=lambda: 5.0, interval=1.0).tick()
        self.assertEqual(emitted, [True])

    def test_the_wire_line_is_the_progress_message_the_app_reads(self):
        import io
        import sys

        captured = io.StringIO()
        original = sys.stdout
        sys.stdout = captured
        try:
            server.emit_download_report(True)
            server.emit_download_report(False)
        finally:
            sys.stdout = original
        lines = [json.loads(line) for line in captured.getvalue().splitlines()]
        self.assertEqual(lines, [{"downloading": True}, {"downloading": False}])

    def test_the_wire_line_carries_the_byte_counts_only_when_they_are_known(self):
        """F859. Optional fields: a line without them is what every older helper sends, and the app
        reads it as "downloading" with no figure."""
        import io
        import sys

        captured = io.StringIO()
        original = sys.stdout
        sys.stdout = captured
        try:
            server.emit_download_report(True, (677870710, 1613977880))
            server.emit_download_report(True)
            server.emit_download_report(False, (1, 2))
        finally:
            sys.stdout = original
        lines = [json.loads(line) for line in captured.getvalue().splitlines()]
        self.assertEqual(lines, [
            {"downloading": True, "downloadedBytes": 677870710, "totalBytes": 1613977880},
            {"downloading": True},
            {"downloading": False},
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
