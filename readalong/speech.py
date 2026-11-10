"""Read Along — speech engine (Phonon-2.5 via the bundled fermion CLI).

Starts a local `fermion serve` WebSocket server, opens the microphone with
sounddevice, streams PCM, and feeds partial/final transcripts back to the app.
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

from ._config import ASR_MODEL, ASR_PORT, AUDIO_PORT, DATA, WEB_PORT


def fermion_cmd() -> list[str]:
    """The command prefix that runs the bundled fermion CLI."""
    helper = os.environ.get("READALONG_FERMION")
    if helper:
        return [sys.executable, helper]
    bin_ = shutil.which("fermion") or str(Path(sys.executable).with_name("fermion"))
    if Path(bin_).exists():
        try:
            head = Path(bin_).read_bytes()[:200].decode("utf-8", "replace")
            if not head.startswith("#!"):
                return [bin_]
            interp = head.splitlines()[0][2:].strip().split()[0]
            if Path(interp).exists():
                return [bin_]
        except (OSError, IndexError):
            pass
    # A renamed venv leaves console-script shebangs pointing at the old path.
    return [sys.executable, "-c", "from fermion.cli import main; raise SystemExit(main())"]


class ASR:
    def __init__(self, on_text, on_status):
        self.on_text = on_text
        self.on_status = on_status
        self.proc: subprocess.Popen | None = None
        self.port: int | None = None
        # Mic device selection now lives in the Swift capture layer; kept for
        # backwards compatibility with the mic picker, but no longer opens a
        # stream here — Python never touches the microphone directly.
        self.device: int | None = None
        self.thread: threading.Thread | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.ws = None
        self.q: queue.Queue = queue.Queue()
        self.running = False
        self.rms = 0.0
        self._lock = threading.Lock()
        self._gen = 0

    @staticmethod
    def healthy(port: int) -> bool:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1.5) as r:
                d = json.loads(r.read())
            return d.get("kind") == "speech"
        except Exception:
            return False

    @staticmethod
    def _free_port(start: int) -> int:
        for p in range(start, start + 20):
            # Never hand the speech server the PCM relay's port: fermion would
            # bind it first and the Swift mic socket would have nowhere to go.
            if p in (AUDIO_PORT, WEB_PORT):
                continue
            with socket.socket() as s:
                try:
                    s.bind(("127.0.0.1", p))
                    return p
                except OSError:
                    continue
        raise RuntimeError("no free port for the speech server")

    def ensure(self, notify: bool = True) -> None:
        with self._lock:
            if self.port and self.healthy(self.port):
                return
            for p in range(ASR_PORT, ASR_PORT + 10):
                if p == AUDIO_PORT:
                    continue
                if self.healthy(p):
                    self.port = p
                    return
            cmd = fermion_cmd()
            DATA.mkdir(parents=True, exist_ok=True)
            log = open(DATA / "asr.log", "ab")
            self.port = self._free_port(ASR_PORT)
            self.proc = subprocess.Popen(
                cmd + ["serve", ASR_MODEL, "--port", str(self.port)],
                stdout=log, stderr=log, start_new_session=True,
            )
            if notify:
                self.on_status("loading")
            for _ in range(120):
                if self.healthy(self.port):
                    return
                if self.proc.poll() is not None:
                    raise RuntimeError("speech server exited: " + tail(DATA / "asr.log"))
                time.sleep(1)
            raise RuntimeError("speech server did not start within 120s")

    def start(self) -> None:
        with self._lock:
            if self.running:
                return
            old = self.thread
        # stop() closes the socket but returns immediately. Wait for that
        # session to end before opening the next one: fermion allows a single
        # live stream, and a start that races the old session's final decode
        # gets "engine busy" -> the UI shows "Try again".
        if old is not None and old.is_alive():
            old.join(timeout=3)
        with self._lock:
            if self.running:
                return
            self._gen += 1
            gen = self._gen
            self.running = True
            self.q = queue.Queue()
            self.thread = threading.Thread(target=self._run, args=(gen,), daemon=True)
            self.thread.start()

    def feed_audio(self, pcm: bytes) -> None:
        """Swift pushes captured PCM (float32 mono 16 kHz) here for ASR."""
        if self.running:
            self.q.put(pcm)

    def _run(self, gen: int) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self.loop = loop
        err = False
        try:
            loop.run_until_complete(self._session(gen))
        except asyncio.CancelledError:
            pass
        except Exception as e:
            if gen == self._gen:
                err = True
                self.on_status("error", str(e))
        finally:
            if gen == self._gen:
                self.running = False
                if not err:
                    self.on_status("idle")
                self.loop = None
                self.ws = None
            try:
                loop.close()
            except Exception:
                pass

    async def _session(self, gen: int) -> None:
        import websockets

        uri = f"ws://127.0.0.1:{self.port}/v1/audio/stream"
        async with websockets.connect(uri, max_size=None) as ws:
            if gen != self._gen:
                return
            self.ws = ws
            await ws.send(json.dumps({"sample_rate": 16000, "format": "pcm_f32le"}))
            if gen == self._gen:
                self.on_status("listening")
            sender = asyncio.create_task(self._send(ws, gen))
            try:
                async for msg in ws:
                    d = json.loads(msg)
                    t = d.get("type")
                    if t in ("partial", "final"):
                        self.on_text(d.get("text", ""), t == "final")
                    elif t == "error":
                        raise RuntimeError(d.get("message", "speech error"))
                    elif t == "done":
                        break
            finally:
                sender.cancel()
                try:
                    await sender
                except asyncio.CancelledError:
                    pass
                except Exception:
                    pass
                if gen == self._gen:
                    self.ws = None

    async def _send(self, ws, gen: int) -> None:
        while self.running and gen == self._gen:
            try:
                chunk = self.q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.01)
                continue
            await ws.send(chunk)
        if gen != self._gen:
            return
        try:
            await ws.send(json.dumps({"type": "end"}))
        except Exception:
            pass

    def stop(self) -> None:
        with self._lock:
            self.running = False
            ws, loop = self.ws, self.loop
        if ws is not None and loop is not None and not loop.is_closed():
            try:
                asyncio.run_coroutine_threadsafe(ws.close(), loop)
            except Exception:
                pass

    def shutdown(self) -> None:
        self.stop()
        thread = self.thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=3)
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                pass


def tail(path: Path, n: int = 800) -> str:
    try:
        data = path.read_bytes()[-n:]
        return data.decode("utf-8", "replace").strip()
    except Exception:
        return ""


def list_mics() -> dict:
    """macOS input devices the Follow me picker can choose from."""
    import sounddevice as sd

    payload = {"default": None, "devices": []}
    try:
        # PortAudio caches the device list, so a USB/Bluetooth mic that was
        # unplugged keeps showing up until PortAudio is re-initialized.
        # Terminating and re-querying forces a fresh CoreAudio enumeration.
        try:
            sd._terminate()
            sd._initialize()
        except Exception:
            pass
        devices = sd.query_devices()
        default = sd.default.device[0]
        try:
            default = int(default)
        except Exception:
            default = None
        payload["default"] = default
        for i, d in enumerate(devices):
            ins = int(d.get("max_input_channels") or 0)
            if ins <= 0:
                continue
            payload["devices"].append({
                "id": i,
                "name": str(d.get("name", "")),
                "channels": ins,
            })
    except Exception as e:
        payload["error"] = str(e)
    return payload
