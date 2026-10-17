#!/usr/bin/env python3
"""F997: how a volume answers the locks WhisperMeet's link-import recovery relies on.

Usage:  python3 Scripts/bench/flock-probe.py /Volumes/<share>/<a folder you can write to>

Run it once on each network share you might keep a WhisperMeet library on (NFS, SMB). It writes one
small file named `whispermeet-flock-probe-<random>.tmp` in that folder and removes it again; it reads
and changes nothing else.

What it asks, in the order InterruptedLinkImportExtraction does (F945, F976):
  1. Can a process create a file with O_EXLOCK (an exclusive lock taken at open)?
  2. While a second process holds that lock, does flock(LOCK_EX | LOCK_NB) from this process
     refuse (EWOULDBLOCK — the lock works), succeed (the volume says yes without locking), or fail
     with ENOTSUP/EOPNOTSUPP (the volume says it cannot lock, and WhisperMeet falls back)?
  3. The same question for open(O_EXLOCK | O_NONBLOCK).
It prints one line per answer and a verdict line. Paste the whole output back.
"""
import errno
import fcntl
import os
import subprocess
import sys
import time
import uuid

O_EXLOCK = getattr(os, "O_EXLOCK", 0x20)


def describe(err):
    return f"{errno.errorcode.get(err, err)} ({os.strerror(err)})"


def holder(path):
    """Child: open with O_EXLOCK, say so, hold for a few seconds."""
    fd = os.open(path, os.O_RDWR | O_EXLOCK)
    print("held", flush=True)
    time.sleep(6)
    os.close(fd)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--hold":
        holder(sys.argv[2])
        return
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__)
    folder = sys.argv[1]
    path = os.path.join(folder, f"whispermeet-flock-probe-{uuid.uuid4().hex}.tmp")
    mounted = subprocess.run(["df", folder], capture_output=True, text=True).stdout.strip().splitlines()[-1:]
    print(f"folder: {folder}")
    print(f"mounted from: {mounted[0].split()[0] if mounted else '?'}  (run `mount` to see whether that is nfs or smbfs)")
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | O_EXLOCK | os.O_NONBLOCK, 0o600)
        print("1. create with O_EXLOCK: ok")
        os.close(fd)
    except OSError as e:
        print(f"1. create with O_EXLOCK: refused, {describe(e.errno)}")
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        os.close(fd)
    child = subprocess.Popen([sys.executable, __file__, "--hold", path], stdout=subprocess.PIPE, text=True)
    try:
        line = child.stdout.readline().strip()
        if line != "held":
            print(f"2/3. the holder could not take the lock (it said {line!r}); see step 1")
            return
        verdicts = []
        fd = os.open(path, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("2. flock(LOCK_EX|LOCK_NB) while another process holds it: SUCCEEDED — the volume does not lock")
            verdicts.append("lies")
        except OSError as e:
            print(f"2. flock(LOCK_EX|LOCK_NB) while another process holds it: {describe(e.errno)}")
            verdicts.append("locks" if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN) else "unsupported" if e.errno in (errno.ENOTSUP, errno.EOPNOTSUPP) else "other")
        finally:
            os.close(fd)
        try:
            fd = os.open(path, os.O_RDWR | O_EXLOCK | os.O_NONBLOCK)
            os.close(fd)
            print("3. open(O_EXLOCK|O_NONBLOCK) while another process holds it: SUCCEEDED — the volume does not lock")
            verdicts.append("lies")
        except OSError as e:
            print(f"3. open(O_EXLOCK|O_NONBLOCK) while another process holds it: {describe(e.errno)}")
            verdicts.append("locks" if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN) else "unsupported" if e.errno in (errno.ENOTSUP, errno.EOPNOTSUPP) else "other")
        print(f"verdict: {', '.join(verdicts)}")
    finally:
        child.wait()
        try:
            os.unlink(path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
