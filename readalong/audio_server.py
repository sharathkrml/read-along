"""Read Along — audio capture relay.

The Swift app owns microphone permission (it has ``NSMicrophoneUsageDescription``
and the audio-input entitlement), so it captures PCM with AVAudioEngine and
streams it here over a WebSocket. This module relays each chunk into the ASR
send queue, which forwards it to the local fermion server. Python never opens
the microphone itself, so TCC attributes microphone access to the Read Along
app and the system permission prompt appears as expected.
"""

from __future__ import annotations

import asyncio
import threading

import websockets


class AudioServer:
    """WebSocket server that receives PCM from the Swift capture layer."""

    def __init__(self, feed_callback, host: str = "127.0.0.1", port: int = 8011):
        self.feed = feed_callback
        self.host = host
        self.port = port
        self._loop: asyncio.AbstractEventLoop | None = None
        self._server = None
        self._thread: threading.Thread | None = None
        # Set once the listening socket is actually bound, so callers know the
        # port is open before Swift tries to connect its microphone WebSocket.
        self._serving = threading.Event()

    def start(self, wait: float = 5.0) -> None:
        self._serving.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        if not self._serving.wait(wait):
            self.stop()
            raise RuntimeError(
                f"audio relay did not bind to {self.host}:{self.port} within {wait}s"
            )

    @property
    def is_serving(self) -> bool:
        return self._serving.is_set()

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)

        async def handler(websocket) -> None:
            async for message in websocket:
                if isinstance(message, (bytes, bytearray)):
                    self.feed(bytes(message))

        async def main() -> None:
            try:
                # websockets.serve returns only after the socket is bound, so
                # setting _serving here means the port is genuinely open.
                self._server = await websockets.serve(handler, self.host, self.port)
            except OSError as exc:
                # Port already in use (stale process from a previous launch).
                # Surface it instead of silently running a dead server.
                print(f"[audio] could not bind to {self.host}:{self.port}: {exc}")
                self._server = None
                return
            self._serving.set()
            await asyncio.Future()  # run forever

        self._loop.run_until_complete(main())

    def stop(self) -> None:
        self._serving.clear()
        if self._loop is not None and self._server is not None:
            try:
                asyncio.run_coroutine_threadsafe(self._server.close(), self._loop)
                self._loop.call_soon_threadsafe(self._loop.stop)
            except Exception:
                pass
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
