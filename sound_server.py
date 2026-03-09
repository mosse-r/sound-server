#!/usr/bin/env python3
import json
import logging
import os
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def env_bool(name: str, default: bool = False) -> bool:
    val = os.getenv(name)
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "on"}


HOST = os.getenv("SOUND_SERVER_HOST", "127.0.0.1")
PORT = int(os.getenv("SOUND_SERVER_PORT", "8088"))
API_TOKEN = os.getenv("SOUND_SERVER_TOKEN", "")
LOG_LEVEL = os.getenv("SOUND_SERVER_LOG_LEVEL", "INFO").upper()
ALLOW_NON_LOCAL = env_bool("SOUND_SERVER_ALLOW_NON_LOCAL", False)
BACKEND = os.getenv("SOUND_SERVER_BACKEND", "auto")
AUDIO_DEVICE = os.getenv("SOUND_SERVER_AUDIO_DEVICE", "")
MAX_TEXT_LEN = int(os.getenv("SOUND_SERVER_MAX_TEXT_LEN", "500"))


logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("sound-server")


@dataclass
class Task:
    id: str
    kind: str  # play-file | play-bytes | speak
    payload: dict[str, Any]
    status: str = "queued"
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    error: str | None = None


class PlaybackService:
    def __init__(self) -> None:
        self.q: queue.Queue[Task] = queue.Queue()
        self.history: dict[str, Task] = {}
        self.history_order: list[str] = []
        self.max_history = 200
        self.current: Task | None = None
        self.shutdown = threading.Event()
        self.backend = self._resolve_backend()
        self.worker = threading.Thread(target=self._worker_loop, daemon=True)
        self.worker.start()

    def _resolve_backend(self) -> str:
        if BACKEND != "auto":
            if not shutil.which(BACKEND):
                raise RuntimeError(f"Configured backend '{BACKEND}' not found in PATH")
            return BACKEND

        for candidate in ("mpv", "ffplay", "aplay"):
            if shutil.which(candidate):
                return candidate
        raise RuntimeError("No playback backend found. Install one of: mpv, ffplay, aplay")

    def enqueue(self, kind: str, payload: dict[str, Any]) -> Task:
        t = Task(id=str(uuid.uuid4()), kind=kind, payload=payload)
        self.history[t.id] = t
        self.history_order.append(t.id)
        if len(self.history_order) > self.max_history:
            old = self.history_order.pop(0)
            self.history.pop(old, None)
        self.q.put(t)
        return t

    def _player_cmd(self, path: str) -> list[str]:
        if self.backend == "mpv":
            cmd = ["mpv", "--no-video", "--really-quiet", "--keep-open=no"]
            if AUDIO_DEVICE:
                # Example pulse device: pulse/bluez_output.XX_XX_XX_XX_XX_XX.a2dp-sink
                cmd += ["--audio-device", AUDIO_DEVICE]
            cmd += [path]
            return cmd
        if self.backend == "ffplay":
            # ffplay doesn't reliably expose output device choice across distros.
            return ["ffplay", "-nodisp", "-autoexit", "-loglevel", "error", path]
        # aplay can select ALSA device like hw:0,0 or default
        cmd = ["aplay"]
        if AUDIO_DEVICE:
            cmd += ["-D", AUDIO_DEVICE]
        cmd += [path]
        return cmd

    def _speak_to_temp_file(self, text: str) -> str:
        tdir = tempfile.mkdtemp(prefix="sound-server-tts-")
        wav = os.path.join(tdir, "speech.wav")
        if shutil.which("espeak-ng"):
            cmd = ["espeak-ng", "-w", wav, text]
        elif shutil.which("espeak"):
            cmd = ["espeak", "-w", wav, text]
        else:
            raise RuntimeError("No TTS engine found. Install espeak-ng or espeak")
        subprocess.run(cmd, check=True)
        return wav

    def _run_task(self, task: Task) -> None:
        if task.kind == "play-file":
            path = task.payload["path"]
            cmd = self._player_cmd(path)
            subprocess.run(cmd, check=True)
            return

        if task.kind == "play-bytes":
            path = task.payload["path"]
            try:
                cmd = self._player_cmd(path)
                subprocess.run(cmd, check=True)
            finally:
                try:
                    Path(path).unlink(missing_ok=True)
                except Exception:
                    pass
            return

        if task.kind == "speak":
            text = task.payload["text"]
            wav = self._speak_to_temp_file(text)
            try:
                cmd = self._player_cmd(wav)
                subprocess.run(cmd, check=True)
            finally:
                try:
                    Path(wav).unlink(missing_ok=True)
                    Path(wav).parent.rmdir()
                except Exception:
                    pass
            return

        raise RuntimeError(f"Unsupported task type: {task.kind}")

    def _worker_loop(self) -> None:
        while not self.shutdown.is_set():
            try:
                task = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            self.current = task
            task.status = "running"
            task.started_at = time.time()
            try:
                self._run_task(task)
                task.status = "done"
            except Exception as e:
                task.status = "failed"
                task.error = str(e)
                log.exception("Task %s failed", task.id)
            finally:
                task.finished_at = time.time()
                self.current = None
                self.q.task_done()

    def status(self) -> dict[str, Any]:
        return {
            "backend": self.backend,
            "queue_length": self.q.qsize(),
            "current": self._task_dict(self.current),
            "recent": [
                self._task_dict(self.history[tid])
                for tid in self.history_order[-10:]
                if tid in self.history
            ],
        }

    @staticmethod
    def _task_dict(t: Task | None) -> dict[str, Any] | None:
        if not t:
            return None
        return {
            "id": t.id,
            "kind": t.kind,
            "status": t.status,
            "error": t.error,
            "created_at": t.created_at,
            "started_at": t.started_at,
            "finished_at": t.finished_at,
            "payload": t.payload,
        }


