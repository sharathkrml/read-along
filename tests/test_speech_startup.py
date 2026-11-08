#!/usr/bin/env python3
"""Assert-based checks for speech-engine startup: background warm must stay
silent and a user start during warm must queue, not swallow the click."""

import threading

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
    asr = ASR(lambda *a, **k: None, lambda *a, **k: None)
    # Pretend a healthy server already serves 8010: ensure must fast-path
    # without spawning anything or reporting a status.
    asr.healthy = staticmethod(lambda port: True)
    asr.port = None
    app.asr = asr
    return app


# Silent warm: ensure(notify=False) never reports a user-visible loading.
app = fresh_app()
seen = []
app.asr.on_status = lambda s, m="": seen.append(s)
app.asr.ensure(notify=False)
check("silent warm reports nothing", seen, [])

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
