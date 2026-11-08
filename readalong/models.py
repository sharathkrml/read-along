"""Read Along — model downloads and readiness.

Reports and manages the two local models (speech Phonon-2.5, page-reading
LFM3-VL) without blocking the UI: downloads run on background threads with
cancel/remove support and disk-space guards.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path

from ._config import (
    ASR_MODEL, ConflictError, DATA, OCR_LOCAL, OCR_MODEL, OCR_TOTAL,
    SETUP_MARKER, SPEECH_TOTAL, _ocr_dir, _ocr_source,
)


def _dir_size(path: Path) -> int:
    total = 0
    try:
        for p in path.rglob("*"):
            try:
                if p.is_file():
                    total += p.stat().st_size
            except OSError:
                pass
    except OSError:
        pass
    return total


def _speech_cache_repo() -> Path:
    override = os.environ.get("FERMION_CACHE_DIR") or os.environ.get("HF_HUB_CACHE")
    if override:
        root = Path(override).expanduser()
    else:
        hf_home = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
        root = Path(hf_home).expanduser() / "hub"
    return root / "models--FermionResearch--Phonon-2.5-English"


def _incomplete_size() -> int:
    """Largest in-flight Hub download, used for the speech progress bar."""
    best = 0
    try:
        for p in _speech_cache_repo().rglob("*.incomplete"):
            try:
                best = max(best, p.stat().st_size)
            except OSError:
                pass
    except OSError:
        pass
    return best


def _speech_root() -> Path:
    override = os.environ.get("FERMION_CACHE_DIR")
    if override:
        return Path(override).expanduser() / "speech"
    return Path.home() / ".cache" / "fermion" / "speech"


def _speech_dir() -> Path | None:
    for p in _speech_root().glob("*Phonon-2.5-English*"):
        try:
            for config in p.rglob("config.json"):
                directory = config.parent
                if any(part.endswith(".partial") for part in directory.parts):
                    continue
                manifest = json.loads((directory / "packed_manifest.json").read_text())
                if not manifest or not json.loads(config.read_text()):
                    continue
                container = directory / "model.fermion"
                with container.open("rb") as stream:
                    size = int.from_bytes(stream.read(8), "little")
                    if not 0 < size <= min(container.stat().st_size - 8, 16 * 1024 * 1024):
                        continue
                    header = json.loads(stream.read(size))
                if (header.get("format") == "fermion-five-value-parakeet-v1"
                        and header.get("index")
                        and 8 + size + sum(e["b"] for e in header["index"]) == container.stat().st_size):
                    return directory
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return None


class Models:
    """Download and report the two local models without blocking the UI."""

    def __init__(self):
        self.lock = threading.RLock()
        self.downloads: dict[str, dict] = {}
        self.procs: dict[str, subprocess.Popen] = {}
        self._ready = {"speech": False, "ocr": False}
        self.refresh()

    def refresh(self) -> None:
        self._ready["speech"] = _speech_dir() is not None
        self._ready["ocr"] = _ocr_dir() is not None

    def ready(self, name: str) -> bool:
        return bool(self._ready.get(name))

    def needs_setup(self) -> bool:
        return not SETUP_MARKER.exists()

    def finish(self) -> None:
        DATA.mkdir(parents=True, exist_ok=True)
        SETUP_MARKER.write_text("1\n")

    def any_downloading(self) -> bool:
        with self.lock:
            return any(v.get("state") in ("preparing", "downloading", "verifying", "removing") for v in self.downloads.values())

    def status(self, name: str) -> dict:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        self.refresh()
        total = SPEECH_TOTAL if name == "speech" else OCR_TOTAL
        path = _speech_dir() if name == "speech" else _ocr_dir()
        with self.lock:
            info = dict(self.downloads.get(name) or {})
        state = info.get("state", "missing")
        base = {"bytes": 0, "total": total,
                "path": str(OCR_LOCAL if name == "ocr" else _speech_root()),
                "can_cancel": state in ("preparing", "downloading"),
                "progress_is_approximate": True}
        if path and state not in ("preparing", "downloading", "verifying", "removing"):
            return {**base, "state": "ready", "bytes": _dir_size(path), "path": str(path), "can_cancel": False}
        if state == "downloading":
            if name == "ocr":
                bytes_ = _dir_size(OCR_LOCAL)
            else:
                bytes_ = _incomplete_size()
            return {**base, "state": state, "bytes": bytes_, "phase": "Downloading and installing"}
        return {**base, "state": state if state != "ready" else "missing", "error": info.get("error", "")}

    def status_all(self) -> dict:
        return {
            "first_run": self.needs_setup(),
            "speech": self.status("speech"),
            "ocr": self.status("ocr"),
        }

    def start(self, name: str) -> None:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        with self.lock:
            if self.status(name)["state"] in ("ready", "preparing", "downloading", "verifying", "removing"):
                return
            root = OCR_LOCAL if name == "ocr" else _speech_root()
            while not root.exists():
                root = root.parent
            total = SPEECH_TOTAL if name == "speech" else OCR_TOTAL
            if shutil.disk_usage(root).free < total * 3:
                raise ValueError("Not enough free storage. Allow approximately three times the download size for installation.")
            self.downloads[name] = {"state": "preparing", "error": "", "bytes": 0}
        target = self._download_speech if name == "speech" else self._download_ocr
        threading.Thread(target=target, daemon=True).start()

    def _set(self, name: str, state: str, error: str = "") -> None:
        with self.lock:
            if (self.downloads.get(name) or {}).get("state") == "canceled":
                return
            self.downloads[name] = {"state": state, "error": error}
        self.refresh()

    def _download_speech(self) -> None:
        from .speech import fermion_cmd

        self._download("speech", fermion_cmd() + ["transcribe", ASR_MODEL, "--download-only"])

    def _download_ocr(self) -> None:
        self._download("ocr", [sys.executable, "-c",
            "from huggingface_hub import snapshot_download; import sys; snapshot_download(sys.argv[1], local_dir=sys.argv[2])",
            OCR_MODEL, str(OCR_LOCAL)])

    def _download(self, name: str, command: list[str]) -> None:
        try:
            DATA.mkdir(parents=True, exist_ok=True)
            log_path = DATA / f"setup-{name}.log"
            with open(log_path, "ab") as log:
                with self.lock:
                    if self.downloads[name]["state"] == "canceled":
                        return
                    proc = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True,
                                            env={**os.environ, "HF_HUB_DISABLE_XET": "1"})
                    self.procs[name] = proc
                    self.downloads[name]["state"] = "downloading"
                rc = proc.wait()
            with self.lock:
                if self.downloads[name]["state"] == "canceled":
                    return
                self.downloads[name]["state"] = "verifying"
            if rc != 0:
                raise RuntimeError(tail(log_path) or "Download was interrupted. Retry the download.")
            if (_speech_dir() if name == "speech" else _ocr_dir()) is None:
                raise RuntimeError("Installation is incomplete. Retry the download to finish it.")
            self._set(name, "ready")
        except Exception as e:
            self._set(name, "error", str(e))
        finally:
            with self.lock:
                self.procs.pop(name, None)

    def cancel(self, name: str) -> None:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        with self.lock:
            state = (self.downloads.get(name) or {}).get("state")
            if state not in ("preparing", "downloading"):
                raise ConflictError("This model has no cancellable download")
            proc = self.procs.get(name)
            if proc is not None and proc.poll() is not None:
                raise ConflictError("The download has finished; installation is being verified")
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
            self.downloads[name] = {"state": "canceled", "error": "Download canceled. Partial files were kept for retry."}

    @staticmethod
    def _remove_hf_repo(repo_id: str) -> None:
        """Delete the Hub revisions (and unshared blobs) for one repo."""
        try:
            from huggingface_hub import scan_cache_dir
            info = scan_cache_dir()
            repo = next((r for r in info.repos if r.repo_id == repo_id), None)
            if repo:
                info.delete_revisions(*[rev.commit_hash for rev in repo.revisions]).execute()
        except Exception:
            pass

    def remove(self, name: str) -> None:
        """Delete one model's cache. Only known model paths are touched."""
        with self.lock:
            if self.any_downloading():
                raise ConflictError("Wait for model installation to finish before removing a model")
        if name == "speech":
            path = _speech_dir()
            if path and _speech_root().resolve() in path.resolve().parents:
                shutil.rmtree(path)
            self._remove_hf_repo("FermionResearch/Phonon-2.5-English")
        elif name == "ocr":
            if OCR_LOCAL.exists():
                shutil.rmtree(OCR_LOCAL)
            self._remove_hf_repo(OCR_MODEL)
        else:
            raise ValueError("unknown model")
        with self.lock:
            self.downloads.pop(name, None)
        self.refresh()

    def shutdown(self) -> None:
        with self.lock:
            procs = list(self.procs.values())
        for proc in procs:
            if proc.poll() is None:
                try:
                    proc.terminate()
                except Exception:
                    pass


def tail(path: Path, n: int = 800) -> str:
    try:
        data = path.read_bytes()[-n:]
        return data.decode("utf-8", "replace").strip()
    except Exception:
        return ""