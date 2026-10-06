#!/usr/bin/env python3
"""F522 — the first Quick Dictation model download restarts from zero after any interruption.

Run: python3 Scripts/tests/test_dictation_model_download.py

`whisper_dictate_server.py` used to `shutil.rmtree` the whole model cache whenever it found the
download unfinished, and the installed `huggingface_hub` would not have resumed it anyway: since 1.x
each attempt writes to a fresh `blobs/<etag>.<random>.incomplete` (`file_download.py:1908`) that is
deleted when the attempt raises (`:1946-1949`) and orphaned when it is killed, and nothing ever seeds
a later attempt from it. So the helper now downloads the two files itself, with HTTP `Range`, into a
partial file named for the blob it will become.

These tests run the helper's real downloader against a local HTTP server that behaves like the Hub
for the two paths involved (a `resolve/` HEAD/GET, the LFS-style redirect to a CDN path that honours
`Range`). No network, no `huggingface_hub`, no installed runtime: plain system python3, so the
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
CONFIG_ETAG = hashlib.sha1(CONFIG).hexdigest()  # git blob ids are sha1; only a size can vouch for them
WEIGHTS = bytes((i * 31 + 7) % 251 for i in range(300_000))
WEIGHTS_SHA256 = hashlib.sha256(WEIGHTS).hexdigest()  # what the Hub advertises as X-Linked-ETag for LFS/Xet


class FakeHub:
    """The two paths the downloader talks to, with the Hub's shapes: `config.json` is served
    directly (`ETag` + `Content-Length`); `weights.safetensors` answers `resolve/` with a 302 whose
    headers carry the commit, the sha256 and the size, and the CDN path behind it honours `Range`."""

    def __init__(self):
        hub = self
        self.weights = WEIGHTS
        self.advertised_sha = WEIGHTS_SHA256
        self.ignore_range = False       # answer a Range request with the whole file and a 200
        self.drop_after = []            # bytes to send before cutting the connection, one per request
        self.served = 0                 # weight bytes put on the wire, across every request
        self.ranges = []                # Range header of every weights request that reached the CDN
        self.requests = []              # (method, path)
        self.fail_head_with = None      # status for every HEAD, to model an unusable metadata path

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _resolve(self, head):
                hub.requests.append((self.command, self.path))
                if hub.fail_head_with is not None and head:
                    self.send_response(hub.fail_head_with)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                name = self.path.rsplit("/", 1)[-1]
                if name == "config.json":
                    self.send_response(200)
                    self.send_header("ETag", '"%s"' % CONFIG_ETAG)
                    self.send_header("X-Repo-Commit", COMMIT)
                    self.send_header("Content-Length", str(len(CONFIG)))
                    self.end_headers()
                    if not head:
                        self.wfile.write(CONFIG)
                elif name == "weights.safetensors":
                    self.send_response(302)
                    self.send_header("Location", "http://127.0.0.1:%d/cdn/weights" % hub.port)
                    self.send_header("X-Repo-Commit", COMMIT)
                    self.send_header("X-Linked-ETag", '"%s"' % hub.advertised_sha)
                    self.send_header("X-Linked-Size", str(len(hub.weights)))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            def do_HEAD(self):
                if self.path.startswith("/cdn/"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(hub.weights)))
                    self.end_headers()
                else:
                    self._resolve(head=True)

            def do_GET(self):
                if not self.path.startswith("/cdn/"):
                    self._resolve(head=False)
                    return
                hub.requests.append((self.command, self.path))
                range_header = self.headers.get("Range")
                hub.ranges.append(range_header)
                start = 0
                status = 200
                if range_header and not hub.ignore_range:
                    start = int(range_header.split("=")[1].split("-")[0])
                    status = 206
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


class Beats:
    """Records every tick the downloader makes, so a test can say bytes were flowing."""

    def __init__(self):
        self.count = 0

    def tick(self):
        self.count += 1


class DownloaderTestCase(unittest.TestCase):
    def setUp(self):
        self.hub = FakeHub()
        self.addCleanup(self.hub.close)
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f522-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.hub_dir = os.path.join(self.tmp, "hf", "hub")
        self.repo_cache = os.path.join(self.hub_dir, "models--" + REPO.replace("/", "--"))
        self.beats = Beats()

    def download(self, **overrides):
        options = dict(
            endpoint=self.hub.endpoint,
            heartbeat=self.beats,
            retries=0,
            sleep=lambda _seconds: None,
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
        self.hub.fail_head_with = 500
        with self.assertRaises(server.ResumableDownloadUnavailable):
            self.download()
        self.assertFalse(os.path.exists(self.repo_cache))


class OrchestrationTests(DownloaderTestCase):
    def test_the_library_downloader_is_only_the_fallback_for_an_unavailable_resumable_path(self):
        self.hub.fail_head_with = 500
        calls = []
        reports = []
        server.download_dictation_model(
            REPO, self.hub_dir, emit=reports.append,
            fallback=lambda repo, hub_dir, heartbeat: calls.append((repo, hub_dir)),
            endpoint=self.hub.endpoint, retries=0, sleep=lambda _s: None,
        )
        self.assertEqual(calls, [(REPO, self.hub_dir)])
        self.assertEqual(reports[0], True)
        self.assertEqual(reports[-1], False, "the report always closes, so the app leaves stall mode")

    def test_a_failed_transfer_is_not_retried_by_restarting_it_in_the_library(self):
        self.hub.drop_after = [0] * 10  # every attempt is cut before a byte arrives
        calls = []
        reports = []
        with self.assertRaises(server.ModelDownloadError):
            server.download_dictation_model(
                REPO, self.hub_dir, emit=reports.append,
                fallback=lambda *args: calls.append(args),
                endpoint=self.hub.endpoint, retries=1, sleep=lambda _s: None,
            )
        self.assertEqual(calls, [], "falling back would download from zero and lose the partial file")
        self.assertEqual(reports[-1], False)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
