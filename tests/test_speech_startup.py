#!/usr/bin/env python3
"""Assert-based checks for speech-engine startup: background warm must stay
silent and a user start during warm must queue, not swallow the click."""

import tempfile
import threading
from pathlib import Path

from readalong import ASR, App, _ensure_asr


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def fresh_app():
    app = App.__new__(App)
    app.lock = threading.RLock()
    app.status = "idle"
    app.error = ""
    app._want_listen = False
    app.aligner = None
    asr = ASR(lambda *a, **k: None, lambda *a, **k: None)

    class OwnedProc:
        def poll(self):
            return None

    # Pretend this backend already started a healthy server: ensure must
    # fast-path without spawning anything or reporting a status.
    asr.healthy = staticmethod(lambda port: True)
    asr.port = 8010
    asr.proc = OwnedProc()
    app.asr = asr
    return app


# Silent warm: ensure(notify=False) never reports a user-visible loading.
app = fresh_app()
seen = []
app.asr.on_status = lambda s, m="": seen.append(s)
app.asr.ensure(notify=False)
check("silent warm reports nothing", seen, [])

# A healthy server this backend did not start is never adopted: it may still
# hold its single live stream for a previous app instance.
import readalong.speech as speech_mod

app = fresh_app()
app.asr.port = None
app.asr.proc = None
spawned = []


class SpawnedProc:
    def poll(self):
        return None


real_popen = speech_mod.subprocess.Popen
real_free_port = speech_mod.ASR._free_port
real_data = speech_mod.DATA
tmp = tempfile.TemporaryDirectory()
speech_mod.subprocess.Popen = lambda *a, **k: (spawned.append(a), SpawnedProc())[1]
speech_mod.ASR._free_port = staticmethod(lambda start: 8099)
speech_mod.DATA = Path(tmp.name)
try:
    app.asr.ensure(notify=False)
finally:
    speech_mod.subprocess.Popen = real_popen
    speech_mod.ASR._free_port = real_free_port
    speech_mod.DATA = real_data
    tmp.cleanup()
check("unowned speech server is not adopted", len(spawned), 1)
check("fresh speech server gets its own port", app.asr.port, 8099)

# Warm success must not wipe a user-requested loading state.
app.status = "loading"
app._want_listen = True
_ensure_asr(app)
check("warm keeps user loading", app.status, "loading")

# Stale loading with no user intent still clears to idle (legacy safety).
app._want_listen = False
_ensure_asr(app)
check("warm clears stale loading", app.status, "idle")

# A user start during background loading queues instead of swallowing the tap.
app = fresh_app()
app.status = "loading"
app.documents = None
app.doc_id = None
app.model = {"words": [1]}
app.models = type("M", (), {"ready": lambda self, n: True})()
spawned = []
real_thread = threading.Thread


class FakeThread:
    def __init__(self, target=None, daemon=None, args=()):
        pass

    def start(self):
        spawned.append(True)


threading.Thread = FakeThread
try:
    app.start()
finally:
    threading.Thread = real_thread
check("start during warm sets intent", app._want_listen, True)
check("start during warm spawns worker", len(spawned), 1)

# A duplicate user start must stay a no-op.
spawned.clear()
threading.Thread = FakeThread
try:
    app.start()
finally:
    threading.Thread = real_thread
check("duplicate start spawns nothing", len(spawned), 0)

print("\nall speech startup checks passed")


# --- audio relay: no keepalive pings, OS-assigned port, and never the web port ---
import socket as socket_mod

from readalong import audio_server as audio_mod
from readalong._config import ASR_PORT, WEB_PORT
from readalong.speech import ASR as ASRClass


class _FakeBoundSocket:
    def getsockname(self):
        return ("127.0.0.1", 54321)


class _FakeServer:
    sockets = [_FakeBoundSocket()]

    def close(self):
        pass

    async def wait_closed(self):
        pass


seen = {}


async def fake_serve(handler, host, port, **kwargs):
    seen.update(kwargs)
    return _FakeServer()


original_serve = audio_mod.websockets.serve
audio_mod.websockets.serve = fake_serve
try:
    relay = audio_mod.AudioServer(lambda pcm: None, port=0)
    relay.start()
    check("relay disables keepalive pings", seen.get("ping_interval", "missing"), None)
    check("relay reports its OS-assigned port", relay.port, 54321)
    relay.stop()
finally:
    audio_mod.websockets.serve = original_serve


class _FakeSocket:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def bind(self, addr):
        if addr[1] in (ASR_PORT, WEB_PORT):
            raise OSError("in use")


original_socket = socket_mod.socket
speech_mod.socket.socket = _FakeSocket
try:
    got = ASRClass._free_port(ASR_PORT)
finally:
    speech_mod.socket.socket = original_socket
check("speech port skips taken and web ports", got not in (ASR_PORT, WEB_PORT), True)