class ApiHandler(BaseHTTPRequestHandler):
    service: PlaybackService

    def _json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("Invalid Content-Length")
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            raise ValueError("Invalid JSON payload")

    def _read_bytes(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("Invalid Content-Length")
        if length <= 0:
            raise ValueError("Missing request body")
        return self.rfile.read(length)

    def _auth_ok(self) -> bool:
        if not API_TOKEN:
            return False
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
        else:
            token = self.headers.get("X-API-Token", "").strip()
        return token == API_TOKEN

    def _client_allowed(self) -> bool:
        if ALLOW_NON_LOCAL:
            return True
        client_ip = self.client_address[0]
        return client_ip in {"127.0.0.1", "::1"}

    def _require_auth(self) -> bool:
        if not self._client_allowed():
            self._json(403, {"ok": False, "error": "forbidden_non_local"})
            return False
        if not self._auth_ok():
            self._json(401, {"ok": False, "error": "unauthorized"})
            return False
        return True

    def do_GET(self) -> None:
        if self.path == "/health":
            self._json(200, {"ok": True, "status": "healthy", "time": time.time()})
            return

        if self.path == "/status":
            if not self._require_auth():
                return
            self._json(200, {"ok": True, "status": self.service.status()})
            return

        self._json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        if self.path not in {"/play-file", "/play-bytes", "/speak"}:
            self._json(404, {"ok": False, "error": "not_found"})
            return

        if not self._require_auth():
            return

        if self.path == "/play-file":
            try:
                payload = self._read_json()
            except ValueError as e:
                self._json(400, {"ok": False, "error": str(e)})
                return
            path = str(payload.get("path", "")).strip()
            if not path:
                self._json(400, {"ok": False, "error": "Missing 'path'"})
                return
            p = Path(path)
            if not p.exists() or not p.is_file():
                self._json(400, {"ok": False, "error": "Path does not exist or is not a file"})
                return
            task = self.service.enqueue("play-file", {"path": str(p.resolve())})
            self._json(202, {"ok": True, "task_id": task.id, "status": task.status})
            return

        if self.path == "/play-bytes":
            try:
                raw = self._read_bytes()
            except ValueError as e:
                self._json(400, {"ok": False, "error": str(e)})
                return

            filename = self.headers.get("X-Filename", "audio.bin")
            suffix = Path(filename).suffix or ".bin"
            fd, tmp_path = tempfile.mkstemp(prefix="sound-server-upload-", suffix=suffix)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(raw)
            except Exception:
                try:
                    Path(tmp_path).unlink(missing_ok=True)
                except Exception:
                    pass
                raise

            task = self.service.enqueue("play-bytes", {"path": tmp_path, "filename": filename})
            self._json(202, {"ok": True, "task_id": task.id, "status": task.status})
            return

        if self.path == "/speak":
            try:
                payload = self._read_json()
            except ValueError as e:
                self._json(400, {"ok": False, "error": str(e)})
                return
            text = str(payload.get("text", "")).strip()
            if not text:
                self._json(400, {"ok": False, "error": "Missing 'text'"})
                return
            if len(text) > MAX_TEXT_LEN:
                self._json(400, {"ok": False, "error": f"Text too long (max {MAX_TEXT_LEN})"})
                return
            task = self.service.enqueue("speak", {"text": text})
            self._json(202, {"ok": True, "task_id": task.id, "status": task.status})
            return

    def log_message(self, format: str, *args: Any) -> None:
        log.info("%s - %s", self.client_address[0], format % args)


def load_env_file(path: str = ".env") -> None:
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        os.environ.setdefault(key, val)


def main() -> int:
    load_env_file()

    # Re-read after .env load
    global HOST, PORT, API_TOKEN, LOG_LEVEL, ALLOW_NON_LOCAL, BACKEND, AUDIO_DEVICE, MAX_TEXT_LEN
    HOST = os.getenv("SOUND_SERVER_HOST", HOST)
    PORT = int(os.getenv("SOUND_SERVER_PORT", str(PORT)))
    API_TOKEN = os.getenv("SOUND_SERVER_TOKEN", API_TOKEN)
    LOG_LEVEL = os.getenv("SOUND_SERVER_LOG_LEVEL", LOG_LEVEL).upper()
    ALLOW_NON_LOCAL = env_bool("SOUND_SERVER_ALLOW_NON_LOCAL", ALLOW_NON_LOCAL)
    BACKEND = os.getenv("SOUND_SERVER_BACKEND", BACKEND)
    AUDIO_DEVICE = os.getenv("SOUND_SERVER_AUDIO_DEVICE", AUDIO_DEVICE)
    MAX_TEXT_LEN = int(os.getenv("SOUND_SERVER_MAX_TEXT_LEN", str(MAX_TEXT_LEN)))

    if not API_TOKEN:
        log.error("SOUND_SERVER_TOKEN is required")
        return 2

    logging.getLogger().setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

    service = PlaybackService()
    ApiHandler.service = service
    server = ThreadingHTTPServer((HOST, PORT), ApiHandler)

    def handle_sig(_sig: int, _frame: Any) -> None:
        log.info("Shutting down...")
        service.shutdown.set()
        server.shutdown()

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    log.info("sound-server listening on http://%s:%s backend=%s", HOST, PORT, service.backend)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
