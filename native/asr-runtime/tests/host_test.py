#!/usr/bin/env python3
"""Integration test for SuperDictateOnnxHost over framed IPC v1 (dev only).

    host_test.py <host_binary> <model_dir> <assets_dir> <long.wav> [<golden.txt>]

Covers: CREATE/STATUS/TRANSCRIBE round-trip, BUSY while running, CANCEL by
target id, idle CPU after inference, malformed frame -> exit 2,
stdin EOF -> exit 0.
"""
import json
import os
import struct
import subprocess
import sys
import threading
import time

import numpy as np
import soundfile as sf

REQ = struct.Struct("<4sHHQIQ")
RESP = struct.Struct("<4sHHQI")
CREATE, TRANSCRIBE, STATUS, CANCEL, SHUTDOWN = 1, 2, 3, 4, 5
OK, CANCELLED, BUSY = 0, 8, 11

failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


class Host:
    def __init__(self, binary):
        self.proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        self.lock = threading.Lock()

    def send(self, kind, request_id, body=b"", pcm=b""):
        with self.lock:
            self.proc.stdin.write(REQ.pack(b"SDAQ", 1, kind, request_id, len(body), len(pcm)) + body + pcm)
            self.proc.stdin.flush()

    def recv(self):
        header = self.proc.stdout.read(RESP.size)
        if len(header) < RESP.size:
            return None
        magic, version, status, request_id, length = RESP.unpack(header)
        assert magic == b"SDAR" and version == 1
        return status, request_id, json.loads(self.proc.stdout.read(length) or b"{}")


def cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def main():
    binary, model_dir, assets_dir, wav = sys.argv[1:5]
    golden = open(sys.argv[5], encoding="utf-8").read().strip() if len(sys.argv) > 5 else None
    audio, rate = sf.read(wav, dtype="float32")
    assert rate == 16000
    pcm = audio.astype("<f4").tobytes()

    host = Host(binary)
    host.send(STATUS, 1)
    status, rid, body = host.recv()
    check(status == OK and rid == 1 and body["state"] == "empty", "status before create")

    config = json.dumps({"model_directory": model_dir, "assets_directory": assets_dir}).encode()
    host.send(CREATE, 2, config)
    status, rid, body = host.recv()
    check(status == OK and body.get("model_id") == "parakeet-ultra-int8", "create")

    host.send(TRANSCRIBE, 3, b"{}", pcm)
    status, rid, body = host.recv()
    check(status == OK and rid == 3, "transcribe")
    if golden is not None:
        check(body.get("text") == golden, "transcribe matches golden")

    if sys.platform.startswith("linux"):
        before = cpu_seconds(host.proc.pid)
        time.sleep(3)
        idle = cpu_seconds(host.proc.pid) - before
        check(idle < 0.3, f"idle CPU after inference ({idle:.2f}s over 3s)")

    # BUSY + CANCEL: start a long request, then poke the host while it runs.
    host.send(TRANSCRIBE, 10, b"{}", pcm)
    time.sleep(0.5)
    host.send(TRANSCRIBE, 11, b"{}", pcm[:64000])
    host.send(CANCEL, 12, json.dumps({"target": 10}).encode())
    responses = {}
    for _ in range(3):
        status, rid, body = host.recv()
        responses[rid] = status
    check(responses.get(11) == BUSY, "second transcribe is BUSY")
    check(responses.get(12) == OK, "cancel acknowledged")
    check(responses.get(10) == CANCELLED, "long transcribe cancelled")

    host.send(TRANSCRIBE, 13, b"{}", pcm[:64000])
    status, rid, body = host.recv()
    check(status == OK and rid == 13, "host usable after cancel")

    host.proc.stdin.close()
    check(host.proc.wait(timeout=10) == 0, "EOF on stdin -> exit 0")

    bad = Host(binary)
    bad.proc.stdin.write(b"XXXX" + b"\0" * (REQ.size - 4))
    bad.proc.stdin.flush()
    reply = bad.recv()
    check(reply is not None and reply[0] != OK, "bad magic -> error response")
    check(bad.proc.wait(timeout=10) == 2, "bad magic -> exit 2")

    huge = Host(binary)
    huge.proc.stdin.write(REQ.pack(b"SDAQ", 1, TRANSCRIBE, 1, 0, 1 << 40))
    huge.proc.stdin.flush()
    check(huge.proc.wait(timeout=10) == 2, "oversize PCM -> exit 2 without allocating")

    print(f"{len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
